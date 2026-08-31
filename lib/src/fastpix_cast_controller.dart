import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:permission_handler/permission_handler.dart';

import 'enums/fastpix_cast_segment_format.dart';
import 'enums/fastpix_cast_state.dart';
import 'fastpix_player_controller.dart';
import 'models/fastpix_cast_device.dart';
import 'models/fastpix_cast_error.dart';
import 'models/fastpix_cast_event.dart';
import 'models/fastpix_cast_text_track.dart';
import 'models/fastpix_player_data_source.dart';
import 'models/fastpix_player_drm_configuration.dart';
import 'models/fastpix_player_event.dart';

/// Drives Chromecast playback for a FastPix stream.
///
/// Casting is not screen mirroring: the receiver fetches the stream itself,
/// directly from FastPix, and this controller only sends it commands. Three
/// consequences shape the whole class:
///
/// * The stream URL must be reachable by the receiver, so authentication has
///   to travel in the URL. [FastPixPlayerDataSource.url] already carries the
///   playback token as a query parameter, but
///   [FastPixPlayerDataSource.headers] are silently dropped — the receiver
///   makes its own request and never sees them.
/// * Local and remote playback are mutually exclusive. Use
///   [startCastingFrom] and [stopCastingTo] to move between them rather than
///   driving both players by hand.
/// * DRM streams cannot be cast at all through the default receiver. See
///   [loadMedia].
///
/// The controller never ends a live session on [dispose]: casting is expected
/// to outlive the screen that started it.
class FastPixCastController {
  /// MIME type reported to the receiver for FastPix streams, which are HLS.
  ///
  /// `application/vnd.apple.mpegurl` is the registered HLS type and what
  /// FastPix itself returns for a manifest; the working native Cast
  /// integration sends the same. `application/x-mpegurl` is the older
  /// unregistered spelling and some receiver pipelines treat the two
  /// differently.
  static const String _hlsContentType = 'application/vnd.apple.mpegurl';

  /// How long [connect] waits for a session before giving up.
  static const Duration _defaultConnectTimeout = Duration(seconds: 30);

  /// Cast application ID of the receiver to look for.
  ///
  /// Defaults to Google's Default Media Receiver, which plays unprotected HLS
  /// with no registration required. A custom receiver ID is needed for
  /// branding, DRM, or receiver-side analytics.
  final String appId;

  /// Whether the receiver should stop playing when this app is terminated.
  final bool stopCastingOnAppTerminated;

  /// How the HLS streams being cast are packaged.
  ///
  /// Defaults to [FastPixCastSegmentFormat.auto]. Set it to
  /// [FastPixCastSegmentFormat.fmp4] when the stream uses CMAF packaging, or
  /// the receiver may connect, display the title, and never start playing.
  final FastPixCastSegmentFormat segmentFormat;

  /// Whether to print a trace of the cast handshake, tagged `[FastPixCast]`.
  ///
  /// Cast failures are largely silent: a session that never starts and a load
  /// that is quietly discarded look identical from the outside. The trace
  /// exists so the failing step is visible rather than inferred.
  final bool verbose;

  final FastPixPlayerEventManager _eventManager;

  FastPixCastController({
    this.appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId,
    this.stopCastingOnAppTerminated = true,
    this.segmentFormat = FastPixCastSegmentFormat.auto,
    this.verbose = false,
    FastPixPlayerEventManager? eventManager,
  }) : _eventManager = eventManager ?? FastPixPlayerEventManager();

  void _trace(String message) {
    if (verbose) debugPrint('[FastPixCast] $message');
  }

  /// Event manager cast events are dispatched through.
  ///
  /// Pass `player.eventManager` to the constructor to have cast events reach
  /// the same listeners as playback events, so consumers only learn one API.
  FastPixPlayerEventManager get eventManager => _eventManager;

  bool _initialized = false;
  bool _disposed = false;

  FastPixCastState _state = FastPixCastState.unavailable;
  List<FastPixCastDevice> _devices = const <FastPixCastDevice>[];

  /// Devices exactly as the plugin reported them.
  ///
  /// Kept so a session can be started from a [FastPixCastDevice], which
  /// intentionally does not carry the plugin's type. Looking the original up
  /// by ID keeps the public model free of `flutter_chrome_cast` without
  /// losing the fields the SDK needs to connect.
  List<GoogleCastDevice> _rawDevices = const <GoogleCastDevice>[];

  FastPixCastDevice? _connectedDevice;
  FastPixCastErrorEvent? _lastError;
  Duration _lastRemotePosition = Duration.zero;

  /// Receiver volume as this controller last observed or set it.
  ///
  /// Tracked optimistically rather than read from the receiver, because the
  /// Cast plugin never reports volume back: its iOS `didReceiveDeviceVolume`
  /// delegates are deliberately stubbed out, and its Android listener has no
  /// volume callback at all. The session carries a level, but only at the
  /// moment the session itself changes — so this is seeded on connect and
  /// updated on every [setVolume] from then on.
  double _remoteVolume = 1.0;

  /// Whether a session has been observed as connected.
  ///
  /// Guards against reporting `castStarted` twice when the session stream
  /// re-emits, and against reporting `castEnded` for a session that never
  /// established.
  bool _sessionWasConnected = false;

  final StreamController<FastPixCastState> _stateController =
      StreamController<FastPixCastState>.broadcast();
  final StreamController<List<FastPixCastDevice>> _devicesController =
      StreamController<List<FastPixCastDevice>>.broadcast();
  final StreamController<double> _volumeController =
      StreamController<double>.broadcast();

  /// Text tracks the receiver is offering, as of its last media status.
  ///
  /// Empty until the receiver has loaded something and reported back — the
  /// tracks inside an HLS manifest are not known before then.
  List<FastPixCastTextTrack> _textTracks = const <FastPixCastTextTrack>[];

  /// ID of the selected text track, or null when subtitles are off.
  int? _activeTextTrackId;

  /// Every track the receiver currently has active, audio and video included.
  ///
  /// Kept because Cast has no "change just the subtitles" command: selecting a
  /// track replaces the whole active set, so the tracks that are not text have
  /// to be sent back unchanged or they are switched off.
  List<int> _activeReceiverTrackIds = const <int>[];

  final StreamController<List<FastPixCastTextTrack>> _textTracksController =
      StreamController<List<FastPixCastTextTrack>>.broadcast();
  final StreamController<int?> _activeTextTrackController =
      StreamController<int?>.broadcast();

  /// Length of the loaded media, once the receiver has reported one.
  ///
  /// Null for a live stream and until the first media status arrives, so a
  /// progress bar has to cope with not knowing how long the thing is.
  Duration? _remoteDuration;

  /// Whether the receiver is playing, as of its last status.
  bool _remotePlaying = false;

  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();

