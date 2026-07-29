// Loader for shared/golden-vectors.json — the single behavior spec shared by
// the Python, JavaScript, and Swift kernel implementations. Never copy this
// file into the package; resolve it in place from the test file's own
// on-disk location.

import Foundation

struct GoldenFile: Decodable {
    let version: Int
    let normalizePurchase: [NormalizePurchaseCase]
    let unitPrice: [UnitPriceCase]
    let suggestedPriceCents: [SuggestedPriceCentsCase]
    let fcStatus: [FcStatusCase]

    enum CodingKeys: String, CodingKey {
        case version
        case normalizePurchase = "normalize_purchase"
        case unitPrice = "unit_price"
        case suggestedPriceCents = "suggested_price_cents"
        case fcStatus = "fc_status"
    }
}

struct NormalizePurchaseCase: Decodable {
    let name: String
    let baseUnit: String
    let qty: String
    let unit: String
    let totalPrice: String
    let qtyInCase: String?
    let expect: String?
    let expectError: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case baseUnit = "base_unit"
        case qty
        case unit
        case totalPrice = "total_price"
        case qtyInCase = "qty_in_case"
        case expect
        case expectError = "expect_error"
    }
}

struct UnitPriceCase: Decodable {
    let totalPrice: String
    let qtyBaseUnits: String
    let expect: String

    enum CodingKeys: String, CodingKey {
        case totalPrice = "total_price"
        case qtyBaseUnits = "qty_base_units"
        case expect
    }
}

struct SuggestedPriceCentsCase: Decodable {
    let plateCents: Int
    let targetBp: Int
    let expect: Int

    enum CodingKeys: String, CodingKey {
        case plateCents = "plate_cents"
        case targetBp = "target_bp"
        case expect
    }
}

struct FcStatusCase: Decodable {
    let plateCents: Int
    let menuCents: Int
    let targetBp: Int
    let expectFc: String
    let expectStatus: String

    enum CodingKeys: String, CodingKey {
        case plateCents = "plate_cents"
        case menuCents = "menu_cents"
        case targetBp = "target_bp"
        case expectFc = "expect_fc"
        case expectStatus = "expect_status"
    }
}

/// Resolves and decodes `shared/golden-vectors.json` from this file's own
/// on-disk location: file → CostSauceKitTests → Tests → CostSauceKit → ios
/// → repo root, then `shared/golden-vectors.json`.
func goldenVectors() throws -> GoldenFile {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    url = url.appendingPathComponent("shared/golden-vectors.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(GoldenFile.self, from: data)
}
