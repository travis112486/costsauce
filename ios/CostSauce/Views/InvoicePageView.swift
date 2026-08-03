// One invoice's pages: zoomable, selectable when there is more than one,
// and the launch point for photo-assisted entry -- "Add purchase from this
// page" pushes the ordinary purchase form with this page's id, so the
// purchase minted there carries `invoice_page_id` (spec §9, 3a-D5).
//
// The image comes off the local file when it exists. When it does not --
// eviction removes the file, never the row, and a page pulled from another
// device never had one here -- the view says so plainly rather than
// spinning: re-downloading an uploaded page from storage is 3b's, arriving
// with the signed-download endpoint the parser work introduces.

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

    var body: some View {
        content
            .navigationTitle("Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                load()
            }
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
                }
            } else {
                ContentUnavailableView(
                    "Photo Not on This Device", systemImage: "icloud",
                    description: Text(
                        "This page was uploaded and its local copy is no longer cached here."))
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
}