  /// Positions the receiver reported, with the plugin's bogus ones removed.
  ///
  /// Not the plugin's stream: that one cannot be trusted frame to frame. See
  /// [_acceptPosition] for what it emits that a progress bar must not show.
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  /// Where a seek was aimed, until the receiver reports having arrived.
  ///
  /// A Cast seek is a network round trip, and the receiver keeps reporting the
  /// *old* position for several hundred milliseconds after the request goes
  /// out. Published immediately and held here so the scrubber stays where the
  /// viewer put it instead of snapping back and then jumping forward again.
  Duration? _pendingSeek;

  /// Gives up on [_pendingSeek] if the receiver never confirms the seek, so a
  /// dropped request cannot freeze the position readout for the whole session.
  Timer? _pendingSeekTimer;

  /// How far from the target a reported position may be and still count as the
  /// receiver having arrived. Cast reports at roughly one-second granularity,
  /// and iOS truncates to whole seconds, so this cannot be tight.
  static const Duration _seekArrivalTolerance = Duration(seconds: 2);

  /// How long to keep showing the seek target before trusting the receiver
  /// again regardless.
  static const Duration _seekConfirmTimeout = Duration(seconds: 6);

  StreamSubscription<List<GoogleCastDevice>>? _devicesSubscription;
  StreamSubscription<GoogleCastSession?>? _sessionSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<GoggleCastMediaStatus?>? _mediaStatusSubscription;

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------

  /// Current state of the cast subsystem.
  FastPixCastState get state => _state;

  /// Stream of state changes, for driving cast UI.
  Stream<FastPixCastState> get stateStream => _stateController.stream;

  /// Receivers discovered so far.
  List<FastPixCastDevice> get devices => _devices;

  /// Stream of the discovered receiver list.
  Stream<List<FastPixCastDevice>> get devicesStream =>
      _devicesController.stream;

  /// The receiver currently playing, or `null` when not casting.
  FastPixCastDevice? get connectedDevice => _connectedDevice;

  /// Whether a receiver is currently playing.
  bool get isConnected => _state == FastPixCastState.connected;

  /// Most recent cast failure, or `null` when nothing has failed.
  ///
  /// Retained so UI that mounts after the failure can still render it, the
  /// same way [FastPixPlayerController.lastError] behaves for playback.
  FastPixCastErrorEvent? get lastError => _lastError;

  /// Last position reported by the receiver.
  ///
  /// Tracked continuously rather than read on demand, because by the time a
  /// session ends the remote client has already been torn down and the
  /// position needed to resume locally would be gone.
  Duration get remotePosition => _lastRemotePosition;

  /// Receiver volume, from 0.0 to 1.0.
  ///
  /// Seeded from the session when it connects and updated by [setVolume].
  /// Volume changed from outside this app — the TV remote, the Google Home
  /// app, or the phone's own volume buttons, which control the receiver while
  /// a session is live — is *not* reflected here, because the Cast plugin
  /// provides no callback for it. Treat this as what this app last asked for
  /// rather than as ground truth.
  double get remoteVolume => _remoteVolume;

  /// Volume changes made through [setVolume], for driving a slider.
  ///
  /// Carries the same caveat as [remoteVolume]: external changes are invisible.
  Stream<double> get remoteVolumeStream => _volumeController.stream;

  /// Live position updates from the receiver, with the plugin's spurious
  /// zeroes and its stale post-seek readings filtered out.
  ///
  /// Deliberately not `flutter_chrome_cast`'s own `playerPositionStream`.
  /// Binding a scrubber straight to that one makes it jump: see
  /// [_acceptPosition].
  ///
  /// Unlike the plugin's stream, this one does **not** replay the latest value
  /// to a new listener — it emits only from the moment you subscribe. Seed
  /// from [remotePosition] (a `StreamBuilder`'s `initialData`) or the readout
  /// will sit blank until the receiver next reports.
  Stream<Duration> get remotePositionStream => _positionController.stream;

  /// Length of the media on the receiver, or null when it has none.
  ///
  /// A live stream has no end, and nothing is known before the receiver's
  /// first status arrives; both read as null, so a progress bar built on this
  /// must handle the unknown case rather than assume zero.
  Duration? get remoteDuration => _remoteDuration;

  /// Updates to [remoteDuration], for driving a progress bar.
  Stream<Duration?> get remoteDurationStream => _durationController.stream;

  /// Updates to [isRemotePlaying], for driving a play/pause button.
  ///
  /// Emits for changes made anywhere, the TV remote included, since the
  /// receiver reports its state the same way whoever caused it.
  Stream<bool> get isRemotePlayingStream => _playingController.stream;

  /// Subtitle tracks the receiver is offering.
  ///
  /// Populated from the receiver's media status, so it covers both the tracks
  /// sent on load and the ones the receiver found in the HLS manifest itself.
  /// Empty until the receiver has reported a status for the loaded media.
  List<FastPixCastTextTrack> get textTracks => _textTracks;

  /// Stream of the offered subtitle tracks, for driving a subtitle menu.
  Stream<List<FastPixCastTextTrack>> get textTracksStream =>
      _textTracksController.stream;

