import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../enums/fastpix_spritesheet_error_code.dart';
import '../enums/fastpix_spritesheet_status.dart';
import '../enums/fastpix_spritesheet_type.dart';
import '../fastpix_player_configuration.dart';
import '../models/fastpix_player_data_source.dart';
import '../models/fastpix_player_event.dart';
import '../models/fastpix_player_spritesheet_configuration.dart';
import '../models/fastpix_spritesheet.dart';
import '../models/fastpix_spritesheet_event.dart';
import '../utils/fastpix_spritesheet_client.dart';

/// The manager behind each controller, for the preview widget.
///
/// A registry rather than a public getter on the controller, so the decoded
/// image never becomes public API: an application holding a `ui.Image` could
/// keep it past the source change or disposal that must release it. Same
/// pattern as `fastPixFullscreenOverlays`. Not exported from the package.
final Expando<FastPixSpritesheetManager> fastPixSpritesheetManagers =
    Expando<FastPixSpritesheetManager>('fastPixSpritesheetManagers');

/// Loads the active source's seek-preview spritesheet and owns its image.
///
/// One per controller, driven from the controller's lifecycle: [load] after a
/// source is ready, [resetForNewSource] when it is replaced, [dispose] with the
/// controller. Every await is followed by a generation check, so work for a
/// source that is no longer current is dropped rather than applied — including
/// an image decoded for it, which is released.
///
/// Nothing here throws, and no failure reaches the playback error channel.
class FastPixSpritesheetManager {
  FastPixSpritesheetManager(
    this._eventManager, {
    FastPixSpritesheetClient Function()? clientFactory,
  }) : _clientFactory =
           clientFactory ?? debugClientFactory ?? FastPixSpritesheetClient.new;

  /// Replaces the HTTP client of managers created afterwards, so tests driving
  /// a whole controller can shorten the generation retry schedule.
  @visibleForTesting
  static FastPixSpritesheetClient Function()? debugClientFactory;

  final FastPixPlayerEventManager _eventManager;
  final FastPixSpritesheetClient Function() _clientFactory;

  /// Longest decoded side, in pixels. A common maximum GPU texture dimension.
  static const int maxDecodedSide = 8192;

  /// Upper bound on decoded pixel memory (RGBA, four bytes a pixel).
  static const int maxDecodedBytes = 100 * 1024 * 1024;

  FastPixSpritesheetClient? _client;
  int _generation = 0;

  FastPixSpritesheetStatus _status = FastPixSpritesheetStatus.idle;
  FastPixSpritesheet? _spritesheet;
  ui.Image? _image;
  double _decodeScale = 1;

  // Broadcast and never closed: a controller may be initialized again after
  // disposal, and a closed controller would silently drop every later update.
  final StreamController<FastPixSpritesheet?> _changes =
      StreamController<FastPixSpritesheet?>.broadcast();

  /// Metadata status for the active source.
  FastPixSpritesheetStatus get status => _status;

  /// The active source's spritesheet, once its metadata is loaded.
  FastPixSpritesheet? get spritesheet => _spritesheet;

  /// Emits the spritesheet when its metadata loads, again when its image
  /// becomes drawable, and null when it is cleared.
  Stream<FastPixSpritesheet?> get changes => _changes.stream;

  /// The decoded image, or null while none is drawable.
  ui.Image? get image => _image;

  /// Decoded size relative to the full image.
  double get decodeScale => _decodeScale;

  /// Load the spritesheet for [dataSource]. Never throws; unawaited by the
  /// controller.
  Future<void> load(
    FastPixPlayerDataSource dataSource,
    FastPixPlayerConfiguration? configuration,
  ) async {
    final generation = ++_generation;
    try {
      await _load(dataSource, configuration, generation);
    } catch (error) {
      // Defensive: every expected failure is handled inside. Anything else
      // still must not escape into an unawaited future.
      debugPrint('FastPix spritesheet load failed unexpectedly: $error');
    }
  }

