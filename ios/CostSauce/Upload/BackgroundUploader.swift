// Performs the transfers UploadQueue selects. All policy lives in the
// Kit's pure UploadQueue; this owns only the URLSession and the ordering
// in `pumpOnce`.
//
// The session is a BACKGROUND session, which changes two things about how
// this file must be written:
//  - background sessions refuse the completion-handler (and therefore
//    async/await) transfer APIs at runtime, so `perform` bridges the
//    delegate callback back to an await by hand;
//  - the app can be relaunched headless purely to receive the session's
//    events, which is what the eager session creation in `init` and
//    `AppDelegate.backgroundCompletionHandler` exist to serve.

import CryptoKit
import Foundation
import ImageIO
import CostSauceKit

@MainActor
final class BackgroundUploader: NSObject, URLSessionTaskDelegate {

    static let sessionIdentifier = "sauce.invoice.upload"

    /// AppModel owns this uploader for the life of the app; `unowned`
    /// rather than a strong back-reference that would cycle.
    private unowned let appModel: AppModel

    private let inFlight = InFlight()
    private var isPumping = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier)
        // A kitchen phone leaves the building mid-upload constantly; let
        // the system retry when connectivity returns rather than fail now.
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
        // Created now, not on first pump: recreating the session with the
        // same identifier at launch is what re-attaches a relaunched app
        // to uploads the system kept running while it was dead.
        _ = session
    }

    /// Drains the queue, one page at a time, stopping at the first
    /// failure -- that attempt's backoff has already delayed, and the next
    /// trigger (scene activation, the next capture's `syncSoon`) retries
    /// from there. Reentrancy-guarded: overlapping triggers must not race
    /// two transfers of the same page.
    func pump() async {
        guard !isPumping else { return }
        isPumping = true
        defer { isPumping = false }
        while await pumpOnce() {}
    }

    /// Uploads the single page `UploadQueue.next` selects, if any.
    /// Returns true only when that page fully uploaded AND confirmed.
    ///
    /// The local file is deleted here under NO circumstances -- eviction
    /// is Task 8's, and only ever for pages already uploaded.
    @discardableResult
    func pumpOnce() async -> Bool {
        guard let store = appModel.store else { return false }
        await recoverOrphanedUploads(store: store)
        guard let queued = try? store.pendingUploads(),
              let upload = UploadQueue.next(from: queued) else { return false }
        do {
            // The endpoints are keyed by (invoice, page_no), so resolve
            // the page row the queued upload references first.
            guard let page = try? store.invoicePage(id: upload.page_id),
                  let pageNo = Int(page.page_no) else {
                throw KernelError("upload references a page this store does not hold")
            }

            // Minted per attempt, never cached: a URL signed before a
            // night offline has long expired by the time the session runs.
            let signed = try await appModel.api.uploadURL(
                invoiceId: page.invoice_id, pageNo: pageNo)
            guard let signedURL = URL(string: signed.url) else {
                throw KernelError("unusable signed upload URL")
            }
            try store.updateUpload(UploadQueue.transition(upload, on: .started))

            let fileURL = URL(fileURLWithPath: upload.local_path)
            var request = URLRequest(url: signedURL)
            request.httpMethod = "PUT"
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            // Storage refuses to replace an existing object unless told
            // otherwise, and a retry MUST overwrite -- the deterministic
            // storage path exists precisely so it can (spec §4).
            request.setValue("true", forHTTPHeaderField: "x-upsert")

            let (response, transportError) = await perform(request, fromFile: fileURL)
            if let transportError { throw transportError }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw KernelError("upload rejected")
            }

            // Confirm reports what the BYTES say, not what capture
            // remembered: the hash and the dimensions both come from the
            // file that was actually sent.
            let bytes = try Data(contentsOf: fileURL)
            let (width, height) = try Self.pixelDimensions(of: fileURL)
            try await appModel.api.confirmPage(
                invoiceId: page.invoice_id, pageNo: pageNo,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                width: width, height: height)

            try store.updateUpload(UploadQueue.transition(upload, on: .succeeded))
            appModel.refreshPendingCount()
            return true
        } catch {
            // Retryable, never terminal: the local file is still the only
            // copy of this page (§13), so giving up would strand it.
            let reason = (error as? KernelError)?.message ?? error.localizedDescription
            try? store.updateUpload(UploadQueue.transition(upload, on: .failed(reason)))
            appModel.refreshPendingCount()
            try? await Task.sleep(
                for: .seconds(UploadQueue.backoffSeconds(attempts: upload.attempts + 1)))
            return false
        }
    }

    /// A row left `uploading` by a crash or force-quit would block the
    /// queue forever -- `UploadQueue.next` treats it as in flight. When
    /// the session reports no task actually running, return such rows to
    /// the retryable set. Re-sending is safe: the storage path is
    /// deterministic and the PUT upserts, so a duplicate upload overwrites
    /// its own predecessor.
    private func recoverOrphanedUploads(store: LocalStore) async {
        guard let uploads = try? store.pendingUploads() else { return }
        let stuck = uploads.filter { $0.state == PendingUpload.State.uploading.rawValue }
        guard !stuck.isEmpty else { return }
        guard await session.allTasks.isEmpty else { return }
        for upload in stuck {
            try? store.updateUpload(
                UploadQueue.transition(upload, on: .failed("interrupted by relaunch")))
        }
    }

    // MARK: - the delegate bridge

    /// One transfer, delegate-bridged: a background session refuses the
    /// completion-handler (and async) transfer APIs at runtime, so the
    /// task is created bare and its completion comes back through
    /// `urlSession(_:task:didCompleteWithError:)` below.
    private func perform(
        _ request: URLRequest, fromFile fileURL: URL
    ) async -> (URLResponse?, Error?) {
        await withCheckedContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            inFlight.store(continuation, for: task.taskIdentifier)
            task.resume()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        // No continuation is registered when the app was relaunched into a
        // task it did not start this run; recoverOrphanedUploads owns that
        // case, and the take() below is simply a no-op for it.
        inFlight.take(task.taskIdentifier)?.resume(returning: (task.response, error))
    }

    /// Called once the session has delivered every event after a
    /// background relaunch. WITHOUT handing the parked completion handler
    /// back, iOS treats the app as unresponsive to background events and
    /// stops waking it for them -- which is most uploads, since these are
    /// large files on slow connections.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            AppDelegate.backgroundCompletionHandler?()
            AppDelegate.backgroundCompletionHandler = nil
        }
    }

    /// The JPEG's pixel dimensions, read from its header without decoding
    /// the bitmap.
    private static func pixelDimensions(of fileURL: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw KernelError("unreadable image file")
        }
        return (width, height)
    }
}

/// Bridges delegate completions back to `perform`'s awaits, keyed by task
/// identifier. Lock-guarded because the session delivers callbacks on its
/// own queue. Same class-plus-NSLock shape `TokenBox` and `ApiClient`'s
/// `onUnauthorized` already use.
private final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var byTask: [Int: CheckedContinuation<(URLResponse?, Error?), Never>] = [:]

    func store(
        _ continuation: CheckedContinuation<(URLResponse?, Error?), Never>, for taskId: Int
    ) {
        lock.lock()
        byTask[taskId] = continuation
        lock.unlock()
    }

    func take(_ taskId: Int) -> CheckedContinuation<(URLResponse?, Error?), Never>? {
        lock.lock()
        defer { lock.unlock() }
        return byTask.removeValue(forKey: taskId)
    }
}
