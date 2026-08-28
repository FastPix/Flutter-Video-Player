import 'dart:async';

import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/widgets.dart';

/// Holds the app's cast controller.
///
/// App-scoped rather than screen-scoped because a session is expected to
/// outlive the screen that started it: rebuilding the controller on every
/// navigation would drop a live cast every time the viewer went back home.
class CastService extends ChangeNotifier with WidgetsBindingObserver {
  CastService._();

  static final CastService instance = CastService._();

  /// FastPix's registered custom receiver.
  ///
  /// Required for DRM: Google's Default Media Receiver cannot perform a
  /// license request. The receiver page forces fMP4 itself, so the segment
  /// format hint below only matters on the default receiver.
  static const String receiverAppId = 'F9461BDD';

  FastPixCastController? _controller;

  /// Whether streams are packaged as fMP4/CMAF.
  ///
  /// A cast that connects and shows the title but never plays is almost
  /// always this: the receiver assumed MPEG-TS and the stream is fMP4. Fixed
  /// per session, so changing it rebuilds the controller.
  bool _useFmp4 = true;

  FastPixCastState _state = FastPixCastState.unavailable;
  List<FastPixCastDevice> _devices = const <FastPixCastDevice>[];
  List<FastPixCastTextTrack> _textTracks = const <FastPixCastTextTrack>[];
  int? _activeTextTrackId;

  final List<String> _events = <String>[];

  StreamSubscription<FastPixCastState>? _stateSubscription;
  StreamSubscription<List<FastPixCastDevice>>? _devicesSubscription;
  StreamSubscription<List<FastPixCastTextTrack>>? _textTracksSubscription;
  StreamSubscription<int?>? _activeTextTrackSubscription;

  FastPixCastController get controller => _controller!;
  bool get isReady => _controller != null;

  bool get useFmp4 => _useFmp4;
  FastPixCastState get state => _state;
  List<FastPixCastDevice> get devices => _devices;
  List<FastPixCastTextTrack> get textTracks => _textTracks;
  int? get activeTextTrackId => _activeTextTrackId;
  FastPixCastErrorEvent? get lastError => _controller?.lastError;
  FastPixCastDevice? get connectedDevice => _controller?.connectedDevice;

  /// Recent cast and playback events, newest first.
  List<String> get events => List<String>.unmodifiable(_events);

  /// Whether the lifecycle observer is registered.
  ///
  /// Tracked separately from [_controller]: that goes null while the controller
  /// is rebuilt, and keying the registration off it would add a second observer
  /// each time — every one of which would then try to end the same session.
  bool _observingLifecycle = false;

  Future<void> start() async {
    if (_controller != null) return;
    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }
    await _build();
  }

  /// Pause device discovery while the app is away, and nothing more.
  ///
  /// A live session is deliberately left running. Cast is built so a session
  /// outlives the sender — the whole point is that the TV keeps playing once
  /// you have put your phone down — and every cast app behaves that way. The
  /// viewer stops casting by choosing to: the cast button on the casting
  /// surface hands playback back to the local player and ends the session.
  ///
  /// Only discovery is stopped, because scanning is battery and Wi-Fi
  /// expensive and there is nobody looking at a device list. The controller
  /// stays as it is: the app may come straight back, and rebuilding it would
  /// drop the live cast this exists to protect.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_pauseDiscovery());
      case AppLifecycleState.resumed:
        unawaited(_resumeDiscovery());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Transient — a notification shade, a call, the app switcher preview.
        // Restarting discovery on the way back out of one would just churn.
        break;
    }
  }

  Future<void> _pauseDiscovery() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.stopDiscovery();
  }

  Future<void> _resumeDiscovery() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.startDiscovery();
  }

  Future<void> _build() async {
    final controller = FastPixCastController(
      appId: receiverAppId,
      verbose: true,
      segmentFormat:
          _useFmp4
              ? FastPixCastSegmentFormat.fmp4
              : FastPixCastSegmentFormat.auto,
    );
    _controller = controller;

    controller.addGlobalListener((event) => log('cast: ${event.type}'));

    _stateSubscription = controller.stateStream.listen((state) {
      _state = state;
      notifyListeners();
    });
    _devicesSubscription = controller.devicesStream.listen((devices) {
      _devices = devices;
      notifyListeners();
    });
    _textTracksSubscription = controller.textTracksStream.listen((tracks) {
      _textTracks = tracks;
      notifyListeners();
    });
    _activeTextTrackSubscription = controller.activeTextTrackStream.listen((
      id,
    ) {
      _activeTextTrackId = id;
      notifyListeners();
    });

    await controller.initialize();

    // Discovery is battery and Wi-Fi expensive. The demo scopes it to the app
    // being in the foreground on a player-centric app; a broader app should
    // start it when cast UI opens and stop it when it closes.
    await controller.startDiscovery();

    _state = controller.state;
    notifyListeners();
  }

  /// Rebuild the controller with a different segment format.
  Future<void> setSegmentFormat(bool useFmp4) async {
    await _teardown();
    _useFmp4 = useFmp4;
    _state = FastPixCastState.unavailable;
    _devices = const <FastPixCastDevice>[];
    _textTracks = const <FastPixCastTextTrack>[];
    _activeTextTrackId = null;
    notifyListeners();
    await _build();
  }

  Future<void> rescan() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.stopDiscovery();
    await controller.startDiscovery();
  }

  Future<void> _teardown() async {
    await _stateSubscription?.cancel();
    await _devicesSubscription?.cancel();
    await _textTracksSubscription?.cancel();
    await _activeTextTrackSubscription?.cancel();
    _stateSubscription = null;
    _devicesSubscription = null;
    _textTracksSubscription = null;
    _activeTextTrackSubscription = null;

    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    await controller.stopDiscovery();
    // Deliberately does not end a live session: casting outlives the app's UI.
    await controller.dispose();
  }

  void log(String message) {
    _events.insert(0, message);
    if (_events.length > 60) _events.removeLast();
    notifyListeners();
  }

  void clearLog() {
    _events.clear();
    notifyListeners();
  }
}
