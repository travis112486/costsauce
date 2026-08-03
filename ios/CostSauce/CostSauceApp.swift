import SwiftUI
import UIKit
import CostSauceKit

@main
struct CostSauceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(appModel: appModel)
        }
    }
}

/// Exists for exactly one UIKit callback: the background upload session's
/// relaunch handshake. When a background session's transfers finish while
/// the app is dead, iOS relaunches it headless, hands this method a
/// completion handler, and expects it back once the session's events have
/// been delivered (BackgroundUploader's urlSessionDidFinishEvents is the
/// one consumer). The handler is parked STATICALLY because on that
/// headless relaunch this delegate exists before any scene -- or any
/// wiring a scene's appearance would have done -- so an instance property
/// somebody must remember to connect would be nil exactly when it matters.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploader.sessionIdentifier else {
            completionHandler()
            return
        }
        Self.backgroundCompletionHandler = completionHandler
    }
}

/// Switches on `AppModel.phase` and — the one piece of scenePhase wiring
/// this task owns — refreshes online data (session refresh, sync, cached
/// `currentLocation`) whenever the app becomes active.
private struct RootView: View {
    let appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch appModel.phase {
            case .login:
                NavigationStack {
                    LoginView(appModel: appModel) { session in
                        appModel.completeInitialSignIn(session: session)
                    }
                    .navigationTitle("CostSauce")
                }
            case .bootstrap:
                BootstrapView(appModel: appModel)
            case .main:
                MainTabView(appModel: appModel)
            case .identityMismatch:
                IdentityMismatchView(appModel: appModel)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await appModel.refreshOnlineData() }
            }
        }
    }
}
