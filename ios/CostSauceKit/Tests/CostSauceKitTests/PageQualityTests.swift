import Testing
@testable import CostSauceKit

@Suite struct PageQualityTests {

    @Test func acceptsASharpFullResolutionPage() {
        #expect(PageQuality.assess(
            width: 1700, height: 2200,
            laplacianVariance: PageQuality.minimumSharpness + 1) == .accept)
    }

    /// Long edge, not width: an invoice photographed in landscape carries
    /// the same detail as one in portrait.
    @Test func measuresTheLongEdgeRegardlessOfOrientation() {
        let portrait = PageQuality.assess(
            width: 100, height: PageQuality.minimumLongEdge,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        let landscape = PageQuality.assess(
            width: PageQuality.minimumLongEdge, height: 100,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        #expect(portrait == .accept)
        #expect(landscape == .accept)
    }

    @Test func refusesAPageBelowTheResolutionFloor() {
        let verdict = PageQuality.assess(
            width: PageQuality.minimumLongEdge - 1,
            height: PageQuality.minimumLongEdge - 1,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        #expect(verdict != .accept)
    }

    @Test func refusesABlurryPage() {
        let verdict = PageQuality.assess(
            width: 1700, height: 2200,
            laplacianVariance: PageQuality.minimumSharpness - 0.01)
        #expect(verdict != .accept)
    }

    /// The reason is read by someone holding a phone over a delivery, so it
    /// has to say which problem to fix -- "retake" alone is useless when the
    /// page is sharp but too small, or large but blurred.
    @Test func namesWhichGateFailed() {
        guard case .retake(let blurReason) = PageQuality.assess(
            width: 1700, height: 2200,
            laplacianVariance: PageQuality.minimumSharpness - 0.01)
        else { Issue.record("expected a retake verdict"); return }
        #expect(blurReason.lowercased().contains("blurry"))

        guard case .retake(let sizeReason) = PageQuality.assess(
            width: 10, height: 10,
            laplacianVariance: PageQuality.minimumSharpness + 1)
        else { Issue.record("expected a retake verdict"); return }
        #expect(sizeReason.lowercased().contains("closer"))
    }

    /// Resolution is checked FIRST: a page too small to read is too small
    /// whatever its sharpness, and telling someone to hold still when the
    /// real problem is distance sends them to the wrong fix.
    @Test func resolutionIsReportedBeforeBlurWhenBothFail() {
        guard case .retake(let reason) = PageQuality.assess(
            width: 10, height: 10,
            laplacianVariance: PageQuality.minimumSharpness - 0.01)
        else { Issue.record("expected a retake verdict"); return }
        #expect(reason.lowercased().contains("closer"))
    }
}
