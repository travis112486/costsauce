// Where a captured page's bytes live before (and after) they upload.
//
// Parent spec §12 step 3 and §13: the JPEG is written BEFORE any network
// call, and is never deleted until storage acknowledges. The containing
// directory is NSFileProtectionComplete, the same protection LocalStore
// already applies to the database -- another business's invoices on a lost
// phone is exactly the problem that setting exists for.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum InvoiceFiles {
    struct WriteError: Error { let message: String }

    /// `Application Support/invoices/{invoice_uuid}/{page_no}.jpg` --
    /// mirroring the remote key's shape so the two are trivially comparable
    /// when debugging, though the remote one is org-scoped and this is not
    /// (the container is already per-identity).
    static func url(invoiceId: String, pageNo: Int) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return base
            .appendingPathComponent("invoices", isDirectory: true)
            .appendingPathComponent(invoiceId, isDirectory: true)
            .appendingPathComponent("\(pageNo).jpg")
    }

    @discardableResult
    static func write(_ image: CGImage, invoiceId: String, pageNo: Int) throws -> String {
        let destination = try url(invoiceId: invoiceId, pageNo: pageNo)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])

        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw WriteError(message: "could not create the image file") }
        // 0.8: visibly lossless on printed text at these resolutions, and
        // roughly half the bytes of 1.0 over a connection that is usually
        // the bottleneck.
        CGImageDestinationAddImage(
            writer, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            throw WriteError(message: "could not write the image file")
        }
        return destination.path
    }

    /// Deletes one page's bytes. Used ONLY by eviction (Task 8) and by the
    /// identity-switch wipe -- never by the uploader, which must leave the
    /// only copy of a page alone until storage acknowledges it.
    static func delete(atPath path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
