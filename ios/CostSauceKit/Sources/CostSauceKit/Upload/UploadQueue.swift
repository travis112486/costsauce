// The upload outbox's decisions, as pure functions over rows -- no network,
// no filesystem, no URLSession -- so every rule below is unit-testable.
// BackgroundUploader (app target) performs the transfers; this decides what
// to send next and what a result means.
//
// Separate from pending_ops on purpose (spec 3a-D2): a stalled 12MB page
// must never block the JSON op batch behind it.

import Foundation

public enum UploadQueue {

    public enum Event: Equatable {
        case started
        case succeeded
        case failed(String)
    }

    /// The oldest queued or previously-failed upload, or nil when one is
    /// already in flight. One at a time: parallel large uploads on kitchen
    /// Wi-Fi finish later than sequential ones and starve the op push
    /// sharing the connection.
    public static func next(from uploads: [PendingUpload]) -> PendingUpload? {
        if uploads.contains(where: { $0.state == PendingUpload.State.uploading.rawValue }) {
            return nil
        }
        return uploads
            .filter {
                $0.state == PendingUpload.State.queued.rawValue
                    || $0.state == PendingUpload.State.failed.rawValue
            }
            .min { ($0.created_at, $0.page_id) < ($1.created_at, $1.page_id) }
    }

    /// Exponential, capped at an hour. The cap matters: the local file is
    /// still the only copy of that page, so a page that failed all night
    /// must not back off into never being retried at all.
    public static func backoffSeconds(attempts: Int) -> Double {
        min(pow(2.0, Double(max(attempts, 1))), 3600)
    }

    /// `.failed` returns the row to the retryable set rather than ending it
    /// -- giving up would strand the only copy of the page (§13).
    public static func transition(_ upload: PendingUpload, on event: Event) -> PendingUpload {
        var next = upload
        switch event {
        case .started:
            next.state = PendingUpload.State.uploading.rawValue
        case .succeeded:
            next.state = PendingUpload.State.uploaded.rawValue
            next.last_error = nil
        case .failed(let reason):
            next.state = PendingUpload.State.failed.rawValue
            next.attempts = upload.attempts + 1
            next.last_error = reason
        }
        return next
    }
}
