// Capture an invoice: scan pages, gate them on quality, and mint rows and
// bytes locally before anything touches the network.
//
// The ordering in `ingest` is the whole point of this screen and is fixed
// by parent spec §12 step 3 -- see that method's doc comment.
//
// This view never references VisionKit. It goes through
// `ScannedPageSource`, which `AppModel` resolves to the real scanner or to
// a fixture depending on UITEST, because the simulator has no camera and
// the acceptance walk has to run somewhere.

import CoreGraphics
import SwiftUI
import UIKit
import CostSauceKit

struct InvoiceCaptureView: View {
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var invoiceId: String?
    @State private var pageCount = 0
    @State private var retakeMessage: String?
    @State private var captureErrorMessage: String?
    @State private var isCapturing = false

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await scan() }
                } label: {
                    Label(pageCount == 0 ? "Scan Invoice" : "Add Page", systemImage: "doc.viewfinder")
                }
                .disabled(isCapturing)
            }

            if pageCount > 0 {
                Section("Captured") {
                    // The acceptance walk keys off this exact string.
                    Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                }
            }

            if let retakeMessage {
                Section {
                    Text(retakeMessage).font(.caption).foregroundStyle(.orange)
                }
            }
            if let captureErrorMessage {
                Section {
                    Text(captureErrorMessage).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("New Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .disabled(pageCount == 0)
            }
        }
    }

    private func scan() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        retakeMessage = nil
        captureErrorMessage = nil

        guard let presenter = Self.topViewController() else {
            captureErrorMessage = "Couldn't open the camera."
            return
        }
        let images = await appModel.pageSource.pages(presentingFrom: presenter)
        guard !images.isEmpty else { return }  // cancelled, or the scan failed
        await ingest(images)
    }

    /// Turns scanned images into a live invoice. The order is load-bearing:
    ///  1. assess quality -- a refused page mints NOTHING, so a retake never
    ///     leaves an orphan row or a stray file behind;
    ///  2. mint the invoice, but only once the FIRST page has been accepted;
    ///     minting it up front would leave an empty invoice behind whenever
    ///     every page is refused or the user backs out;
    ///  3. mint the page row, which hands back the storage key;
    ///  4. write the JPEG;
    ///  5. queue the upload;
    ///  6. only now touch the network.
    ///
    /// Both the row and the bytes are therefore on disk before a single
    /// network call, so a failure anywhere downstream loses nothing.
    private func ingest(_ images: [CGImage]) async {
        guard let edits = appModel.edits,
              let store = appModel.store,
              let orgId = appModel.boundOrgId else {
            captureErrorMessage = "Not signed in to a location yet."
            return
        }
        do {
            for image in images {
                let variance = PageSharpness.laplacianVariance(of: image)
                if case .retake(let reason) = PageQuality.assess(
                    width: image.width, height: image.height,
                    laplacianVariance: variance
                ) {
                    retakeMessage = reason
                    continue
                }

                if invoiceId == nil {
                    invoiceId = try edits.createInvoice()
                }
                guard let invoiceId else { return }

                let pageNo = pageCount + 1
                let (pageId, _) = try edits.addInvoicePage(
                    invoiceId: invoiceId, pageNo: pageNo, orgId: orgId)
                let localPath = try InvoiceFiles.write(
                    image, invoiceId: invoiceId, pageNo: pageNo)
                try store.enqueueUpload(pageId: pageId, localPath: localPath)
                pageCount = pageNo
            }
            appModel.syncSoon()
        } catch let error as KernelError {
            captureErrorMessage = error.message
        } catch {
            captureErrorMessage = error.localizedDescription
        }

        // Once per capture SESSION, not per page: sweeping between pages of
        // one multi-page invoice measures a cache still mid-growth and could
        // evict page 1 while page 3 is still being written.
        if let store = appModel.store {
            ImageSweeper.sweep(store: store)
        }
    }

    /// The scanner is a UIKit controller and needs a presenter. Walks from
    /// the active scene's root rather than caching one, because a SwiftUI
    /// screen has no stable controller of its own to hand over.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
