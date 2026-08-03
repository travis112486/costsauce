import Testing
import Foundation
@testable import CostSauceKit

@Suite struct UploadQueueTests {

    private func upload(
        _ id: String, state: PendingUpload.State, attempts: Int = 0, createdAt: String = "1"
    ) -> PendingUpload {
        PendingUpload(page_id: id, local_path: "/tmp/\(id).jpg", state: state,
                      attempts: attempts, last_error: nil, created_at: createdAt)
    }

    @Test func takesTheOldestQueuedUploadFirst() {
        let next = UploadQueue.next(from: [
            upload("b", state: .queued, createdAt: "2"),
            upload("a", state: .queued, createdAt: "1"),
        ])
        #expect(next?.page_id == "a")
    }

    /// One at a time: a background session uploading four 12MB pages at once
    /// on kitchen Wi-Fi is slower than four in sequence, and starves the op
    /// push sharing the connection.
    @Test func skipsAnUploadAlreadyInFlight() {
        let next = UploadQueue.next(from: [
            upload("a", state: .uploading),
            upload("b", state: .queued),
        ])
        #expect(next == nil)
    }

    @Test func neverReturnsAnAlreadyUploadedPage() {
        #expect(UploadQueue.next(from: [upload("a", state: .uploaded)]) == nil)
    }

    @Test func backoffGrowsWithAttemptsAndIsCapped() {
        let first = UploadQueue.backoffSeconds(attempts: 1)
        let later = UploadQueue.backoffSeconds(attempts: 5)
        #expect(first < later)
        // A page must not become unreachable because it failed all night.
        #expect(UploadQueue.backoffSeconds(attempts: 99) <= 3600)
    }

    @Test func failureRecordsTheReasonAndCountsTheAttempt() {
        let after = UploadQueue.transition(
            upload("a", state: .uploading, attempts: 1), on: .failed("503"))
        #expect(after.state == PendingUpload.State.failed.rawValue)
        #expect(after.attempts == 2)
        #expect(after.last_error == "503")
    }

    /// A failed upload returns to the queue rather than dying: the local
    /// file is still the only copy, so giving up would strand it (§13).
    @Test func aFailedUploadIsRetryableNotTerminal() {
        let failed = UploadQueue.transition(
            upload("a", state: .uploading, attempts: 1), on: .failed("timeout"))
        #expect(UploadQueue.next(from: [failed])?.page_id == "a")
    }

    @Test func successIsTerminal() {
        let done = UploadQueue.transition(upload("a", state: .uploading), on: .succeeded)
        #expect(done.state == PendingUpload.State.uploaded.rawValue)
        #expect(UploadQueue.next(from: [done]) == nil)
    }
}
