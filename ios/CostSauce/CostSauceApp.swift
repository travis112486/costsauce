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
