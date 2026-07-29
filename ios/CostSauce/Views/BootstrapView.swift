// The CostSauce post-login bootstrap screen — resolves `/me`'s membership
// list down to one organization, that organization's locations down to
// one location, binds the local store to (userId, orgId, locationId), and
// hands off to `MainTabView`. `AppModel.runBootstrap()` (triggered by
// `.task` below) also transparently short-circuits this whole flow on a
// later launch when a local store already matches the session's userId.

import SwiftUI
import CostSauceKit

struct BootstrapView: View {
    let appModel: AppModel

    var body: some View {
        NavigationStack {
            content
        }
        .task {
            await appModel.runBootstrap()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = appModel.bootstrapError {
            ContentUnavailableView(
                "Couldn't Load Your Account",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .safeAreaInset(edge: .bottom) {
                Button("Try Again") {
                    Task { await appModel.runBootstrap() }
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        } else {
            switch appModel.bootstrapStep {
            case .loading:
                ProgressView("Loading your account…")
                    .navigationTitle("CostSauce")

            case .chooseMembership(let memberships):
                List(memberships, id: \.orgId) { membership in
                    Button {
                        Task { await appModel.selectMembership(membership) }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(membership.orgName)
                            Text(membership.role)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Choose an Organization")

            case .noOrganization:
                ContentUnavailableView(
                    "No Organization Yet",
                    systemImage: "building.2",
                    description: Text("This account isn't part of an organization yet. Create one on the web app.")
                )

            case .chooseLocation(let locations):
                List(locations) { location in
                    Button(location.name) {
                        appModel.selectLocation(location)
                    }
                }
                .navigationTitle("Choose a Location")

            case .noLocations:
                ContentUnavailableView(
                    "No Locations Yet",
                    systemImage: "mappin.slash",
                    description: Text("This organization has no locations yet — add one on the web app.")
                )
            }
        }
    }
}
