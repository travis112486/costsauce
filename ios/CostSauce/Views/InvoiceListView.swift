// The captured-invoices list. Every row is a pure rendering of
// already-local data -- `LocalStore.liveInvoices()` newest first, one
// `livePages` read per invoice for the page count, and the upload outbox
// for the "still uploading" indicator (§9: a page that has not landed is
// unsynced data, and this list is where that state is visible per-invoice
// rather than as one aggregate badge).
//
// Capture itself is reached from here ("Capture Invoice" in the toolbar):
// the list is the natural home for both directions of the flow -- see
// what has been captured, and capture more.

import SwiftUI
import CostSauceKit

struct InvoiceListView: View {
    let appModel: AppModel

    @State private var invoices: [LocalInvoice]?
    @State private var pageCounts: [String: Int] = [:]
    @State private var uploadingInvoiceIds: Set<String> = []
    @State private var loadError: String?

    var body: some View {
        content
            .navigationTitle("Invoices")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        InvoiceCaptureView(appModel: appModel)
                    } label: {
                        // 44pt with a filled content shape -- the same fix
                        // the Dashboard "+" needed to be reliably tappable.
                        Label("Capture Invoice", systemImage: "doc.viewfinder")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Capture Invoice")
                }
            }
            .task(id: RefreshKey(appModel: appModel)) {
                load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                "Couldn't Load Invoices", systemImage: "exclamationmark.triangle",
                description: Text(loadError))
        } else if let invoices {
            if invoices.isEmpty {
                ContentUnavailableView(
                    "No Invoices Yet", systemImage: "doc.viewfinder",
                    description: Text("Capture a delivery invoice to keep its pages with your purchases."))
            } else {
                invoiceList(invoices)
            }
        } else {
            ProgressView()
        }
    }

    private func invoiceList(_ invoices: [LocalInvoice]) -> some View {
        List(invoices, id: \.id) { invoice in
            NavigationLink {
                InvoicePageView(appModel: appModel, invoiceId: invoice.id)
            } label: {
                InvoiceRow(
                    capturedOn: String(invoice.captured_at.prefix(10)),
                    pageCount: pageCounts[invoice.id] ?? 0,
                    isUploading: uploadingInvoiceIds.contains(invoice.id))
            }
        }
    }

    private func load() {
        guard let store = appModel.store else { return }
        loadError = nil
        do {
            let live = try store.liveInvoices()
            // Pages still waiting on storage: anything the outbox has not
            // marked `uploaded` yet, mapped back to its owning invoice.
            let unUploadedPageIds = Set(
                try store.pendingUploads()
                    .filter { $0.state != PendingUpload.State.uploaded.rawValue }
                    .map(\.page_id))
            var counts: [String: Int] = [:]
            var uploading: Set<String> = []
            for invoice in live {
                let pages = try store.livePages(invoiceId: invoice.id)
                counts[invoice.id] = pages.count
                if pages.contains(where: { unUploadedPageIds.contains($0.id) }) {
                    uploading.insert(invoice.id)
                }
            }
            invoices = live
            pageCounts = counts
            uploadingInvoiceIds = uploading
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct InvoiceRow: View {
    let capturedOn: String
    let pageCount: Int
    let isUploading: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(capturedOn)
                    .font(.headline)
                Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isUploading {
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Uploading")
            } else {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Uploaded")
            }
        }
    }
}

private struct RefreshKey: Equatable {
    let syncState: SyncState
    let pendingCount: Int

    @MainActor
    init(appModel: AppModel) {
        syncState = appModel.syncState
        pendingCount = appModel.pendingCount
    }
}
