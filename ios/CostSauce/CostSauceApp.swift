import SwiftUI
import CostSauceKit

@main
struct CostSauceApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(appModel: appModel)
        }
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
                IdentityMismatchPlaceholderView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await appModel.refreshOnlineData() }
            }
        }
    }
}

/// `store.bind` throwing `identityMismatch` routes here. Task 14 builds
/// the real screen (export pending changes / switch-and-erase / cancel);
/// this is a deliberately minimal, action-less placeholder standing in
/// for it (see task-9-report.md's hand-off notes).
private struct IdentityMismatchPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Different Account Signed In",
            systemImage: "person.crop.circle.badge.exclamationmark",
            description: Text("This device holds unsynced changes for a different account. Recovery options arrive in a later task.")
        )
    }
}
