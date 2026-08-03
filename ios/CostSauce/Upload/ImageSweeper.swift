// Deletes cached page images the policy says are safe to lose.
//
// The POLICY is ImageEviction, pure and in the Kit. This is the part that
// cannot be pure: it stats files and deletes them, so it lives in the app
// target beside InvoiceFiles.
//
// One entry point on purpose. Today two triggers call it (foreground and
// end-of-capture); a BGTaskScheduler task can call the same function later
// without any of this being rewritten.

import Foundation
import CostSauceKit

enum ImageSweeper {

    /// UITEST budget: one ordinary captured page is 0.5-1.5MB, so a 1-byte
    /// ceiling guarantees the walk evicts something real. Same seam rule as
    /// AppModel.pageSource and BackgroundUploader -- gated on UITEST=1 only,
    /// production always takes the calibrated defaults.
    private static var isUITest: Bool {
        ProcessInfo.processInfo.environment["UITEST"] == "1"
    }

    /// Deletes FILES, never rows. The invoice_pages row surviving is what
    /// keeps the page re-downloadable and the purchase's invoice_page_id
    /// provenance link intact.
    static func sweep(store: LocalStore, now: Date = Date()) {
        guard let candidates = try? store.evictionCandidates() else { return }

        // Only pages with a file on disk may be measured. A page pulled from
        // another device has a row and no file; counting its bytes would
        // evict real files to get under a budget we were never over.
        var pathsByPageId: [String: String] = [:]
        var measured: [ImageEviction.Candidate] = []

        for candidate in candidates {
            guard let url = try? InvoiceFiles.url(
                invoiceId: candidate.invoiceId, pageNo: candidate.pageNo),
                let attributes = try? FileManager.default
                    .attributesOfItem(atPath: url.path),
                let bytes = attributes[.size] as? Int
            else { continue }

            pathsByPageId[candidate.pageId] = url.path
            measured.append(ImageEviction.Candidate(
                pageId: candidate.pageId, bytes: bytes,
                capturedAt: candidate.createdAt, isUploaded: candidate.isUploaded))
        }

        let evicted = isUITest
            ? ImageEviction.evictable(
                candidates: measured, now: now, maximumBytes: 1, maximumAge: 1)
            : ImageEviction.evictable(candidates: measured, now: now)

        for pageId in evicted {
            if let path = pathsByPageId[pageId] {
                InvoiceFiles.delete(atPath: path)
            }
        }
    }
}
