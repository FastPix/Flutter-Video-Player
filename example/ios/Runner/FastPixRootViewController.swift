import Flutter
import UIKit

/// The app's root view controller, so the fullscreen lock is answered from the
/// one place UIKit always asks.
///
/// `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` is an
/// *app-level* answer, and this app is scene-based — `Info.plist` declares a
/// `UIApplicationSceneManifest`. The answer UIKit is guaranteed to consult,
/// including at the moment it decides how to present an app returning to the
/// foreground, is the root view controller's.
///
/// Named in `Main.storyboard` in place of the stock `FlutterViewController`,
/// which is where this app's root controller is built.
class FastPixRootViewController: FlutterViewController {

  /// Flutter's own preference — what `SystemChrome.setPreferredOrientations`
  /// last asked for — is `super`'s answer, and it still governs every ordinary
  /// screen. A screen that has narrowed the mask wins outright instead of
  /// being intersected with it: on the way back from Picture-in-Picture the
  /// app is presented before the Dart isolate is asked anything, so a stale
  /// Flutter preference must not be able to reintroduce portrait.
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    let appMask = AppDelegate.orientationMask
    return appMask == .allButUpsideDown ? super.supportedInterfaceOrientations : appMask
  }

  override var shouldAutorotate: Bool { true }
}
