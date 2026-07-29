// The CostSauce API client — error shape.
//
// Mirrors web/js/api.mjs's `ApiError` (FastAPI's `{"detail": ...}` envelope,
// including its list-shaped 422 validation body), extended with an
// `.object` case web/js/api.mjs doesn't need: two routes in this project
// raise a 409 whose `detail` is itself a dict wrapping a human string under
// an INNER "detail" key alongside sibling data --
// `POST /locations/{id}/ingredients` duplicate (api/routes/ingredients.py:
// 83-84, 97 — `{"detail": "duplicate", "matches": [...]}`) and `DELETE /me`
// last-owner (api/routes/deletion.py:315-322 — `{"detail": "...",
// "orgs_requiring_deletion": [...]}`). `ApiDetail.object` is typed
// `[String: String]`, so it captures only string-valued keys of that inner
// dict (the sibling `matches`/`orgs_requiring_deletion` arrays don't
// survive) -- sufficient for `.message`, which only ever reads the inner
// "detail" string back out.
//
// `.message` does NOT fall back across cases: the response body decodes
// into exactly one `ApiDetail` case, and each case has its own single
// extraction rule (a string verbatim, an object's inner "detail", a
// validation list's first message) with its own "HTTP <status>" fallback
// for the case where that specific shape didn't carry a usable string.

import Foundation

public enum ApiDetail: Equatable, Sendable {
    case text(String)
    case validationList([String])
    case object([String: String])
    case none
}

public struct ApiError: Error, Equatable, Sendable {
    public let status: Int
    public let detail: ApiDetail

    public init(status: Int, detail: ApiDetail) {
        self.status = status
        self.detail = detail
    }

    public var message: String {
        switch detail {
        case .text(let text):
            return text
        case .object(let object):
            return object["detail"] ?? "HTTP \(status)"
        case .validationList(let list):
            return list.first ?? "HTTP \(status)"
        case .none:
            return "HTTP \(status)"
        }
    }
}

extension ApiError {
    /// Parses a non-2xx JSON response body's `detail` field into an
    /// `ApiDetail`. Uses `JSONSerialization` rather than `Decodable`
    /// because `detail`'s shape (string / list / dict) isn't known ahead
    /// of decode time -- FastAPI itself picks the shape per call site
    /// (a plain `HTTPException(status, "text")`, its own 422 validator, or
    /// a route's `detail={...}` dict).
    static func parseDetail(from data: Data) -> ApiDetail {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = root["detail"]
        else {
            return .none
        }
        if let text = detail as? String {
            return .text(text)
        }
        if let list = detail as? [[String: Any]] {
            return .validationList(list.compactMap { $0["msg"] as? String })
        }
        if let object = detail as? [String: Any] {
            var strings: [String: String] = [:]
            for (key, value) in object {
                if let s = value as? String {
                    strings[key] = s
                }
            }
            return .object(strings)
        }
        return .none
    }
}
