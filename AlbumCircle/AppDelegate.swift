import UIKit
import SwiftUI
import CloudKit
import BackgroundTasks

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: PendingImports.identifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { @MainActor in
                let finished = await AlbumImporter.resumePending()
                processing.setTaskCompleted(success: finished)
            }
            processing.expirationHandler = {
                work.cancel()
                Task { @MainActor in CloudStore.shared.expireImport() }
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: PhotoBackup.identifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                let success = await PhotoBackup.shared.runIfDue()
                processing.setTaskCompleted(success: success)
            }
            processing.expirationHandler = {
                work.cancel()
                Task { @MainActor in PhotoBackup.shared.cancel() }
            }
        }
        Task { @MainActor in PhotoBackup.shared.clockChanged() }
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in await CloudStore.shared.accept(metadata) }
    }
}
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AlbumsView())
        self.window = window
        window.makeKeyAndVisible()
        if let metadata = options.cloudKitShareMetadata {
            Task { @MainActor in await CloudStore.shared.accept(metadata) }
        }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in await CloudStore.shared.accept(metadata) }
    }
}