  /// The selected subtitle track, or null when subtitles are off.
  FastPixCastTextTrack? get activeTextTrack {
    final id = _activeTextTrackId;
    if (id == null) return null;
    for (final FastPixCastTextTrack track in _textTracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  /// Stream of the selected track's ID, or null each time subtitles go off.
  ///
  /// Emits for changes made from anywhere — the TV remote and other senders
  /// can switch tracks too, and the receiver reports all of it the same way.
  Stream<int?> get activeTextTrackStream => _activeTextTrackController.stream;

  /// Whether the receiver is actively playing rather than paused or idle.
  ///
  /// Reads the same field [isRemotePlayingStream] emits. It used to consult
  /// the plugin's live `mediaStatus` instead, which meant a `StreamBuilder`
  /// seeded from this getter and driven by that stream could disagree — and
  /// because the stream deduplicates, a play/pause button that started out
  /// wrong stayed wrong until the next real state change.
  bool get isRemotePlaying => _remotePlaying;

  /// Whether a custom receiver is configured rather than Google's default.
  ///
  /// DRM playback requires one: the Default Media Receiver cannot perform a
  /// license request, so a protected stream can never play on it.
  bool get hasCustomReceiver =>
      appId != GoogleCastDiscoveryCriteria.kDefaultApplicationId;

  /// Casting is only supported on the platforms the Cast SDK ships for.
  static bool get _isSupportedPlatform => Platform.isAndroid || Platform.isIOS;

  // ---------------------------------------------------------------------
  // Listeners
  // ---------------------------------------------------------------------

  /// Add a listener for a specific event type.
  void addEventListener(String eventType, FastPixPlayerEventListener listener) {
    _eventManager.addEventListener(eventType, listener);
  }

  /// Add a listener for all events.
  void addGlobalListener(FastPixPlayerEventListener listener) {
    _eventManager.addGlobalListener(listener);
  }

  /// Remove a listener for a specific event type.
  void removeEventListener(
    String eventType,
    FastPixPlayerEventListener listener,
  ) {
    _eventManager.removeEventListener(eventType, listener);
  }

  /// Remove a global listener.
  void removeGlobalListener(FastPixPlayerEventListener listener) {
    _eventManager.removeGlobalListener(listener);
  }

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Initialise the Cast context.
  ///
  /// Must run before discovery. Calling it again is a no-op, so it is safe to
  /// call defensively from [startDiscovery] and [connect]. On an unsupported
  /// platform this settles on [FastPixCastState.unavailable] instead of
  /// throwing, so callers can build cast UI unconditionally and let the state
  /// hide it.
  Future<void> initialize() async {
    _assertNotDisposed();
    if (_initialized) return;

    if (!_isSupportedPlatform) {
      _setState(FastPixCastState.unavailable);
      return;
    }

    try {
      // The options type differs per platform: iOS wants discovery criteria,
      // Android wants the raw application ID.
      final GoogleCastOptions options =
          Platform.isIOS
              ? IOSGoogleCastOptions(
                GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
                  appId,
                ),
                stopCastingOnAppTerminated: stopCastingOnAppTerminated,
              )
              : GoogleCastOptionsAndroid(
                appId: appId,
                stopCastingOnAppTerminated: stopCastingOnAppTerminated,
              );

      await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
    } catch (error) {
      _fail(
        'Could not initialise the Google Cast context: $error',
        FastPixCastErrorCode.initFailed,
        cause: error,
      );
      return;
    }

    _initialized = true;
    _bindDeviceStream();
    _bindSessionStream();
    _bindPositionStream();
    _bindMediaStatusStream();

    // Nothing has been discovered yet — which is not the same as knowing
    // there is nothing to discover, hence [FastPixCastState.noDevices] rather
    // than [FastPixCastState.unavailable].
    _setState(FastPixCastState.noDevices);
  }

  /// Start scanning for receivers.
  ///
  /// Discovery is expensive in battery and Wi-Fi traffic, so start it when
  /// cast UI opens and call [stopDiscovery] when it closes rather than
  /// leaving it running for the app's lifetime.
  Future<void> startDiscovery() async {
    _assertNotDisposed();
    if (!_initialized) await initialize();
    if (!_initialized) return;

    await _requestNearbyDevicesPermission();

    try {
      await GoogleCastDiscoveryManager.instance.startDiscovery();
    } catch (error) {
      _fail(
        'Could not start Cast device discovery: $error',
        FastPixCastErrorCode.discoveryFailed,
        cause: error,
      );
    }
  }

  /// Cached Android API level, since it cannot change while running.
  int? _cachedAndroidSdkInt;

  /// Android API level, or 0 when that cannot be determined.
  ///
  /// Returning 0 on failure deliberately makes callers behave as though the
  /// platform is old, which skips permission requests rather than raising
  /// errors about permissions that may not exist.
  Future<int> _androidSdkInt() async {
    final cached = _cachedAndroidSdkInt;
    if (cached != null) return cached;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return _cachedAndroidSdkInt = info.version.sdkInt;
    } catch (_) {
      return _cachedAndroidSdkInt = 0;
    }
  }

  /// Whether this device gates Cast discovery behind a runtime permission.
  ///
  /// False on Android 12 and below, and on every other platform, so callers
  /// can avoid reporting a permission problem that cannot apply.
  Future<bool> get requiresNearbyDevicesPermission async =>
      Platform.isAndroid && await _androidSdkInt() >= 33;

  /// Open the system settings page for this app.
  ///
  /// Once a permission is permanently denied, requesting it again does
  /// nothing — Android will not show the dialog a third time. Settings is the
  /// only route back, so a caller showing the permission error needs a way to
  /// get the user there.
  Future<bool> openPermissionSettings() => openAppSettings();

  /// Ask for the Android 13+ nearby devices permission.
  ///
  /// Cast discovery runs over mDNS on the local network, which Android 13
  /// (API 33) moved behind `NEARBY_WIFI_DEVICES`. Without the grant
  /// MediaRouter reports zero Cast routes and raises nothing — the failure
  /// looks exactly like "there are no Chromecasts here". The Cast plugin
  /// declares a launcher for this permission but never wires it up, so
  /// nothing requests it unless the app does.
  ///
  /// A refusal is reported but does not abort discovery: the permission does
  /// not exist below Android 13, and treating "not granted" as fatal would
  /// break discovery on devices where it works fine.
  Future<void> _requestNearbyDevicesPermission() async {
    if (!Platform.isAndroid) return;

    // NEARBY_WIFI_DEVICES only exists from Android 13 (API 33). Below that,
    // permission_handler drops it from the request entirely and reports back
    // "denied" — not because anything is wrong, but because there is nothing
    // to grant. Requesting it anyway would raise a permission error on every
    // Android 12 device and send the user hunting for a setting their OS does
    // not have.
    if (await _androidSdkInt() < 33) return;

    try {
      final PermissionStatus status =
          await Permission.nearbyWifiDevices.request();
      if (status.isGranted || status.isLimited) return;

      _emitError(
        'The nearby devices permission was not granted. On Android 13 and '
        'above Cast discovery finds nothing without it — enable "Nearby '
        'devices" for this app in Settings.',
        FastPixCastErrorCode.nearbyPermissionDenied,
      );
    } catch (_) {
      // Platforms without the permission cannot be asked for it, which is not
      // a failure.
    }
  }

  /// Stop scanning for receivers. Does not affect a live session.
  Future<void> stopDiscovery() async {
    if (_disposed || !_initialized) return;

    try {
      await GoogleCastDiscoveryManager.instance.stopDiscovery();
    } catch (error) {
      _fail(
        'Could not stop Cast device discovery: $error',
        FastPixCastErrorCode.discoveryFailed,
        cause: error,
      );
    }
  }

  /// Release every subscription and stream this controller opened.
  ///
  /// Deliberately does not end a live session: a user who started casting
  /// expects the TV to keep playing when they leave the player screen. Call
  /// [disconnect] first if the session should stop with the screen.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _devicesSubscription?.cancel();
    await _sessionSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _mediaStatusSubscription?.cancel();
    _devicesSubscription = null;
    _sessionSubscription = null;
    _positionSubscription = null;
    _mediaStatusSubscription = null;

    // A wakelock is process-wide, so one left held here would keep the host
    // app's screen awake for the rest of its life.
    unawaited(WakelockPlus.disable().catchError((Object _) {}));

