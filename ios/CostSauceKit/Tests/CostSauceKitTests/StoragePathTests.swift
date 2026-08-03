import Testing
@testable import CostSauceKit

@Suite struct StoragePathTests {

    /// Pinned against `api/routes/invoices.py`'s `storage_path`. These two
    /// definitions must agree byte for byte: the client mints the key and
    /// the server derives its own and refuses one that disagrees, so a
    /// divergence here does not fail loudly -- it orphans every upload.
    @Test func matchesTheServersDerivation() {
        #expect(StoragePath.forPage(
            orgId: "019fc76f-45b6-7547-83b2-f95775ad2c81",
            invoiceId: "019fc770-0000-7000-8000-000000000001",
            pageNo: 2
        ) == "019fc76f-45b6-7547-83b2-f95775ad2c81/019fc770-0000-7000-8000-000000000001/2.jpg")
    }

    /// No zero-padding: the server writes `f"{page_no}.jpg"`, so page 10 is
    /// "10.jpg" and never "010.jpg".
    @Test func pageNumberIsNotZeroPadded() {
        #expect(StoragePath.forPage(orgId: "o", invoiceId: "i", pageNo: 10) == "o/i/10.jpg")
    }

    /// Deterministic: the same page always derives the same key, which is
    /// what makes an upload retry overwrite instead of duplicate.
    @Test func isDeterministicAcrossCalls() {
        let a = StoragePath.forPage(orgId: "o", invoiceId: "i", pageNo: 1)
        let b = StoragePath.forPage(orgId: "o", invoiceId: "i", pageNo: 1)
        #expect(a == b)
    }
}
