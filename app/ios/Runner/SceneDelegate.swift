import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    StartupWatch.shared.arm((scene as? UIWindowScene)?.windows.first)
  }
}
