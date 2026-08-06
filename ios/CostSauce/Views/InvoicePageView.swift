// One invoice's pages: zoomable, selectable when there is more than one,
// and the launch point for photo-assisted entry -- "Add purchase from this
// page" pushes the ordinary purchase form with this page's id, so the
// purchase minted there carries `invoice_page_id` (spec §9, 3a-D5).
//
// The image comes off the local file when it exists. When it does not --
// eviction removes the file, never the row, and a page pulled from another
// device never had one here -- the view re-downloads it from storage via
// the signed-download endpoint and holds the bytes in memory only: writing
// them back to disk would just have the age-based eviction sweep delete
// them again on the next foreground pass.

import SwiftUI
import UIKit
import CostSauceKit

struct InvoicePageView: View {
    let appModel: AppModel
    let invoiceId: String

    @State private var pages: [LocalInvoicePage]?
    @State private var selectedPageId: String?
    @State private var steadyZoom: CGFloat = 1
    @GestureState private var gestureZoom: CGFloat = 1

    /// Re-downloaded bytes live HERE and never touch disk. Writing them back
    /// would thrash: the age rule evicts any uploaded page past 90 days
    /// regardless of size, so a restored old page would be deleted again on
    /// the very next foreground sweep -- and old invoices are exactly the
    /// ones people reopen during a dispute.
    ///
    /// Keyed by page id, same as `downloaded` -- on a multi-page invoice
    /// each page has its own in-flight/failure state. A single shared flag
    /// would let page 2 render page 1's outcome (or vice versa) purely
    /// because it happened to be the page open when that outcome landed.
    @State private var downloaded: [String: UIImage] = [:]
    @State private var downloadFailures: [String: DownloadFailure] = [:]
    @State private var downloadingPageIds: Set<String> = []

    private enum DownloadFailure: Equatable { case offline, failed }

    var body: some View {
        content
            .navigationTitle("Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                load()
            }
            // Re-keyed on the selected page id, not just once on appear, so
            // switching pages via the Picker attempts a download for the
            // newly selected page instead of leaving it untried while
            // showing whatever state the previously selected page left
            // behind.
            //
            // The work is handed to an UNSTRUCTURED Task on purpose. This
            // view is a NavigationLink destination, and the push transition
            // is still animating when `.task(id:)` starts -- reproducibly,
            // it cancelled the request about 14ms in, on the feature's
            // PRIMARY path (runbook §6.3). Because `selectedPageId` does not
            // change across that cancellation, `.task(id:)` never fires
            // again, so the first attempt was also the last. An unstructured
            // Task inherits the actor but NOT the cancellation -- the one
            // difference that has always made the Retry button succeed where
            // the automatic attempt could not.
            .task(id: selectedPageId) {
                Task { @MainActor in await downloadSelectedPageIfNeeded() }
            }
    }

    private func downloadSelectedPageIfNeeded() async {
        guard let pages, let page = selectedPage(in: pages),
              localImage(for: page) == nil,
              downloaded[page.id] == nil,
              downloadFailures[page.id] == nil,
              !downloadingPageIds.contains(page.id)
        else { return }
        await download(page)
    }

    @ViewBuilder
    private var content: some View {
        if let pages {
            if let page = selectedPage(in: pages) {
                pageView(page, pages: pages)
            } else {
                ContentUnavailableView(
                    "No Pages", systemImage: "doc.viewfinder",
                    description: Text("Every page of this invoice has been removed."))
            }
        } else {
            ProgressView()
        }
    }

