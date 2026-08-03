// Which cached page images may be deleted. Pure: it takes measurements and
// returns page ids, touching no filesystem, so every rule is testable.
//
// Spec 3a-D4: deleting on upload-ack would break photo-assisted entry in
// exactly the walk-in-cooler dead spot the product exists for; keeping
// everything grows without ceiling on the owner's phone.

import Foundation

public enum ImageEviction {

    public struct Candidate: Equatable, Sendable {
        public let pageId: String
        public let bytes: Int
        public let capturedAt: Date
        public let isUploaded: Bool

        public init(pageId: String, bytes: Int, capturedAt: Date, isUploaded: Bool) {
            self.pageId = pageId
            self.bytes = bytes
            self.capturedAt = capturedAt
            self.isUploaded = isUploaded
        }
    }

    /// CALIBRATION, same rule as PageQuality's: measured against the Task 6
    /// fixture pipeline's own output. A page JPEG at the quality gates'
    /// floor (1600px long edge, 0.8 compression, printed text) lands at
    /// roughly 0.5-1.5MB, so 500MB holds a few hundred invoices -- months
    /// of a small restaurant's deliveries -- while staying a small fraction
    /// of any modern phone's disk. 90 days mirrors the quarter a purchase
    /// remains realistically disputable; a page older than that has been
    /// uploaded for months and remains one tap away via re-download in 3b.
    public static let maximumBytes: Int = 500 * 1_024 * 1_024
    public static let maximumAge: TimeInterval = 90 * 86_400

    /// Page ids safe to delete, oldest first. An un-uploaded page is never
    /// returned, at any age or size: until storage acknowledges, the local
    /// file is the only copy in existence (§13).
    public static func evictable(candidates: [Candidate], now: Date) -> [String] {
        let evictableCandidates = candidates
            .filter(\.isUploaded)
            .sorted { ($0.capturedAt, $0.pageId) < ($1.capturedAt, $1.pageId) }

        var evicted: [String] = []
        // Un-uploaded pages still occupy the disk, so they count toward the
        // total -- they simply cannot be what gets sacrificed to get under it.
        var total = candidates.reduce(0) { $0 + $1.bytes }

        for candidate in evictableCandidates {
            let tooOld = now.timeIntervalSince(candidate.capturedAt) > maximumAge
            if tooOld || total > maximumBytes {
                evicted.append(candidate.pageId)
                total -= candidate.bytes
            }
        }
        return evicted
    }
}
