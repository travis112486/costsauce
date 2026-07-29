// The CostSauce sync status chip — a small, always-rendered, tappable
// summary of `SyncEngine.state` shown in every main tab's toolbar (§13).
// Purely presentational: the caller decides what a tap does (re-auth sheet
// vs. the pending-queue placeholder) based on the same `state` this view
// was given.

import SwiftUI
import CostSauceKit

struct SyncStatusChip: View {
    let state: SyncState
    let pendingCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                Label(title, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                // `.blocked(.offline(message))` carries the REAL transport/HTTP
                // error the sync engine hit — surfaced here as a visible
                // second line (not just an accessibility value) so a sighted
                // user can tell "no network" apart from "server said no",
                // instead of every blocked-offline case reading identically.
                if let carriedDetail {
                    Text(carriedDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text(title))
        .modifier(CarriedDetailModifier(detail: carriedDetail))
    }

    private var title: String {
        switch state {
        case .idle, .catchingUp:
            return "Syncing…"
        case .caughtUp:
            return "Synced ✓"
        case .blocked(.offline):
            return "\(pendingCount) not synced"
        case .blocked(.authRequired):
            return "Sign-in needed"
        case .blocked(.orgDeleted):
            return "Organization deleted"
        }
    }

    private var systemImage: String {
        switch state {
        case .idle, .catchingUp:
            return "arrow.triangle.2.circlepath"
        case .caughtUp:
            return "checkmark.circle"
        case .blocked(.offline):
            return "exclamationmark.icloud"
        case .blocked(.authRequired):
            return "person.crop.circle.badge.exclamationmark"
        case .blocked(.orgDeleted):
            return "trash"
        }
    }

    /// The carried transport/HTTP message from `.blocked(.offline(_))` —
    /// surfaced both as a visible second line (below) and as an
    /// accessibility value, rather than a hardcoded "You're offline"
    /// string, since the message is whatever the server/transport
    /// actually reported.
    private var carriedDetail: String? {
        if case .blocked(.offline(let message)) = state {
            return message
        }
        return nil
    }
}

private struct CarriedDetailModifier: ViewModifier {
    let detail: String?

    func body(content: Content) -> some View {
        if let detail {
            content.accessibilityValue(Text(detail))
        } else {
            content
        }
    }
}
