import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  /// What this app supports right now, as the *window* sees it.
  ///
  /// Defaults to the full set from `Info.plist`, so ordinary screens keep
  /// behaving exactly as they did and `SystemChrome.setPreferredOrientations`
  /// still narrows things from Dart the way it always has. This only ever
  /// tightens further when a screen explicitly says it is presenting
  /// fullscreen.
  ///
  /// **Why this exists.** iOS decides an app's orientation as it brings the app
  /// to the foreground, and it asks *here* — before the Dart isolate is asked
  /// anything at all. A screen that locked itself to landscape from Dart has
  /// therefore already lost the race by the time it hears
  /// `AppLifecycleState.resumed`: the app is presented using the `Info.plist`
  /// order, which lists Portrait first, and only rotates a second or two later
  /// when Flutter re-applies its preference and iOS re-evaluates. That is the
  /// portrait flash seen coming back from a Picture-in-Picture window that was
  /// opened from fullscreen.
  ///
  /// Setting this from Dart before leaving the app means iOS has the right
  /// answer at the moment it needs it, so the app comes back already landscape
  /// with nothing to rotate.
  static var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown

  /// Covers the window while the app is not active, so the snapshot iOS takes
  /// on the way out is a plain black frame.
  ///
  /// **Why this exists.** iOS paints a cached snapshot of the app during the
  /// transition back to the foreground, before the first live frame arrives.
  /// While a screen is presenting fullscreen the root view controller permits
  /// landscape only, so the *live* view cannot be portrait — yet a portrait
  /// frame is still visible for about a second on the way back from
  /// Picture-in-Picture. That frame is the snapshot, taken or kept from a
  /// portrait rendering of the app, and no orientation lock can reach it: it
  /// is a bitmap, not a view hierarchy.
  ///
  /// What *is* reachable is what the snapshot contains. Covering the window
  /// before the app deactivates means the cached frame is black rather than a
  /// portrait layout, so the return reads as black-then-fullscreen instead of
  /// portrait-then-rotate.
  ///
  /// Deliberately scoped to the fullscreen lock: ordinary screens are snapshot
  /// exactly as they are today, and nothing here runs for them.
  private static var snapshotCover: UIView?

  private static var isFullscreenLocked: Bool { orientationMask == .landscape }

  private static func addSnapshotCover(to scene: UIWindowScene) {
    guard isFullscreenLocked, snapshotCover == nil,
          let window = scene.keyWindow else { return }
    let cover = UIView(frame: window.bounds)
    cover.backgroundColor = .black
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // Above the Flutter view but a sibling of it: the video layer AVKit lifts
    // for a Picture-in-Picture window is untouched, so covering the window
    // cannot affect what that window renders.
    window.addSubview(cover)
    snapshotCover = cover
  }

  private static func removeSnapshotCover() {
    snapshotCover?.removeFromSuperview()
    snapshotCover = nil
  }

  override func application(
    _: UIApplication,
    supportedInterfaceOrientationsFor _: UIWindow?
  ) -> UIInterfaceOrientationMask {
    // Diagnostic: this is the question iOS asks as it presents the app, and
    // the answer decides whether it comes back landscape or rotates later.
    // If this never logs around a PiP return, the mask is not the mechanism.
    NSLog("[FastPixOrientation] iOS asked; answering mask=%lu (landscape=%@)",
          AppDelegate.orientationMask.rawValue,
          AppDelegate.orientationMask == .landscape ? "YES" : "NO")
    return AppDelegate.orientationMask
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Unconditional, and the first thing this app can possibly log. UIKit calls
    // this for every launch, so if it is missing from a device log the binary
    // on the device is not built from this source — which no amount of Dart
    // logging can tell you, because Dart hot-restarts independently of native.
    NSLog("[FastPixOrientation] AppDelegate launched — native build is current")

    // Scene notifications rather than UIApplicationDelegate callbacks: this app
    // is scene-based (`Info.plist` declares a `UIApplicationSceneManifest`), so
    // the application-level foreground/background callbacks are never called,
    // and observing keeps this out of `FlutterSceneDelegate`'s way.
    let center = NotificationCenter.default
    center.addObserver(forName: UIScene.willDeactivateNotification,
                       object: nil, queue: .main) { note in
      guard let scene = note.object as? UIWindowScene else { return }
      AppDelegate.addSnapshotCover(to: scene)
    }
    center.addObserver(forName: UIScene.didActivateNotification,
                       object: nil, queue: .main) { _ in
      AppDelegate.removeSnapshotCover()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    NSLog("[FastPixOrientation] engine bridge ready; registering channel")
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Demo-level, not part of the SDK: fullscreen is the application's to own
    // in the custom-UI pattern, and so is restoring it. The player package
    // stays out of orientation entirely.
    let channel = FlutterMethodChannel(
      name: "fastpix_demo/orientation",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())

    channel.setMethodCallHandler { call, result in
      guard call.method == "set" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let fullscreen =
        (call.arguments as? [String: Any])?["fullscreen"] as? Bool ?? false
      AppDelegate.orientationMask = fullscreen ? .landscape : .allButUpsideDown

      // Ask iOS to re-evaluate now rather than at the next natural opportunity,
      // so a change made while the app is on screen takes effect immediately.
      if #available(iOS 16.0, *) {
        UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }
          .forEach { scene in
            scene.keyWindow?.rootViewController?
              .setNeedsUpdateOfSupportedInterfaceOrientations()
          }
      } else {
        UIViewController.attemptRotationToDeviceOrientation()
      }

      // Answered rather than logged, because `NSLog` is invisible: on iOS 17+
      // the device log is not forwarded to the `flutter run` console, so a
      // native-side check cannot be read during an ordinary debug session.
      //
      // `rootVC` is the load-bearing one. The lock is only in the path if the
      // storyboard actually instantiated `FastPixRootViewController`; if this
      // says `FlutterViewController`, the subclass never took and the mask is
      // being answered app-level, which is not guaranteed to be consulted in a
      // scene-based app.
      let rootVC = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }?
        .keyWindow?.rootViewController
      result([
        "rootVC": rootVC.map { String(describing: type(of: $0)) } ?? "none",
        "locked": fullscreen,
      ])
    }
  }
}
