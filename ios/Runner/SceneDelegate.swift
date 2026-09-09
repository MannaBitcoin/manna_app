import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        super.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    override func sceneDidBecomeActive(_ scene: UIScene) {
        super.sceneDidBecomeActive(scene)
        updateForegroundState(isForeground: true)
    }

    override func sceneDidEnterBackground(_ scene: UIScene) {
        super.sceneDidEnterBackground(scene)
        updateForegroundState(isForeground: false)
    }

    override func sceneWillEnterForeground(_ scene: UIScene) {
        super.sceneWillEnterForeground(scene)
        updateForegroundState(isForeground: true)
    }

    private func updateForegroundState(isForeground: Bool) {
        if let shared = UserDefaults(suiteName: "group.com.lightning.manna") {
            shared.set(isForeground, forKey: "is_foreground")
        }
    }
}
