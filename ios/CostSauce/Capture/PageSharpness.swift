// The measurement behind `PageQuality`'s blur gate.
//
// Lives in the app target, not the Kit: it needs a real `CGImage`, while
// `PageQuality.assess` is deliberately pure so the thresholds stay testable
// without one. Image STATISTICS only -- the parent spec's D4 bars on-device
// OCR, and how sharp a photograph is says nothing about what it says.

import CoreGraphics

enum PageSharpness {
    /// Variance of the discrete Laplacian over a grayscale downscale.
    ///
    /// Downscaled first (long edge 512) for two reasons: it is far cheaper
    /// on a 12-megapixel scan, and it makes the number comparable between
    /// devices with different camera resolutions -- without it the same
    /// physical sharpness would score differently on every phone, and no
    /// single threshold could be calibrated.
    static func laplacianVariance(of image: CGImage, downscaleLongEdge: Int = 512) -> Double {
        let scale = Double(downscaleLongEdge) / Double(max(image.width, image.height))
        let width = max(3, Int(Double(image.width) * min(scale, 1)))
        let height = max(3, Int(Double(image.height) * min(scale, 1)))

        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 4-neighbour Laplacian; borders skipped rather than clamped, since
        // a clamped border produces artificial zero-response rows that drag
        // the variance down on every image equally.
        var values: [Double] = []
        values.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let centre = Int(pixels[y * width + x]) * 4
                let neighbours = Int(pixels[(y - 1) * width + x])
                    + Int(pixels[(y + 1) * width + x])
                    + Int(pixels[y * width + (x - 1)])
                    + Int(pixels[y * width + (x + 1)])
                values.append(Double(centre - neighbours))
            }
        }
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }
}