  Future<void> _load(
    FastPixPlayerDataSource dataSource,
    FastPixPlayerConfiguration? configuration,
    int generation,
  ) async {
    final settings =
        configuration?.spritesheetConfiguration ??
        const FastPixPlayerSpritesheetConfiguration();
    // The images host is derived from the source's `customDomain`. A domain it
    // cannot read leaves the host genuinely unknown, which belongs on this
    // shelf rather than in the error path: guessing would only spend a request
    // on the seek path to reach the same time-only preview, and report a
    // failure for a source that was never misconfigured.
    final origin = dataSource.imagesHost;
    if (!settings.enableSpritesheet ||
        dataSource.streamType == StreamType.live ||
        origin == null) {
      _status = FastPixSpritesheetStatus.idle;
      return;
    }

    final type =
        settings.enableAdvancedSpritesheet
            ? FastPixSpritesheetType.advanced
            : FastPixSpritesheetType.normal;
    final interval = settings.resolvedInterval;
    final metadataUri = FastPixSpritesheetClient.metadataUri(
      origin: origin,
      playbackId: dataSource.playbackId,
      type: type,
      interval: interval,
      token: dataSource.token,
    );
    final imageUri = FastPixSpritesheetClient.imageUri(
      origin: origin,
      playbackId: dataSource.playbackId,
      type: type,
      interval: interval,
      token: dataSource.token,
    );

    bool isStale() => generation != _generation;
    final client = _client ??= _clientFactory();

    _status = FastPixSpritesheetStatus.loading;
    _eventManager.emit(
      FastPixSpritesheetLoadStartedEvent(
        timestamp: DateTime.now(),
        spritesheetType: type,
      ),
    );

    // Metadata.
    final metadata = await client.fetchMetadata(metadataUri, type: type);
    if (isStale()) return;
    if (!metadata.isOk) {
      _status = FastPixSpritesheetStatus.failed;
      _fail(type, metadata.error!, _describe(metadata, 'metadata'));
      return;
    }

    final FastPixSpritesheet sheet;
    try {
      sheet = FastPixSpritesheet.parse(
        utf8.decode(metadata.bytes!, allowMalformed: true),
        type: type,
        imageUrl: imageUri,
      );
    } on FormatException catch (error) {
      _status = FastPixSpritesheetStatus.failed;
      _fail(type, FastPixSpritesheetErrorCode.invalidResponse, error.message);
      return;
    }

    _spritesheet = sheet;
    _status = FastPixSpritesheetStatus.ready;
    _changes.add(sheet);
    _eventManager.emit(
      FastPixSpritesheetLoadedEvent(
        timestamp: DateTime.now(),
        spritesheetType: type,
        interval: sheet.interval,
        tileCount: sheet.tiles.length,
      ),
    );

    // Image. From here a failure leaves the metadata usable: status stays
    // ready, and previews show the time only.
    final imageResponse = await client.fetchImage(
      imageUri,
      type: type,
      isCancelled: isStale,
    );
    if (isStale()) return;
    if (!imageResponse.isOk) {
      _fail(type, imageResponse.error!, _describe(imageResponse, 'image'));
      return;
    }

    final decoded = await _decode(imageResponse.bytes!, sheet);
    if (isStale()) {
      decoded.image?.dispose();
      return;
    }
    if (decoded.image == null) {
      _fail(type, decoded.error!, decoded.message!);
      return;
    }

    _image = decoded.image;
    _decodeScale = decoded.scale;
    _changes.add(sheet);
    _eventManager.emit(
      FastPixSpritesheetImageReadyEvent(
        timestamp: DateTime.now(),
        spritesheetType: type,
        decodeScale: decoded.scale,
      ),
    );
  }