    private func pageView(_ page: LocalInvoicePage, pages: [LocalInvoicePage]) -> some View {
        VStack(spacing: 12) {
            if pages.count > 1 {
                Picker("Page", selection: pageSelection) {
                    ForEach(pages, id: \.id) { candidate in
                        Text("Page \(candidate.page_no)").tag(candidate.id)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            if let image = localImage(for: page) {
                pageImage(image, page: page, identifier: "pageImage.local")
            } else if let image = downloaded[page.id] {
                pageImage(image, page: page, identifier: "pageImage.downloaded")
            } else if downloadingPageIds.contains(page.id) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailable(page)
            }

            NavigationLink {
                PurchaseEntryView(appModel: appModel, invoicePageId: page.id)
                    .navigationTitle("Add Purchase")
            } label: {
                Label("Add purchase from this page", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .padding([.horizontal, .bottom])
            .accessibilityLabel("Add purchase from this page")
        }
    }

    /// One definition of the zoom and accessibility behaviour for a rendered
    /// page image, called by both the local-file branch and the
    /// re-downloaded branch -- so a future change to either can't land on
    /// only one copy.
    ///
    /// The two branches share a LABEL and differ by IDENTIFIER. The label
    /// says what the thing is, which is all VoiceOver should care about --
    /// where the bytes came from is not the user's problem. The identifier
    /// says which branch drew it, which the acceptance walk very much does
    /// care about: with one shared label, a walk asserting "the page image
    /// is on screen" passes identically whether the sweep evicted the file
    /// and storage gave it back or the sweep silently stopped deleting
    /// anything at all.
    @ViewBuilder
    private func pageImage(_ image: UIImage, page: LocalInvoicePage,
                           identifier: String) -> some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(zoom)
                .clipped()
                .contentShape(Rectangle())
                .gesture(magnification)
                .accessibilityLabel("Invoice page \(page.page_no)")
                .accessibilityIdentifier(identifier)
        }
    }

    // MARK: - zoom

    private var zoom: CGFloat { steadyZoom * gestureZoom }

    private var magnification: some Gesture {
        MagnifyGesture()
            .updating($gestureZoom) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                steadyZoom = min(max(steadyZoom * value.magnification, 1), 5)
            }
    }

    // MARK: - data

    private func load() {
        guard let store = appModel.store else { return }
        let loaded = (try? store.livePages(invoiceId: invoiceId)) ?? []
        pages = loaded
        if selectedPageId == nil {
            selectedPageId = loaded.first?.id
        }
    }

    private func selectedPage(in pages: [LocalInvoicePage]) -> LocalInvoicePage? {
        pages.first { $0.id == selectedPageId } ?? pages.first
    }

    /// Selecting a different page resets the zoom -- carrying page 1's
    /// close-up over to page 2 shows an arbitrary crop of the wrong page.
    private var pageSelection: Binding<String> {
        Binding(
            get: { selectedPageId ?? "" },
            set: { newValue in
                selectedPageId = newValue
                steadyZoom = 1
            })
    }

    private func localImage(for page: LocalInvoicePage) -> UIImage? {
        guard let pageNo = Int(page.page_no),
              let fileURL = try? InvoiceFiles.url(invoiceId: page.invoice_id, pageNo: pageNo)
        else { return nil }
        return UIImage(contentsOfFile: fileURL.path)
    }

    // MARK: - download

    /// Three states, not two, because "no photo" has three causes and only
    /// two of them are failures.
    ///
    /// `nil` means no attempt has FINISHED -- the automatic one may not have
    /// started yet, or something cancelled it. Reporting that as
    /// "Photo Couldn't Be Loaded" claims an attempt was made and lost, which
    /// is a lie whenever it is not true, and it was not true on this view's
    /// primary path for as long as the push transition kept cancelling the
    /// first attempt. Neutral copy and a "Load Photo" button say the same
    /// thing honestly and read identically to a user who then taps it.
    ///
    /// Offline and broken keep DIFFERENT copy: someone in a walk-in cooler
    /// needs to know whether waiting will help. Everything that is not a
    /// transport failure -- including the endpoint's 409 -- is the generic
    /// error, because a 409 is unreachable for a page this device evicted
    /// and a third message for an unactionable case is not worth the string.
    @ViewBuilder
    private func unavailable(_ page: LocalInvoicePage) -> some View {
        let failure = downloadFailures[page.id]
        VStack(spacing: 12) {
            if failure == .offline {
                ContentUnavailableView(
                    "Photo Needs a Connection", systemImage: "icloud.slash",
                    description: Text("It's stored safely — reconnect to view it."))
            } else if failure == .failed {
                ContentUnavailableView(
                    "Photo Couldn't Be Loaded", systemImage: "icloud",
                    description: Text("This page's photo isn't on this device."))
            } else {
                ContentUnavailableView(
                    "Photo Not Downloaded Yet", systemImage: "icloud.and.arrow.down",
                    description: Text("It's stored safely — it just isn't on this device."))
            }
            Button(failure == nil ? "Load Photo" : "Retry") {
                Task { await download(page) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("retryPageDownload")
        }
    }

    private func download(_ page: LocalInvoicePage) async {
        guard let pageNo = Int(page.page_no) else {
            downloadFailures[page.id] = .failed
            return
        }
        downloadingPageIds.insert(page.id)
        downloadFailures[page.id] = nil
        defer { downloadingPageIds.remove(page.id) }
        do {
            let signed = try await appModel.api.downloadURL(
                invoiceId: page.invoice_id, pageNo: pageNo)
            guard let url = URL(string: signed.url) else {
                downloadFailures[page.id] = .failed
                return
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                downloadFailures[page.id] = .failed
                return
            }
            downloaded[page.id] = image
        } catch is CancellationError {
            // Cancellation is not a failure and must never be recorded as
            // one. Leaving `downloadFailures[page.id]` nil holds the view in
            // its neutral not-downloaded-yet state, which is the truth: an
            // attempt was started and abandoned, so nothing is known about
            // whether the bytes are reachable.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession bridges a cancelled wrapping Task into
            // URLError(.cancelled) rather than CancellationError, so the two
            // spellings need identical no-op treatment.
        } catch let error as URLError where
            error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            downloadFailures[page.id] = .offline
        } catch {
            downloadFailures[page.id] = .failed
        }
    }
}
