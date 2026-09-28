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

/// HTTP primitives for aDISWeb, shared by the account scraper (`VOEBBSession`) and the anonymous
/// catalog crawl (`CatalogEnricher`) — previously two near-identical private copies. Same headers
/// and timeout for both; the only per-call difference is the optional Referer.
enum ADISHTTP {
    /// A fresh ephemeral session: aDIS keeps its state in cookies, and nothing may leak between
    /// accounts or into the next run.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }

    static func get(_ url: String, session: URLSession, referer: String = "") async throws -> String {
        let req = request(url, referer: referer)
        return try await send(req, session: session)
    }

    static func postRaw(_ url: String, body: String, session: URLSession, referer: String) async throws -> String {
        var req = request(url, referer: referer)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await send(req, session: session)
    }

    /// Error pages (5xx/4xx) would otherwise be silently "parsed" as empty results.
    static func checkHTTP(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw VOEBBError.networkError("HTTP \(http.statusCode)")
        }
    }

    private static func request(_ url: String, referer: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(ADISForm.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("de-DE,de;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        return req
    }

    private static func send(_ req: URLRequest, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(for: req)
        try checkHTTP(response)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}
