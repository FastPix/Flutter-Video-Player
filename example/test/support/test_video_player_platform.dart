// Copied from the package's own test support, because test files are not
// exported between packages. Keep the two in step when either changes.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for the platform video player, so controller behaviour that only
/// shows up around a *live* engine — releasing the outgoing player, rebinding
/// views, advancing a playlist on completion — can be tested without a device.
///
/// The engine talks to the platform over one method channel plus a per-texture
/// event channel. Both are mocked here: method calls are recorded and answered
/// with plausible values, and [emit] pushes an event back up the event channel
/// exactly as the native side would.
class TestVideoPlayerPlatform {
  TestVideoPlayerPlatform._();

  static final TestVideoPlayerPlatform instance = TestVideoPlayerPlatform._();

  static const MethodChannel _channel = MethodChannel('better_player_channel');

  /// Every method call the engine made, in order.
  final List<MethodCall> calls = <MethodCall>[];

  /// Texture ids handed out by `create`, in order.
  final List<int> created = <int>[];

  /// Texture ids the engine asked to `dispose`, in order.
  final List<int> disposed = <int>[];

  /// Texture ids created and not yet disposed — the platform players alive.
  List<int> get alive =>
      created.where((id) => !disposed.contains(id)).toList(growable: false);

  int _nextTextureId = 1;

  /// Position reported by `position`, per texture.
  final Map<int, Duration> positions = <int, Duration>{};

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Install the test and clear anything a previous test left behind.
  void install() {
    reset();
    _messenger.setMockMethodCallHandler(_channel, _handle);
    _installSideChannels();
  }

  /// Channels the player pulls in through its dependencies rather than for
  /// playback: connectivity, which the preload manager and the metrics beacon
  /// both consult. Left unmocked they throw `MissingPluginException` from a
  /// stream activation, which fails whichever test happened to be running.
  static const List<String> _sideChannels = <String>[
    'dev.fluttercommunity.plus/connectivity',
    'dev.fluttercommunity.plus/connectivity_status',
  ];

  void _installSideChannels() {
    for (final name in _sideChannels) {
      _messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => call.method == 'check' ? <String>['wifi'] : null,
      );
    }
  }

  void reset() {
    calls.clear();
    created.clear();
    disposed.clear();
    positions.clear();
    _nextTextureId = 1;
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(_channel, null);
    for (final name in _sideChannels) {
      _messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    for (final id in created) {
      _messenger.setMockMethodCallHandler(_eventChannel(id), null);
    }
    reset();
  }

  MethodChannel _eventChannel(int textureId) =>
      MethodChannel('better_player_channel/videoEvents$textureId');

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    final arguments = call.arguments;
    final int? textureId =
        arguments is Map ? arguments['textureId'] as int? : null;
    switch (call.method) {
      case 'create':
        final id = _nextTextureId++;
        created.add(id);
        positions[id] = Duration.zero;
        // The engine subscribes to this channel as soon as it has the id.
        _messenger.setMockMethodCallHandler(_eventChannel(id), (_) async => null);
        return <String, dynamic>{'textureId': id};
      case 'dispose':
        if (textureId != null && !disposed.contains(textureId)) {
          disposed.add(textureId);
        }
        return null;
      case 'position':
        return (positions[textureId] ?? Duration.zero).inMilliseconds;
      case 'absolutePosition':
        return 0;
      case 'isPictureInPictureSupported':
        return false;
      case 'seekTo':
        final location = arguments is Map ? arguments['location'] as int? : null;
        if (textureId != null && location != null) {
          positions[textureId] = Duration(milliseconds: location);
        }
        return null;
      default:
        return null;
    }
  }

  /// Push a platform event for [textureId], as the native side would.
  Future<void> emit(int textureId, Map<String, dynamic> event) async {
    await _messenger.handlePlatformMessage(
      'better_player_channel/videoEvents$textureId',
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) {},
    );
  }

  /// The engine treats a source as usable only once it reports `initialized`.
  Future<void> emitInitialized(
    int textureId, {
    Duration duration = const Duration(minutes: 10),
    double width = 1920,
    double height = 1080,
  }) => emit(textureId, <String, dynamic>{
    'event': 'initialized',
    'duration': duration.inMilliseconds,
    'width': width,
    'height': height,
  });

  /// Report a platform failure, as the native side does over the error
  /// channel rather than as an event.
  Future<void> emitError(int textureId, String message) async {
    await _messenger.handlePlatformMessage(
      'better_player_channel/videoEvents$textureId',
      const StandardMethodCodec().encodeErrorEnvelope(
        code: 'VideoError',
        message: message,
        details: null,
      ),
      (_) {},
    );
  }

  Future<void> emitCompleted(int textureId) =>
      emit(textureId, <String, dynamic>{'event': 'completed'});

  Future<void> emitPlay(int textureId) =>
      emit(textureId, <String, dynamic>{'event': 'play'});

  Future<void> emitPause(int textureId) =>
      emit(textureId, <String, dynamic>{'event': 'pause'});

  Future<void> emitBufferingStart(int textureId) =>
      emit(textureId, <String, dynamic>{'event': 'bufferingStart'});

  Future<void> emitBufferingEnd(int textureId) =>
      emit(textureId, <String, dynamic>{'event': 'bufferingEnd'});
}
