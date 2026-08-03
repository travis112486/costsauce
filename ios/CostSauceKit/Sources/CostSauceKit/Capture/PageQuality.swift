// The two gates a scanned invoice page must pass before it is accepted
// (parent spec §12 step 2).
//
// Pure arithmetic over measurements the CALLER supplies -- no image, no
// camera, no simulator -- so every rule below is unit-testable. The
// measurement itself (a variance of the Laplacian over a grayscale
// downscale) lives in the app target beside the capture view, because it
// needs Core Image and a real CGImage; keeping the judgement here and the
// measurement there is what lets the thresholds be tested at all.
//
// This is image STATISTICS, not text recognition. The parent spec's D4 bars
// on-device OCR and nothing else; measuring how sharp a photograph is says
// nothing about what it says.

import Foundation

public enum PageQuality {

    public enum Verdict: Equatable, Sendable {
        case accept
        case retake(reason: String)
    }

    // MARK: - Thresholds
    //
    // NOT YET CALIBRATED AGAINST REAL PHOTOGRAPHS. Both values below are
    // defensible starting points, not measurements, and they are recorded
    // as such deliberately: a threshold whose provenance is not written
    // down cannot be re-tuned later by anyone, because they cannot tell
    // whether it was measured or guessed.
    //
    // To calibrate: run a set of deliberately bad invoice photographs
    // (crumpled, thermal, glare, folded -- the same set that gates Phase
    // 3b) plus a set of good ones through the app target's
    // `laplacianVariance`, pick the value that separates them, and replace
    // this comment with the numbers and the sample they came from.

    /// 1600px on the long edge is ~145 DPI across a US Letter invoice,
    /// around the floor at which small print stays legible once JPEG
    /// compression has had its way with it.
    public static let minimumLongEdge: Int = 1600

    /// Variance of the Laplacian. 100 is the conventional starting point
    /// for blur detection, but it is sensitive to how the image was scaled
    /// and normalized first, so it means little until measured against this
    /// app's own downscale. Treat it as a placeholder that errs toward
    /// ACCEPTING: a wrongly-rejected page frustrates someone standing over
    /// a delivery, while a wrongly-accepted one is caught later by the
    /// human reading that photo during entry.
    public static let minimumSharpness: Double = 100.0

    /// Resolution is judged FIRST. A page too small to read is too small
    /// whatever its sharpness, and telling someone to hold still when the
    /// real problem is distance sends them to the wrong fix.
    public static func assess(
        width: Int, height: Int, laplacianVariance: Double
    ) -> Verdict {
        // Long edge, not width: a landscape invoice holds the same detail.
        guard max(width, height) >= minimumLongEdge else {
            return .retake(reason: "Move closer — this page is too small to read.")
        }
        guard laplacianVariance >= minimumSharpness else {
            return .retake(reason: "That came out blurry — hold still and try again.")
        }
        return .accept
    }
}
