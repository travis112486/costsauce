// The storage key for an invoice page, derived rather than stored.
//
// Its own file, and its own test suite, because this is a CONTRACT with
// api/routes/invoices.py's `storage_path()`. The client mints the key (spec
// §4: a deterministic function of the client-minted invoice UUID plus page
// number is what makes a retry overwrite rather than duplicate) and the
// server derives the same key independently and never accepts one from the
// client. A divergence therefore never surfaces as a crash -- it surfaces
// as uploads landing somewhere nothing reads.

public enum StoragePath {
    /// `{org_id}/{invoice_uuid}/{page_no}.jpg` -- lowercase UUIDs exactly as
    /// minted, no zero-padding on the page number, always `.jpg`.
    public static func forPage(orgId: String, invoiceId: String, pageNo: Int) -> String {
        "\(orgId)/\(invoiceId)/\(pageNo).jpg"
    }
}
