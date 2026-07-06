import Foundation

/// Enriches archived items with ISBN + cover from VÖBB's **public catalog** (no login).
///
/// Flow validated against the live site (see plan / `voebb-suche.har`):
/// bootstrap GET → search POST (`$Autosuggest`) → the Trefferliste already carries the VLB
/// cover, and thus the ISBN. Cover is downloaded (needs UA + aDIS Referer) into a shared cache.
///
/// Strictly **incremental**: only items missing from `media_details` are crawled, so repeated
/// account refreshes don't re-hit VÖBB. A fresh session per item keeps it robust against the
/// short aDIS session timeout (`requestCount=1` every time).
final class CatalogEnricher {
    static let shared = CatalogEnricher()
    private init() {}

    private let base = "https://www.voebb.de"
    private let userAgent = ADISForm.userAgent
    private let politeDelay: UInt64 = 400_000_000 // 0.4 s between items

    // MARK: - Orchestration

    /// Applies pending manual ISBN corrections (search by ISBN, lock as 'manual'), then crawls
    /// every not-yet-processed item by title. Safe to call after each refresh — it no-ops when
    /// there is nothing new.
    func enrichMissing() async {
        let overrides = ArchiveStore.shared.pendingISBNOverrides()
        let overrideNumbers = Set(overrides.map(\.mediaNumber))
        let targets = ArchiveStore.shared.mediaNeedingEnrichment()
            .filter { !overrideNumbers.contains($0.mediaNumber) }
        // Books enriched before the author/year/… columns existed: fill them once, by ISBN.
        let backfill = ArchiveStore.shared.mediaNeedingDetailBackfill()
            .filter { !overrideNumbers.contains($0.mediaNumber) }

        guard !overrides.isEmpty || !targets.isEmpty || !backfill.isEmpty else { return }

        try? FileManager.default.createDirectory(at: ArchiveStore.coversDirectory, withIntermediateDirectories: true)

        EnrichmentProgress.shared.start(phase: "Titel", total: overrides.count + targets.count + backfill.count)

        for o in overrides {
            await enrichOne(mediaNumber: o.mediaNumber, term: o.isbn, source: "manual")
            EnrichmentProgress.shared.step()
            try? await Task.sleep(nanoseconds: politeDelay)
        }
        for t in targets {
            await enrichOne(mediaNumber: t.mediaNumber, term: t.title, source: "title")
            EnrichmentProgress.shared.step()
            try? await Task.sleep(nanoseconds: politeDelay)
        }
        for b in backfill {
            await backfillOne(mediaNumber: b.mediaNumber, isbn: b.isbn)
            EnrichmentProgress.shared.step()
            try? await Task.sleep(nanoseconds: politeDelay)
        }
    }

    /// One item: fresh session → search → parse → cover → store. On a *network* failure we
    /// store nothing (retried next refresh); on a successful-but-empty search we record
    /// 'notfound' so it is never re-crawled.
    private func enrichOne(mediaNumber: String, term: String, source: String) async {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return }

        guard let ctx = try? await bootstrap(),
              let resultHTML = try? await search(term: cleanTerm, ctx: ctx) else {
            return // network/session error → leave unprocessed for a later run
        }

        guard let hit = HTMLParser.parseCatalogResult(resultHTML) else {
            // For manual corrections the search term IS the ISBN: store it even on notfound, so
            // pendingISBNOverrides (`d.isbn <> o.isbn`) sees the override as applied instead of
            // re-crawling the same dead ISBN on every refresh.
            ArchiveStore.shared.upsertMediaDetails(
                mediaNumber: mediaNumber, isbn: source == "manual" ? cleanTerm : "", coverPath: "",
                detail: .empty, source: source, status: "notfound")
            return
        }

        // Optional: open the Vollanzeige for blurb / subjects / author / year / …
        var detail = HTMLParser.CatalogDetail.empty
        if !hit.recordID.isEmpty,
           let vollHTML = try? await openVollanzeige(recordID: hit.recordID, term: cleanTerm, trefferliste: resultHTML, ctx: ctx) {
            detail = HTMLParser.parseVollanzeige(vollHTML)
        }

