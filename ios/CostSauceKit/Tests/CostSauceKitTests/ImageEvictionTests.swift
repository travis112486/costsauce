import Testing
import Foundation
@testable import CostSauceKit

@Suite struct ImageEvictionTests {

    private func candidate(
        _ id: String, bytes: Int, ageDays: Int, uploaded: Bool = true
    ) -> ImageEviction.Candidate {
        ImageEviction.Candidate(
            pageId: id, bytes: bytes,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
                .addingTimeInterval(-Double(ageDays) * 86_400),
            isUploaded: uploaded)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// THE load-bearing rule (spec 3a-D4). The local file is the only copy
    /// until storage acknowledges, so evicting it would destroy the page.
    @Test func neverEvictsAnUnuploadedPageEvenWhenHugeAndAncient() {
        let evicted = ImageEviction.evictable(
            candidates: [candidate("a", bytes: 500_000_000, ageDays: 3650, uploaded: false)],
            now: now)
        #expect(evicted.isEmpty)
    }

    @Test func keepsEverythingWhenUnderBothBounds() {
        let evicted = ImageEviction.evictable(
            candidates: [candidate("a", bytes: 1_000, ageDays: 1)], now: now)
        #expect(evicted.isEmpty)
    }

    @Test func evictsPagesPastTheAgeBound() {
        let evicted = ImageEviction.evictable(
            candidates: [
                candidate("old", bytes: 1_000, ageDays: 400),
                candidate("new", bytes: 1_000, ageDays: 1),
            ], now: now)
        #expect(evicted == ["old"])
    }

    @Test func evictsOldestFirstUntilUnderTheByteBound() {
        let big = ImageEviction.maximumBytes / 2 + 1
        let evicted = ImageEviction.evictable(
            candidates: [
                candidate("oldest", bytes: big, ageDays: 3),
                candidate("middle", bytes: big, ageDays: 2),
                candidate("newest", bytes: big, ageDays: 1),
            ], now: now)
        #expect(evicted.first == "oldest")
        #expect(!evicted.contains("newest"))
    }

    /// An un-uploaded page still counts toward the total -- it occupies the
    /// disk -- but can never be the thing evicted to get under it.
    @Test func anUnuploadedPageIsNotSacrificedToGetUnderTheBound() {
        let big = ImageEviction.maximumBytes
        let evicted = ImageEviction.evictable(
            candidates: [
                candidate("pending", bytes: big, ageDays: 10, uploaded: false),
                candidate("done", bytes: big, ageDays: 1),
            ], now: now)
        #expect(!evicted.contains("pending"))
        #expect(evicted.contains("done"))
    }
}
