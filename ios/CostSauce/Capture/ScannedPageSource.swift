// Capture's seam.
//
// `InvoiceCaptureView` depends on THIS protocol, never on VisionKit
// directly, because `VNDocumentCameraViewController` cannot run in the
// simulator -- there is no camera. Without this indirection the acceptance
// walk (Task 10) could not be written at all, and Phase 3a would ship its
// central flow permanently unautomatable, exactly as Phase 2b shipped
// swipe-to-remove. The seam is built here, where the scanner's output is
// first handled, rather than retrofitted later.

import CoreGraphics
import UIKit
import VisionKit

@MainActor
protocol ScannedPageSource {
    /// The scanned pages in order, or an empty array if the user cancelled
    /// or the scan failed. Never throws: from this screen's point of view
    /// "cancelled" and "failed" are the same outcome -- nothing was
    /// captured, and nothing has been minted yet to roll back.
    func pages(presentingFrom presenter: UIViewController) async -> [CGImage]
}

// MARK: - The real scanner

@MainActor
struct DocumentScannerSource: ScannedPageSource {
    func pages(presentingFrom presenter: UIViewController) async -> [CGImage] {
        await withCheckedContinuation { continuation in
            let controller = VNDocumentCameraViewController()
            let delegate = ScannerDelegate(continuation: continuation)
            controller.delegate = delegate
            // VNDocumentCameraViewController does NOT retain its delegate,
            // so without this association the delegate deallocates the
            // instant this closure returns and the continuation is never
            // resumed -- capture would hang forever with no error.
            objc_setAssociatedObject(
                controller, &ScannerDelegate.associationKey, delegate,
                .OBJC_ASSOCIATION_RETAIN)
            presenter.present(controller, animated: true)
        }
    }
}

/// VisionKit's delegate bridged to one `async` call.
///
/// `continuation` is nilled on first use rather than merely flagged: this
/// delegate has THREE terminal callbacks (finish, cancel, fail), and a
/// continuation resumed twice traps the process while one never resumed
/// hangs capture forever. Dismissal lives here because all three paths must
/// dismiss and only this type sees all three.
@MainActor
final class ScannerDelegate: NSObject, VNDocumentCameraViewControllerDelegate {
    nonisolated(unsafe) static var associationKey: UInt8 = 0

    private var continuation: CheckedContinuation<[CGImage], Never>?

    init(continuation: CheckedContinuation<[CGImage], Never>) {
        self.continuation = continuation
    }

    private func finish(_ controller: VNDocumentCameraViewController, with pages: [CGImage]) {
        guard let continuation else { return }
        self.continuation = nil
        controller.dismiss(animated: true)
        continuation.resume(returning: pages)
    }

    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
    ) {
        let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage }
        finish(controller, with: pages)
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        finish(controller, with: [])
    }

    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController, didFailWithError error: Error
    ) {
        finish(controller, with: [])
    }
}

// MARK: - The UITEST twin

/// Supplies fixture pages where the scanner's output would land, so the
/// whole capture -> upload -> entry walk runs headless on a simulator.
@MainActor
struct FixturePageSource: ScannedPageSource {
    let images: [CGImage]

    func pages(presentingFrom presenter: UIViewController) async -> [CGImage] {
        images
    }
}

enum FixtureInvoicePage {
    /// Drawn with Core Graphics rather than bundled as an asset, so the
    /// fixture cannot drift out of sync with the thresholds it must pass:
    /// it is generated at a size above `PageQuality.minimumLongEdge` and
    /// with hard black-on-white edges, which is what makes its Laplacian
    /// variance high.
    static func make(longEdge: Int = 2200) -> CGImage? {
        let width = Int(Double(longEdge) * 0.77)  // roughly US Letter
        let height = longEdge
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        // Hard-edged bars standing in for invoice lines. Sharp transitions
        // are the point: a blurred fixture would fail the very gate this
        // fixture exists to get past.
        var y = height / 12
        while y < height - height / 12 {
            context.fill(CGRect(x: width / 10, y: y, width: width * 8 / 10, height: 12))
            y += height / 24
        }
        return context.makeImage()
    }
}