        let coverPath = await downloadCover(hit.coverURL, mediaNumber: mediaNumber, session: ctx.session) ?? ""
        ArchiveStore.shared.upsertMediaDetails(
            mediaNumber: mediaNumber, isbn: hit.isbn, coverPath: coverPath,
            detail: detail, source: source, status: "found")
    }

    /// Re-opens the Vollanzeige of an already-enriched book (by its unambiguous ISBN) to fill the
    /// newer fields (author/year/…). Updates text fields only — the cover isn't re-downloaded.
    private func backfillOne(mediaNumber: String, isbn: String) async {
        guard let ctx = try? await bootstrap(),
              let resultHTML = try? await search(term: isbn, ctx: ctx),
              let hit = HTMLParser.parseCatalogResult(resultHTML), !hit.recordID.isEmpty,
              let vollHTML = try? await openVollanzeige(recordID: hit.recordID, term: isbn, trefferliste: resultHTML, ctx: ctx) else {
            return // transient failure → left for a later run (detail_version stays < 1)
        }
        ArchiveStore.shared.updateDetailFields(mediaNumber: mediaNumber, detail: HTMLParser.parseVollanzeige(vollHTML))
    }

    /// Opens the full record from a Trefferliste (re-POST the page's hidden inputs plus the
    /// record's `selected` code). Same mechanism as voebbar's `navigate()`.
    private func openVollanzeige(recordID: String, term: String, trefferliste: String, ctx: Ctx) async throws -> String {
        var data = extractHiddenInputs(trefferliste)
        data["keyCode"] = "0"
        data["focus"] = ""
        data["stz"] = ""
        data["source"] = ""
        data["selected"] = "ZTEXT       \(recordID)"
        data["requestCount"] = "2"
        data["scriptEnabled"] = "true"
        data["scrollPos"] = "0"
        data["overrideScrollPos"] = "0"
        data["$Autosuggest"] = term
        data["$Select"] = "Überall suchen"
        data["$Tab"] = "0"

        let body = data.map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }.joined(separator: "&")
        return try await postRaw(ctx.appURL, body: body, session: ctx.session, referer: ctx.appURL)
    }

    // MARK: - Catalog HTTP flow

    private struct Ctx {
        let session: URLSession
        let appURL: String
        let hidden: [String: String]
    }

    /// GET the start page (URLSession follows the redirect) → session-id URL + form hidden inputs.
    private func bootstrap() async throws -> Ctx {
        let session = makeSession()
        let html = try await get("\(base)/aDISWeb/app/prod00?sp=SPROD00", session: session, referer: "")
        guard let idMatch = html.range(of: #"/aDISWeb/_[a-z0-9]+/app"#, options: .regularExpression) else {
            throw VOEBBError.parseError("Katalog-Session nicht gefunden")
        }
        let sid = String(html[idMatch])
            .replacingOccurrences(of: "/aDISWeb/", with: "")
            .replacingOccurrences(of: "/app", with: "")
        return Ctx(session: session, appURL: "\(base)/aDISWeb/\(sid)/app", hidden: extractHiddenInputs(html))
    }

    private func search(term: String, ctx: Ctx) async throws -> String {
        var data = ctx.hidden
        data["keyCode"] = "0"
        data["focus"] = "$$GFBO_1"
        data["stz"] = ""
        data["source"] = "$B"
        data["selected"] = ""
        data["requestCount"] = "1"
        data["scriptEnabled"] = "true"
        data["scrollPos"] = "0"
        data["overrideScrollPos"] = "0"
        data["$Autosuggest"] = term
        data["$Select"] = "Überall suchen"
        data["$Button"] = "pressed"

        let body = data.map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }.joined(separator: "&")
        return try await postRaw(ctx.appURL, body: body, session: ctx.session, referer: "\(base)/aDISWeb/app/prod00")
    }

    /// Downloads the VLB cover (requires UA + aDIS Referer) into `covers/{media_number}.jpg`.
    /// Returns nil when there is no image (403/non-image → book without a VLB cover).
    private func downloadCover(_ urlString: String, mediaNumber: String, session: URLSession) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("\(base)/aDISWeb/app", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("image/"),
              !data.isEmpty else {
            return nil
        }
        let fileURL = ArchiveStore.coversDirectory.appendingPathComponent("\(mediaNumber).jpg")
        do { try data.write(to: fileURL); return fileURL.path } catch { return nil }
    }

    // MARK: - HTTP primitives (standalone; VÖBB catalog is anonymous)

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }

    private func get(_ url: String, session: URLSession, referer: String) async throws -> String {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("de-DE,de;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: req)
        try VOEBBSession.checkHTTP(response)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private func postRaw(_ url: String, body: String, session: URLSession, referer: String) async throws -> String {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("de-DE,de;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: req)
        try VOEBBSession.checkHTTP(response)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // Shared with VOEBBSession via ADISForm.
    private func extractHiddenInputs(_ html: String) -> [String: String] { ADISForm.extractHiddenInputs(html) }
    private func urlEncode(_ string: String) -> String { ADISForm.urlEncode(string) }
}