    await _stateController.close();
    await _devicesController.close();
    await _volumeController.close();
    await _textTracksController.close();
    await _activeTextTrackController.close();
    await _durationController.close();
    await _playingController.close();
    _clearPendingSeek();
    await _positionController.close();
  }

  // ---------------------------------------------------------------------
  // Sessions
  // ---------------------------------------------------------------------

  /// Start a session on [device] and wait until it is actually established.
  ///
  /// The underlying SDK call only reports that the attempt *started*, so this
  /// waits on the session stream before returning. Returning early would let
  /// callers load media into a session that does not exist yet.
  ///
  /// Returns whether the session connected.
  Future<bool> connect(
    FastPixCastDevice device, {
    Duration timeout = _defaultConnectTimeout,
  }) async {
    _assertNotDisposed();
    if (!_initialized) await initialize();
    if (!_initialized) return false;

    final raw = _rawDeviceFor(device);
    _trace('connect ${device.name} id=${device.id} '
        'raw=${raw.runtimeType} knownDevices=${_rawDevices.length}');
    if (raw == null) {
      _emitError(
        '${device.name} is no longer available. Rescan and try again.',
        FastPixCastErrorCode.deviceUnavailable,
      );
      return false;
    }

    _setState(FastPixCastState.connecting);

    // Subscribe before starting, or a fast connection can settle before the
    // listener is attached and the wait would time out on a live session.
    final connected = _awaitConnected(timeout);

    try {
      final started = await GoogleCastSessionManager.instance
          .startSessionWithDevice(raw);
      _trace('startSessionWithDevice -> $started');
      if (!started) {
        _emitError(
          'Could not start a Cast session on ${device.name}.',
          FastPixCastErrorCode.connectFailed,
        );
        _setState(_stateForDeviceList());
        return false;
      }
    } catch (error) {
      _emitError(
        'Could not start a Cast session on ${device.name}: $error',
        FastPixCastErrorCode.connectFailed,
        cause: error,
      );
      _setState(_stateForDeviceList());
      return false;
    }

    final result = await connected;
    _trace('awaited connection -> $result (state=${_state.name})');
    if (!result) {
      _emitError(
        'Timed out connecting to ${device.name}.',
        FastPixCastErrorCode.connectTimeout,
      );
      // The session never settled, so nothing else will move the controller
      // out of `connecting` — leaving it there would strand the UI on a
      // spinner for a connection that has already been given up on.
      _setState(_stateForDeviceList());
      return false;
    }

    return true;
  }

  /// End the current session.
  ///
  /// [stopReceiver] controls whether the receiver stops playing. It only has
  /// an effect when other senders are still connected to the same receiver;
  /// with a single sender the receiver always stops.
  Future<void> disconnect({bool stopReceiver = true}) async {
    if (_disposed || !_initialized) return;

    try {
      if (stopReceiver) {
        await GoogleCastSessionManager.instance.endSessionAndStopCasting();
      } else {
        await GoogleCastSessionManager.instance.endSession();
      }
    } catch (error) {
      _emitError(
        'Could not end the Cast session: $error',
        FastPixCastErrorCode.disconnectFailed,
        cause: error,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Media
  // ---------------------------------------------------------------------

  /// Load [dataSource] on the connected receiver, starting at [startAt].
  ///
  /// Throws [StateError] when no session is connected, and
  /// [UnsupportedError] for DRM protected sources: Chromecast receivers speak
  /// Widevine only — never FairPlay — and the Default Media Receiver cannot
  /// perform a license request against the FastPix license server at all.
  /// Supporting DRM playback on a receiver requires a custom receiver
  /// application.
  ///
  /// Several data source options do not survive the trip, because the
  /// receiver fetches and renders the stream itself:
  ///
  /// * [FastPixPlayerDataSource.headers] are dropped — authentication must be
  ///   in the URL, which the FastPix playback token already is.
  /// * Resolution hints (`minResolution`, `maxResolution`, `resolution`,
  ///   `renditionOrder`) are sent as URL parameters but adaptive switching is
  ///   then the receiver's decision, not this player's.
  /// * Caching, looping and [FastPixPlayerDataSource.endAt] are local player
  ///   behaviours with no receiver equivalent.
  Future<void> loadMedia(
    FastPixPlayerDataSource dataSource, {
    Duration startAt = Duration.zero,
    bool autoPlay = true,
  }) async {
    _assertNotDisposed();

    if (!isConnected) {
      throw StateError(
        'Connect to a Cast device before loading media onto it.',
      );
    }

    if (dataSource.drmEnabled && !hasCustomReceiver) {
      const message =
          'DRM protected streams cannot be cast through the Default Media '
          'Receiver: it has no way to request a license. Host a custom '
          'receiver that reads the license URL from customData and pass its '
          'application ID as FastPixCastController(appId: ...).';
      _emitError(message, FastPixCastErrorCode.drmUnsupported);
      throw UnsupportedError(message);
    }

    final tracks = _buildTracks(dataSource);
    final streamUri = Uri.parse(dataSource.url);
    final media = GoogleCastMediaInformation(
      contentId: dataSource.url,
      // Android builds its media from `contentID`, but the iOS mapper reads
      // `contentURL` and returns nil without it — so the media is never
      // created, the receiver is never told what to play, and the failure is
      // invisible because the iOS channel call discards the error it gets
      // back. Both fields have to be set for one payload to work on both.
      contentUrl: streamUri,
      contentType: _hlsContentType,
      streamType:
          dataSource.streamType == StreamType.live
              ? CastMediaStreamType.live
              : CastMediaStreamType.buffered,
      metadata: GoogleCastMovieMediaMetadata(
        title: dataSource.title ?? dataSource.videoData?.title,
        subtitle: dataSource.description,
        images: _buildImages(dataSource),
      ),
      duration: dataSource.duration,
      tracks: tracks,
      // Left null unless configured, so the receiver keeps its own detection
      // for streams that do not need the hint.
      hlsSegmentFormat: _castSegmentFormat,
      hlsVideoSegmentFormat: _castVideoSegmentFormat,
      customData: _buildCustomData(dataSource),
    );

    // Seed the position now so a session that ends before the receiver has
    // reported anything still resumes locally at the right point. Any seek
    // aimed at the previous item is abandoned with it.
    _clearPendingSeek();
    _lastRemotePosition = startAt;
    if (!_positionController.isClosed) _positionController.add(startAt);

    try {
      // Clear whatever the receiver was playing first. Loading straight over a
      // live item lets the previous title resume instead of the new one
      // starting, which the working native integration also guards against.
      if (isRemotePlaying) {
        await GoogleCastRemoteMediaClient.instance.stop();
      }

      await GoogleCastRemoteMediaClient.instance.loadMedia(
        media,
        autoPlay: autoPlay,
        playPosition: startAt,
        activeTrackIds: _activeTrackIds(dataSource, tracks),
      );
    } catch (error) {
      _emitError(
        'Could not load the stream on ${_connectedDevice?.name ?? 'the receiver'}: $error',
        FastPixCastErrorCode.loadFailed,
        cause: error,
      );
      rethrow;
    }
  }

  /// Resume playback on the receiver.
  Future<void> play() => _remote(
    () => GoogleCastRemoteMediaClient.instance.play(),
    'play',
  );

  /// Pause playback on the receiver.
  Future<void> pause() => _remote(
    () => GoogleCastRemoteMediaClient.instance.pause(),
    'pause',
  );

  /// Stop playback on the receiver without ending the session.
  Future<void> stop() => _remote(
    () => GoogleCastRemoteMediaClient.instance.stop(),
    'stop',
  );

  /// Seek the receiver to [position].
  ///
  /// The new position is published before the request goes out, so a scrubber
  /// bound to [remotePositionStream] moves once, to where it was put, instead
  /// of snapping back to the receiver's stale reading first.
  ///
  /// Seeking never changes whether the receiver is playing. That has to be
  /// stated explicitly: `GoogleCastMediaSeekOption.resumeState` defaults to
  /// [GoogleCastMediaResumeState.play], so a seek issued on a paused video
  /// silently starts it — skip ten seconds while paused and playback resumes
  /// on its own.
  Future<void> seekTo(Duration position) {
    final target = position < Duration.zero ? Duration.zero : position;
    // Only pre-empt the readout if the seek can actually be sent. [_remote]
    // silently no-ops without a session, and showing the target anyway would
    // move the scrubber to a position nothing is playing and then hold it
    // there for the whole confirmation timeout.
    if (isConnected) _beginSeek(target);
    return _remote(
      () => GoogleCastRemoteMediaClient.instance.seek(
        GoogleCastMediaSeekOption(
          position: target,
          resumeState: GoogleCastMediaResumeState.unchanged,
        ),
      ),
      'seek',
    );
  }

  /// Seek [delta] from where the receiver actually is, clamped to the media.
  ///
  /// Belongs here rather than in the UI because it needs the position this
  /// controller has vetted. Computing it from the plugin's raw stream is what
  /// produced skips that landed nowhere near ten seconds away: one spurious
  /// zero and "forward ten seconds" becomes "jump to 0:10".
  Future<void> seekBy(Duration delta) {
    final duration = _remoteDuration;
    var target = _lastRemotePosition + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration != null && target > duration) target = duration;
    return seekTo(target);
  }

  /// Show [track] on the receiver, or turn subtitles off when it is null.
  ///
  /// Only tracks from [textTracks] can be selected — a receiver rejects an ID
  /// it did not report, and does so silently.
  ///
  /// The change is not recorded locally: the receiver confirms it in its next
  /// media status, which is also how changes made from a TV remote or another
  /// sender arrive. Assuming success here would make a rejected switch look
  /// like it worked.
  Future<void> selectTextTrack(FastPixCastTextTrack? track) async {
    if (!isConnected) return;

    if (track != null && !_textTracks.contains(track)) {
      _emitError(
        'The receiver is not offering a subtitle track with ID ${track.id}. '
        'Select one of the tracks from textTracks.',
        FastPixCastErrorCode.commandFailed,
      );
      return;
    }

    // Cast replaces the entire active set, so every active track that is not
    // a subtitle has to be sent back or it is switched off — selecting
    // subtitles would otherwise silently kill the audio track.
    final textTrackIds = _textTracks.map((track) => track.id).toSet();
    final ids = <int>[
      ..._activeReceiverTrackIds.where((id) => !textTrackIds.contains(id)),
      if (track != null) track.id,
    ];
    _trace('selectTextTrack -> $ids');

    try {
      await GoogleCastRemoteMediaClient.instance.setActiveTrackIDs(ids);
    } catch (error) {
      _emitError(
        'Could not change the subtitle track on the receiver: $error',
        FastPixCastErrorCode.commandFailed,
        cause: error,
      );
    }
  }

  /// Turn subtitles off on the receiver.
  Future<void> disableTextTrack() => selectTextTrack(null);

  /// Set the receiver's device volume, from 0.0 to 1.0.
  ///
  /// This is the volume of the receiver hardware, not of a local player.
  Future<void> setVolume(double volume) async {
    if (!isConnected) return;
    final double clamped = volume.clamp(0.0, 1.0);
    try {
      GoogleCastSessionManager.instance.setDeviceVolume(clamped);
      // Recorded only once the call has gone out, so a rejected change does
      // not leave a slider showing a level the receiver never adopted.
      _setRemoteVolume(clamped);
    } catch (error) {
      _emitError(
        'Could not set the receiver volume: $error',
        FastPixCastErrorCode.volumeFailed,
        cause: error,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Handoff between local and remote playback
  // ---------------------------------------------------------------------

  /// Move playback from [player] to [device], continuing where it left off.
  ///
  /// The order matters. The connection is established *before* local playback
  /// is touched, so a receiver that fails to connect leaves the phone playing
  /// exactly where it was rather than stranding the user on a paused player.
  /// If the receiver connects but the stream fails to load, the session is
  /// torn down and local playback resumes.
  ///
  /// Returns whether playback moved to the receiver.
  Future<bool> startCastingFrom(
    FastPixPlayerController player,
    FastPixCastDevice device,
  ) async {
    _assertNotDisposed();

    final dataSource = player.dataSource;
    if (dataSource == null) {
      throw StateError(
        'The player has no data source to cast. Initialize it first.',
      );
    }

    final position = player.getCurrentPosition() ?? Duration.zero;
    final wasPlaying = player.isPlaying;

    if (!await connect(device)) return false;

    await player.pause();

    try {
      await loadMedia(dataSource, startAt: position, autoPlay: true);
    } catch (_) {
      // The session came up but the stream did not. Hand control straight
      // back rather than leaving both players stopped.
      await disconnect();
      if (wasPlaying) await player.play();
      rethrow;
    }

    return true;
  }

  /// Move playback back from the receiver to [player].
  ///
  /// Reads the receiver's position before tearing the session down, since the
  /// remote client is cleared as the session ends.
  Future<void> stopCastingTo(FastPixPlayerController player) async {
    final position = _lastRemotePosition;
    final wasPlaying = isRemotePlaying;

    await disconnect();

    // The local player may no longer be usable: hosts that unmount it while
    // casting leave its platform controller torn down, and seeking one throws
    // "The video has not been initialized yet". Ending the session still has
    // to succeed, so resuming locally is best effort.
    if (player.betterPlayerController?.isVideoInitialized() != true) {
      _emitError(
        'Casting stopped, but local playback could not resume because the '
        'player is no longer initialized. Keep the player mounted while '
        'casting — hide it rather than removing it — so playback can be '
        'handed back.',
        FastPixCastErrorCode.resumeUnavailable,
      );
      return;
    }

    await player.seekTo(position);
    if (wasPlaying) await player.play();
  }

  // ---------------------------------------------------------------------
  // Stream plumbing
  // ---------------------------------------------------------------------

  void _bindDeviceStream() {
    _devicesSubscription = GoogleCastDiscoveryManager.instance.devicesStream
        .listen(
          _onDevicesChanged,
          onError: (Object error) {
            _fail(
              'Cast device discovery failed: $error',
              FastPixCastErrorCode.discoveryFailed,
              cause: error,
            );
          },
        );
  }

  void _onDevicesChanged(List<GoogleCastDevice> raw) {
    if (_disposed) return;

    final hadDevices = _devices.isNotEmpty;
    final next = List<FastPixCastDevice>.unmodifiable(
      raw.map(FastPixCastDevice.fromPlugin),
    );

    // The platform re-reports the full route list on every MediaRouter
    // callback, which fires many times a second while discovery runs. Emitting
    // an unchanged list makes every listener rebuild that often — enough to
    // visibly stutter a video playing on the same screen.
    if (_sameDevices(_devices, next)) {
      _rawDevices = List<GoogleCastDevice>.unmodifiable(raw);
      return;
    }

    _rawDevices = List<GoogleCastDevice>.unmodifiable(raw);
    _devices = next;
    _devicesController.add(_devices);

    if (!hadDevices && _devices.isNotEmpty) {
      _emit(
        FastPixCastAvailableEvent(
          timestamp: DateTime.now(),
          deviceCount: _devices.length,
        ),
      );
    }

    // A session owns the state while it lasts. Without this guard a routine
    // discovery refresh would knock the controller out of `connecting` or
    // `connected` and the UI would flicker back to the device list mid-cast.
    if (_state.hasSession) return;
    _setState(_stateForDeviceList());
  }

  void _bindSessionStream() {
    _sessionSubscription = GoogleCastSessionManager
        .instance
        .currentSessionStream
        .listen(
          _onSessionChanged,
          onError: (Object error) {
            _fail(
              'Cast session failed: $error',
              FastPixCastErrorCode.sessionFailed,
              cause: error,
            );
          },
        );
  }

  /// Session state is derived here and nowhere else.
  ///
  /// A session can also be started or ended from outside this app — the
  /// Google Home app, another sender, the TV powering off — so treating the
  /// session stream as the single source of truth means all of those paths
  /// are handled without any extra code.
  void _onSessionChanged(GoogleCastSession? session) {
    if (_disposed) return;
    _trace('session event: connectionState=${session?.connectionState}, '
        'device=${session?.device?.friendlyName}');

    switch (session?.connectionState) {
      case GoogleCastConnectState.connecting:
        _setState(FastPixCastState.connecting);

      case GoogleCastConnectState.connected:
        final device = session?.device;
        _connectedDevice =
            device == null ? null : FastPixCastDevice.fromPlugin(device);
        // The one moment the receiver's real level is visible: the session
        // reports it as it connects, and never mentions it again.
        //
        // A reported zero is discarded rather than believed. The plugin uses
        // 0.0 both for "the receiver is muted" and for "no level available",
        // and the second is far more common — it has no volume callback on
        // either platform. Believing it renders a mute icon over a receiver
        // playing at full volume, and because nothing ever corrects the value,
        // that icon stays wrong until the user drags the slider.
        //
        // The failure modes are not symmetric: a wrong mute icon is visible
        // and sticky, while a wrong unmuted icon is corrected by the first
        // [setVolume]. So an unusable reading keeps the 1.0 default.
        final level = session?.currentDeviceVolume;
        if (level != null && level > 0) _setRemoteVolume(level);
        if (!_sessionWasConnected) {
          _sessionWasConnected = true;
          _emit(
            FastPixCastStartedEvent(
              timestamp: DateTime.now(),
              device: _connectedDevice,
            ),
          );
        }
        _setState(FastPixCastState.connected);

      case GoogleCastConnectState.disconnecting:
      case GoogleCastConnectState.disconnected:
      case null:
        _onSessionEnded();
    }
  }

  void _onSessionEnded() {
    final wasConnected = _sessionWasConnected;
    final device = _connectedDevice;

    _sessionWasConnected = false;
    _connectedDevice = null;

    // Tracks belong to the media the ended session was playing. Leaving them
    // would let a subtitle menu offer IDs the next receiver never reported.
    _setTextTracks(const <FastPixCastTextTrack>[]);
    _setActiveTextTrackId(null);
    _activeReceiverTrackIds = const <int>[];

    // The length and play state described the ended session's media. Keeping
    // them would leave a progress bar sitting at a duration nothing is playing.
    _setRemoteDuration(null);
    _setRemotePlaying(false);
    _clearPendingSeek();

    if (wasConnected) {
      _emit(
        FastPixCastEndedEvent(
          timestamp: DateTime.now(),
          device: device,
          position: _lastRemotePosition,
        ),
      );
    }

    _setState(_stateForDeviceList());
  }

  /// Track the subtitle tracks and selection the receiver reports.
  ///
  /// The receiver is the only authority here. Tracks declared in the HLS
  /// manifest are unknown until it parses them, and the selection can be
  /// changed by the TV remote or another sender, so both are read from the
  /// status rather than assumed from what this app last asked for.
  void _bindMediaStatusStream() {
    _mediaStatusSubscription = GoogleCastRemoteMediaClient
        .instance
        .mediaStatusStream
        .listen((GoggleCastMediaStatus? status) {
          if (_disposed) return;
          _setRemoteDuration(status?.mediaInformation?.duration);
          _updateRemotePlaying(status?.playerState);
          final tracks = _textTracksFrom(status);
          _activeReceiverTrackIds =
              status?.activeTrackIds == null
                  ? const <int>[]
                  : List<int>.unmodifiable(status!.activeTrackIds!);
          _setTextTracks(tracks);
          _setActiveTextTrackId(_activeTextTrackIdFrom(status, tracks));
        });
  }

  /// Publish a new media length, ignoring a repeat of the one already known.
  ///
  /// A status arrives several times a second; emitting an unchanged duration
  /// each time would rebuild every progress bar listening for no reason.
  void _setRemoteDuration(Duration? duration) {
    // Zero is how the receiver reports "no length" for a live stream, and a
    // progress bar reading 0:00 as the end is worse than one told nothing.
    final normalized =
        (duration == null || duration == Duration.zero) ? null : duration;
    if (normalized == _remoteDuration) return;
    _remoteDuration = normalized;
    _durationController.add(normalized);
  }

  /// Map a receiver player state onto whether it counts as playing.
  ///
  /// `buffering` deliberately leaves the state alone. The receiver passes
  /// through it on every seek and on every network stall, and treating it as
  /// paused made the play/pause button flip to "play" mid-playback and back
  /// again a moment later — the flicker that made the transport look broken.
  /// `unknown` is ignored for the same reason: it says nothing.
  void _updateRemotePlaying(CastMediaPlayerState? state) {
    switch (state) {
      case CastMediaPlayerState.playing:
        _setRemotePlaying(true);
      case CastMediaPlayerState.paused:
      case CastMediaPlayerState.idle:
        _setRemotePlaying(false);
      default:
        break;
    }
  }

  /// Publish whether the receiver is playing, deduplicated the same way.
  void _setRemotePlaying(bool playing) {
    if (playing == _remotePlaying) return;
    _remotePlaying = playing;
    _playingController.add(playing);
  }

  /// The active *text* track in a media status, or null when none is on.
  ///
  /// `activeTrackIds` lists every active track, audio included — a typical
  /// status reads `[2, 4]` for audio 2 plus subtitles 4. Taking the first ID
  /// would report the audio track as the subtitle selection, leaving no entry
  /// in a subtitle menu matching it and making every tap look ignored. Only an
  /// ID that belongs to a known text track is an answer.
  int? _activeTextTrackIdFrom(
    GoggleCastMediaStatus? status,
    List<FastPixCastTextTrack> textTracks,
  ) {
    final active = status?.activeTrackIds;
    if (active == null || active.isEmpty) return null;

    for (final int id in active) {
      for (final FastPixCastTextTrack track in textTracks) {
        if (track.id == id) return id;
      }
    }
    return null;
  }

  /// Subtitle and caption tracks in a media status, in receiver order.
  List<FastPixCastTextTrack> _textTracksFrom(GoggleCastMediaStatus? status) {
    final tracks = status?.mediaInformation?.tracks;
    if (tracks == null) return const <FastPixCastTextTrack>[];

    return List<FastPixCastTextTrack>.unmodifiable(
      tracks
          .where((track) => track.type == TrackType.text)
          // Chapters, descriptions and script metadata are text tracks too,
          // and offering them as subtitles puts unusable entries in the menu.
          // Excluded by name rather than including by name, because a subtype
          // is often missing or unknown — receivers do not always report one —
          // and dropping those would empty the menu on a stream that has
          // perfectly good captions.
          .where(
            (track) =>
                track.subtype != TextTrackType.chapters &&
                track.subtype != TextTrackType.descriptions &&
                track.subtype != TextTrackType.metadata,
          )
          .map(FastPixCastTextTrack.fromPlugin),
    );
  }

  void _bindPositionStream() {
    _positionSubscription = GoogleCastRemoteMediaClient
        .instance
        .playerPositionStream
        .listen((Duration position) {
          if (_disposed) return;
          _acceptPosition(position);
        });
  }

  /// Decide whether a position the plugin reported is worth believing, and
  /// publish it if so.
  ///
  /// Two kinds of lie have to be caught here, and both of them reach the UI as
  /// the scrubber lurching:
  ///
  /// * **Spurious zero.** `flutter_chrome_cast` seeds its position subject with
  ///   `Duration.zero`, and its Android channel *also* emits `Duration.zero`
  ///   whenever a progress callback arrives with a null payload — which happens
  ///   routinely while the receiver buffers, seeks or goes idle. A playhead
  ///   genuinely at zero only occurs at load, so a zero arriving after playback
  ///   has moved on is discarded rather than shown.
  /// * **Stale post-seek reading.** The receiver keeps reporting where it *was*
  ///   for a few hundred milliseconds after a seek is requested. Those are
  ///   dropped until one lands near the target, so the scrubber does not snap
  ///   back before jumping forward.
  ///
  /// Believing either of them is what made `_seekBy` compute a relative skip
  /// from a bogus base and land somewhere unrelated to where playback was.
  void _acceptPosition(Duration position) {
    if (position == Duration.zero &&
        _lastRemotePosition > _seekArrivalTolerance) {
      return;
    }

    final pending = _pendingSeek;
    if (pending != null) {
      if ((position - pending).abs() > _seekArrivalTolerance) return;
      _clearPendingSeek();
    }

    if (position == _lastRemotePosition) return;
    _lastRemotePosition = position;
    if (!_positionController.isClosed) _positionController.add(position);
  }

  /// Show [target] straight away and stop believing the receiver until it gets
  /// there, so a seek reads as one movement rather than three.
  void _beginSeek(Duration target) {
    _pendingSeekTimer?.cancel();
    _pendingSeek = target;
    _pendingSeekTimer = Timer(_seekConfirmTimeout, _clearPendingSeek);

    _lastRemotePosition = target;
    if (!_positionController.isClosed) _positionController.add(target);
  }

  void _clearPendingSeek() {
    _pendingSeekTimer?.cancel();
    _pendingSeekTimer = null;
    _pendingSeek = null;
  }

  /// Wait for the session stream to settle on connected or not.
  ///
  /// Completes `false` on any terminal state other than connected, so a
  /// rejected connection fails fast instead of running out the timeout.
  Future<bool> _awaitConnected(Duration timeout) {
    if (_state == FastPixCastState.connected) return Future<bool>.value(true);

    final completer = Completer<bool>();
    late final StreamSubscription<FastPixCastState> subscription;

    subscription = _stateController.stream.listen((FastPixCastState state) {
      if (completer.isCompleted) return;
      if (state == FastPixCastState.connected) {
        completer.complete(true);
      } else if (state != FastPixCastState.connecting) {
        completer.complete(false);
      }
    });

    return completer.future
        .timeout(timeout, onTimeout: () => false)
        .whenComplete(subscription.cancel);
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  /// Audio segment hint for the receiver, or null to let it detect.
  CastHlsSegmentFormat? get _castSegmentFormat => switch (segmentFormat) {
    FastPixCastSegmentFormat.auto => null,
    FastPixCastSegmentFormat.fmp4 => CastHlsSegmentFormat.fmp4,
    FastPixCastSegmentFormat.mpegTs => CastHlsSegmentFormat.ts,
  };

  /// Video segment hint for the receiver, or null to let it detect.
  HlsVideoSegmentFormat? get _castVideoSegmentFormat => switch (segmentFormat) {
    FastPixCastSegmentFormat.auto => null,
    FastPixCastSegmentFormat.fmp4 => HlsVideoSegmentFormat.fmp4,
    FastPixCastSegmentFormat.mpegTs => HlsVideoSegmentFormat.mpeg2Ts,
  };

  /// Whether two device lists describe the same receivers, in the same order.
  static bool _sameDevices(
    List<FastPixCastDevice> a,
    List<FastPixCastDevice> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].name != b[i].name) return false;
    }
    return true;
  }

  /// State to fall back to whenever no session is live.
  FastPixCastState _stateForDeviceList() =>
      _devices.isEmpty
          ? FastPixCastState.noDevices
          : FastPixCastState.devicesFound;

  GoogleCastDevice? _rawDeviceFor(FastPixCastDevice device) {
    for (final GoogleCastDevice raw in _rawDevices) {
      if (raw.deviceID == device.id) return raw;
    }
    return null;
  }

  /// Everything the receiver needs that Cast has no standard field for.
  ///
  /// Only DRM uses this today. The payload is namespaced under `fastpix` so a
  /// receiver can tell our data apart from anything else a sender adds.
  Map<String, dynamic>? _buildCustomData(FastPixPlayerDataSource dataSource) {
    final drm = dataSource.drmConfiguration;
    if (drm == null) return null;

    // Cast receivers implement Widevine and nothing else, so the license URL
    // has to be the Widevine one even when the phone is playing the same
    // title locally through FairPlay. [FastPixPlayerDrmConfiguration] derives
    // the URL from the DRM system, so overriding the type is enough — and the
    // FastPix license endpoint carries its token as a query parameter, so the
    // receiver needs no custom headers to use it.
    final widevine = drm.copyWith(drmType: FastPixDrmType.widevine);

    // Flat keys, matching the deployed FastPix receiver, which reads
    // `loadRequest.media.customData.licenseUrl`. The shape is a contract with
    // that page — changing one without the other silently disables DRM, since
    // a receiver that finds no license URL just plays nothing.
    return <String, dynamic>{
      'licenseUrl': widevine.licenseUrl(dataSource.playbackId),
      'protectionSystem': FastPixDrmType.widevine.value,
    };
  }

  List<GoogleCastImage>? _buildImages(FastPixPlayerDataSource dataSource) {
    final url = dataSource.thumbnailUrl ?? dataSource.videoData?.thumbnailUrl;
    if (url == null || url.isEmpty) return null;

    // [VideoDetailsData] defaults its fields to the placeholder "NA" rather
    // than to null, and "NA" parses as a perfectly valid *relative* URI. Left
    // unchecked it reaches the receiver as an image address, which then tries
    // to fetch it. Only an absolute http(s) URL is a real thumbnail.
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    return <GoogleCastImage>[GoogleCastImage(url: uri)];
  }

  /// Convert external subtitle tracks for the receiver.
  ///
  /// Subtitles carried inside the HLS manifest are handled by the receiver
  /// on its own, so only separately hosted tracks need declaring here.
  List<GoogleCastMediaTrack>? _buildTracks(FastPixPlayerDataSource dataSource) {
    final subtitles = dataSource.subtitles;
    if (subtitles == null || subtitles.isEmpty) return null;

    final tracks = <GoogleCastMediaTrack>[];
    for (int i = 0; i < subtitles.length; i++) {
      final subtitle = subtitles[i];
      tracks.add(
        GoogleCastMediaTrack(
          // Track IDs are 1-based by Cast convention; 0 is reserved.
          trackId: i + 1,
          type: TrackType.text,
          subtype: TextTrackType.subtitles,
          trackContentId: subtitle.url,
          trackContentType: 'text/vtt',
          name: subtitle.name,
          language: _languageFor(subtitle.languageCode),
        ),
      );
    }
    return tracks;
  }

  /// Resolve a language code, or null when it is not one Cast recognises.
  ///
  /// `Rfc5646Language.fromMap` answers English for anything it cannot parse,
  /// so an unrecognised code would ship a Spanish track to the receiver
  /// labelled English. Sending no language is the honest answer — the
  /// receiver then falls back to the track's name.
  static Rfc5646Language? _languageFor(String? code) {
    if (code == null || code.isEmpty) return null;
    for (final Rfc5646Language language in Rfc5646Language.values) {
      if (language.value.toLowerCase() == code.toLowerCase()) return language;
    }
    return null;
  }

  /// Tracks to enable on load, honouring
  /// [FastPixPlayerDataSource.showSubtitles].
  List<int>? _activeTrackIds(
    FastPixPlayerDataSource dataSource,
    List<GoogleCastMediaTrack>? tracks,
  ) {
    if (!dataSource.showSubtitles || tracks == null || tracks.isEmpty) {
      return null;
    }

    final subtitles = dataSource.subtitles!;
    for (int i = 0; i < subtitles.length; i++) {
      if (subtitles[i].isDefault) return <int>[tracks[i].trackId];
    }
    return <int>[tracks.first.trackId];
  }

  Future<void> _remote(Future<void> Function() action, String label) async {
    if (!isConnected) return;
    try {
      await action();
    } catch (error) {
      _emitError(
        'Cast $label failed: $error',
        FastPixCastErrorCode.commandFailed,
        cause: error,
      );
    }
  }

  void _setTextTracks(List<FastPixCastTextTrack> next) {
    // Media status arrives on every position tick. Re-emitting an unchanged
    // list would rebuild any subtitle menu that often.
    if (_sameTextTracks(_textTracks, next)) return;
    _textTracks = next;
    if (!_textTracksController.isClosed) _textTracksController.add(next);
  }

  void _setActiveTextTrackId(int? next) {
    if (_activeTextTrackId == next) return;
    _activeTextTrackId = next;
    if (!_activeTextTrackController.isClosed) {
      _activeTextTrackController.add(next);
    }
  }

  static bool _sameTextTracks(
    List<FastPixCastTextTrack> a,
    List<FastPixCastTextTrack> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].label != b[i].label) return false;
    }
    return true;
  }

  void _setRemoteVolume(double next) {
    if (_remoteVolume == next) return;
    _remoteVolume = next;
    if (!_volumeController.isClosed) _volumeController.add(next);
  }

  void _setState(FastPixCastState next) {
    if (_state == next) return;
    _trace('state ${_state.name} -> ${next.name}');
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
    _applyScreenWakelock();
  }

  /// Hold the screen awake for as long as a Cast session is live.
  ///
  /// The local player's `allowedScreenSleep: false` does not cover this. While
  /// casting, that player is paused and offstage — it releases its own
  /// wakelock, and the phone locks a minute later while the television is
  /// still playing. Locking the phone does not stop the receiver, but it does
  /// take away the transport controls mid-programme.
  ///
  /// Best effort: a wakelock that cannot be taken is not a reason to fail a
  /// Cast session that is otherwise working, so failures are swallowed rather
  /// than surfaced.
  void _applyScreenWakelock() {
    unawaited(
      WakelockPlus.toggle(enable: isConnected).catchError((Object _) {}),
    );
  }

  /// Record and report a failure that leaves casting unusable.
  void _fail(String message, FastPixCastErrorCode code, {Object? cause}) {
    _emitError(message, code, cause: cause);
    _setState(FastPixCastState.error);
  }

  /// Record and report a failure that does not invalidate the session.
  ///
  /// A refused load or a failed transport command is not a reason to tear
  /// down a healthy session, so the state is left alone.
  ///
  /// [code] is what the call site knows from context; when [cause] carries a
  /// platform message that identifies something more specific — Play Services
  /// missing, a receiver already in use — that wins, since the call site
  /// cannot tell those apart on its own.
  void _emitError(String message, FastPixCastErrorCode code, {Object? cause}) {
    final event = FastPixCastErrorEvent(
      timestamp: DateTime.now(),
      message: message,
      errorCode: FastPixCastErrorClassifier.classifyOr(cause, code),
      underlyingError: cause?.toString(),
    );
    _lastError = event;
    _emit(event);
  }

  void _emit(FastPixPlayerEvent event) => _eventManager.emit(event);

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('FastPixCastController was used after being disposed.');
    }
  }
}
