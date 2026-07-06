import Foundation

/// Shared helpers for talking to aDISWeb's form-based pages — previously duplicated (privately)
/// in `VOEBBSession` and `CatalogEnricher`.
enum ADISForm {
    /// One UA for every request the app makes (account scraping, catalog, cover downloads).
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    /// Percent-encodes for an `application/x-www-form-urlencoded` body (RFC 3986 unreserved set).
    static func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// All hidden `<input>` name/value pairs of a page — aDISWeb "navigation" means re-POSTing
    /// these plus a few action fields.
    static func extractHiddenInputs(_ html: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"<input[^>]+type=['"]hidden['"][^>]*>"#, options: .caseInsensitive)
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let name = attr(tag, "name") else { continue }
            result[name] = attr(tag, "value") ?? ""
        }
        return result
    }

    /// Value of one attribute inside a single HTML tag, or nil.
    static func attr(_ tag: String, _ name: String) -> String? {
        guard let m = tag.range(of: "\(name)=['\"]([^'\"]*)['\"]", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let parts = String(tag[m]).components(separatedBy: CharacterSet(charactersIn: "\"'"))
        return parts.count >= 2 ? parts[1] : nil
    }
}