  /// The scale an image of [width] x [height] is decoded at: the largest scale
  /// up to 1 that keeps the longer side within [maxDecodedSide] and the pixels
  /// within [maxDecodedBytes].
  @visibleForTesting
  static double decodeScaleFor(int width, int height) {
    if (width <= 0 || height <= 0) return 1;
    final bySide = maxDecodedSide / math.max(width, height);
    final byMemory = math.sqrt(maxDecodedBytes / (width * height * 4));
    return math.min(1.0, math.min(bySide, byMemory));
  }

  Future<_Decoded> _decode(Uint8List bytes, FastPixSpritesheet sheet) async {
    // The sheet's size is not in the metadata; it is the far edge of its tiles.
    var sheetWidth = 0;
    var sheetHeight = 0;
    for (final tile in sheet.tiles) {
      sheetWidth = math.max(sheetWidth, tile.region.right.round());
      sheetHeight = math.max(sheetHeight, tile.region.bottom.round());
    }

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // Reads the header only: dimensions, without decoding a single pixel.
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width != sheetWidth || descriptor.height != sheetHeight) {
        return _Decoded.failed(
          FastPixSpritesheetErrorCode.metadataImageMismatch,
          'Image is ${descriptor.width}x${descriptor.height} but the metadata '
          'describes ${sheetWidth}x$sheetHeight.',
        );
      }

      final scale = decodeScaleFor(descriptor.width, descriptor.height);
      codec = await descriptor.instantiateCodec(
        targetWidth:
            scale < 1 ? math.max(1, (descriptor.width * scale).floor()) : null,
        targetHeight:
            scale < 1 ? math.max(1, (descriptor.height * scale).floor()) : null,
      );
      final image = (await codec.getNextFrame()).image;
      return _Decoded.ok(image, image.width / descriptor.width);
    } catch (error) {
      return const _Decoded.failed(
        FastPixSpritesheetErrorCode.decodeFailed,
        'Spritesheet image could not be decoded.',
      );
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  void _fail(
    FastPixSpritesheetType type,
    FastPixSpritesheetErrorCode code,
    String message,
  ) {
    _eventManager.emit(
      FastPixSpritesheetFailedEvent(
        timestamp: DateTime.now(),
        spritesheetType: type,
        code: code,
        message: message,
      ),
    );
  }

  static String _describe(FastPixSpritesheetResponse response, String what) {
    final status = response.statusCode;
    final suffix = status == null ? '' : ' (HTTP $status)';
    return switch (response.error) {
      FastPixSpritesheetErrorCode.unauthorized =>
        'Spritesheet $what request was not authorized$suffix.',
      FastPixSpritesheetErrorCode.mediaNotFound =>
        'No media found for this playback ID$suffix.',
      FastPixSpritesheetErrorCode.intervalExceedsDurationCap =>
        'Advanced spritesheet interval is too small for this video$suffix.',
      FastPixSpritesheetErrorCode.generationTimedOut =>
        'Spritesheet image was still being generated after the last retry.',
      _ => 'Spritesheet $what request failed$suffix.',
    };
  }

  /// Drop the current source's spritesheet: stale work stands down, pending
  /// retries stop, and the image is released.
  void resetForNewSource() {
    _generation++;
    final hadSpritesheet = _spritesheet != null;
    _status = FastPixSpritesheetStatus.idle;
    _spritesheet = null;
    _image?.dispose();
    _image = null;
    _decodeScale = 1;
    if (hadSpritesheet) _changes.add(null);
  }

  /// Stop all traffic and release the image. The manager stays usable, since
  /// the controller may be initialized again.
  void dispose() {
    resetForNewSource();
    _client?.close();
    _client = null;
  }
}

class _Decoded {
  const _Decoded.ok(ui.Image this.image, this.scale)
    : error = null,
      message = null;

  const _Decoded.failed(
    FastPixSpritesheetErrorCode this.error,
    String this.message,
  ) : image = null,
      scale = 1;

  final ui.Image? image;
  final double scale;
  final FastPixSpritesheetErrorCode? error;
  final String? message;
}
