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
        // Fundus-triggered manual rescrapes run first and re-crawl regardless of current state; the
        // other passes skip whatever a rescrape already covers this run.
        let rescrapes = ArchiveStore.shared.mediaNeedingRescrape()
        let rescrapeNumbers = Set(rescrapes.map(\.mediaNumber))
        let overrides = ArchiveStore.shared.pendingISBNOverrides()
            .filter { !rescrapeNumbers.contains($0.mediaNumber) }
        let skip = Set(overrides.map(\.mediaNumber)).union(rescrapeNumbers)
        // New items plus earlier 'notfound' misses that are due for another try.
        let targets = (ArchiveStore.shared.mediaNeedingEnrichment() + ArchiveStore.shared.mediaNeedingNotFoundRetry())
            .filter { !skip.contains($0.mediaNumber) }
        // Books enriched before the author/year/… columns existed: fill them once, by ISBN.
        let backfill = ArchiveStore.shared.mediaNeedingDetailBackfill()
            .filter { !skip.contains($0.mediaNumber) }
        // Found books that carry a real ISBN but never got a cover file → retry the plain VLB GET.
        let healTargets = ArchiveStore.shared.coversNeedingHeal()
            .filter { !skip.contains($0.mediaNumber) }

        guard !rescrapes.isEmpty || !overrides.isEmpty || !targets.isEmpty
            || !backfill.isEmpty || !healTargets.isEmpty else { return }

        try? FileManager.default.createDirectory(at: ArchiveStore.coversDirectory, withIntermediateDirectories: true)

        EnrichmentProgress.shared.start(
            phase: "Titel",
            total: rescrapes.count + overrides.count + targets.count + backfill.count + healTargets.count)

        for r in rescrapes {
            ArchiveStore.shared.resetCoverAttempts(mediaNumber: r.mediaNumber)
            // Reproduce the original enrichment decision: a manual ISBN override → search by ISBN,
            // otherwise by title (which — per the user's observation — actually surfaces the cover).
            if !r.overrideISBN.isEmpty {
                await enrichOne(mediaNumber: r.mediaNumber, term: r.overrideISBN, source: "manual")
            } else {
                await enrichOne(mediaNumber: r.mediaNumber, term: r.title, source: "title")
            }
            EnrichmentProgress.shared.step()
            try? await Task.sleep(nanoseconds: politeDelay)
        }
        for o in overrides {
            await enrichOne(mediaNumber: o.mediaNumber, term: o.isbn, source: "manual")
            EnrichmentProgress.shared.step()
            try? await Task.sleep(nanoseconds: politeDelay)
        }
        // Parse guard: a changed Trefferliste markup would make EVERY search look empty, and
        // 'notfound' is (nearly) permanent — one VÖBB redesign would silently lock every pending item. So
        // the title pass only collects its misses; if a run with ≥ minSearchesForGuard real
        // answers found nothing at all, they stay unprocessed (retried next refresh) and we warn.
        var found = 0
        var misses: [(mediaNumber: String, term: String)] = []
        for t in targets {
            switch await enrichOne(mediaNumber: t.mediaNumber, term: t.title, source: "title", deferNotFound: true) {
            case .found: found += 1
            case .notFound: misses.append((t.mediaNumber, t.title))
            case .transient: break
            }
            EnrichmentProgress.shared.step()
            try? await Task.sleep(nanoseconds: politeDelay)
        }
        if found == 0 && misses.count >= Self.minSearchesForGuard {
            notifyCatalogParseSuspect(misses: misses.count)
        } else {
            for m in misses { recordNotFound(mediaNumber: m.mediaNumber, term: m.term, source: "title") }
        }
        for b in backfill {
            await backfillOne(mediaNumber: b.mediaNumber, isbn: b.isbn)
            EnrichmentProgress.shared.step()
            try? await Task.sleep(nanoseconds: politeDelay)
        }
        await healMissingCovers(healTargets)
    }

    /// Cover self-heal: for each found book with a real ISBN but no cached cover, re-fetch the VLB
    /// cover directly (its URL is deterministic from the ISBN — no aDIS search/login needed). A
    /// success records the path; a miss bumps `cover_attempts` so the query drops the item after a
    /// few tries and a genuinely cover-less record isn't hammered every refresh.
    private func healMissingCovers(_ targets: [ArchiveStore.DetailTarget]) async {
        guard !targets.isEmpty else { return }
        let session = ADISHTTP.makeSession()
        for t in targets {
            let url = "\(base)/vlb/cover/\(t.isbn)/m"
            if let path = await downloadCover(url, mediaNumber: t.mediaNumber, session: session) {
                ArchiveStore.shared.setCoverPath(mediaNumber: t.mediaNumber, coverPath: path)
            } else {
                ArchiveStore.shared.bumpCoverAttempt(mediaNumber: t.mediaNumber)
            }
            EnrichmentProgress.shared.step()
            try? await Task.sleep(nanoseconds: politeDelay)
        }
    }

    private static let minSearchesForGuard = 3
    private let catalogParseNotifiedKey = "voebb_catalog_parsefail_notified"

    enum Outcome { case found, notFound, transient }

    /// One item: fresh session → search → parse → cover → store. On a *network* failure we
    /// store nothing (retried next refresh); on a successful-but-empty search we record
    /// 'notfound' (retried a few times later, see `mediaNeedingNotFoundRetry`) — unless
    /// `deferNotFound`, where the caller decides (see the parse guard in `enrichMissing`).
    /// A title search walks `titleSearchTerms` until one yields a hit.
    @discardableResult
    private func enrichOne(mediaNumber: String, term: String, source: String, deferNotFound: Bool = false) async -> Outcome {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return .transient }
        let terms = source == "title" ? Self.titleSearchTerms(cleanTerm) : [cleanTerm]

        var found: (hit: HTMLParser.CatalogHit, term: String, html: String, ctx: Ctx)?
        for t in terms {
            guard let ctx = try? await bootstrap(),
                  let resultHTML = try? await search(term: t, ctx: ctx) else {
                return .transient // network/session error → leave unprocessed for a later run
            }
            if let hit = HTMLParser.parseCatalogResult(resultHTML) {
                found = (hit, t, resultHTML, ctx)
                break
            }
        }
        guard let (hit, searchTerm, resultHTML, ctx) = found else {
            if !deferNotFound { recordNotFound(mediaNumber: mediaNumber, term: cleanTerm, source: source) }
            return .notFound
        }

        // Optional: open the Vollanzeige for blurb / subjects / author / year / …
        var detail = HTMLParser.CatalogDetail.empty
        if !hit.recordID.isEmpty,
           let vollHTML = try? await openVollanzeige(recordID: hit.recordID, term: searchTerm, trefferliste: resultHTML, ctx: ctx) {
            detail = HTMLParser.parseVollanzeige(vollHTML)
        }

        let coverPath = await downloadCover(hit.coverURL, mediaNumber: mediaNumber, session: ctx.session) ?? ""
        ArchiveStore.shared.upsertMediaDetails(
            mediaNumber: mediaNumber, isbn: hit.isbn, coverPath: coverPath,
            detail: detail, source: source, status: "found", recordID: hit.recordID)
        return .found
    }

    private func recordNotFound(mediaNumber: String, term: String, source: String) {
        // For manual corrections the search term IS the ISBN: store it even on notfound, so
        // pendingISBNOverrides (`d.isbn <> o.isbn`) sees the override as applied instead of
        // re-crawling the same dead ISBN on every refresh.
        ArchiveStore.shared.upsertMediaDetails(
            mediaNumber: mediaNumber, isbn: source == "manual" ? term.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            coverPath: "", detail: .empty, source: source, status: "notfound", recordID: "")
        if source == "title" { ArchiveStore.shared.bumpNotFoundAttempt(mediaNumber: mediaNumber) }
    }

    /// Search terms for a loan-list title, most specific first. The loan list carries the full
    /// statement of responsibility ("Titel / Autor [Textdichter/in] ; …"), and VÖBB's free search
    /// returns nothing as soon as it contains a letter its index folds differently — e.g. "Ḥ" in
    /// "Sasha Ḥaddad", while the same string with "H" finds the record. So: the title as is, then
    /// with non-Latin-1 diacritics folded, then just the title part before " / ".
    static func titleSearchTerms(_ title: String) -> [String] {
        let folded = foldRareDiacritics(title)
        var terms = [title, folded]
        if let slash = folded.range(of: " / ") {
            terms.append(String(folded[..<slash.lowerBound]).trimmingCharacters(in: .whitespaces))
        }
        var seen = Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Strips diacritics from letters outside Latin-1 ("Ḥ" → "H", "ł" stays), leaving German
    /// umlauts, ß and common accents like "é" alone — those the catalog search handles fine.
    static func foldRareDiacritics(_ s: String) -> String {
        String(s.map { ch -> String in
            guard ch.unicodeScalars.contains(where: { $0.value > 0xFF }) else { return String(ch) }
            return String(ch).folding(options: .diacriticInsensitive, locale: nil)
        }.joined())
    }

    /// At most one warning per day, like the loan page's parse monitor.
    private func notifyCatalogParseSuspect(misses: Int) {
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: catalogParseNotifiedKey) != day else { return }
        defaults.set(day, forKey: catalogParseNotifiedKey)
        NotificationManager.shared.notify(
            title: "⚠️ VÖBB-Katalogsuche defekt?",
            body: "\(misses) Titelsuchen ohne einen einzigen Treffer (Markup geändert?). Die Medien bleiben unverarbeitet und werden beim nächsten Abruf erneut versucht.")
    }

    /// Re-opens the Vollanzeige of an already-enriched item (by its unambiguous ISBN — for a Tonie,
    /// the EAN box code, which the catalog resolves the same way) to fill the newer fields
    /// (author/year/record_id). Updates text fields only — the cover isn't re-downloaded, so a
    /// Tonie's my.tonies image stays put.
    private func backfillOne(mediaNumber: String, isbn: String) async {
        // A network/session failure must be retried later; a search that simply has no record must
        // NOT be — otherwise the row keeps its old detail_version and is re-crawled every refresh.
        guard let ctx = try? await bootstrap(),
              let resultHTML = try? await search(term: isbn, ctx: ctx) else {
            return // transient failure → left for a later run
        }
        guard let hit = HTMLParser.parseCatalogResult(resultHTML), !hit.recordID.isEmpty,
              let vollHTML = try? await openVollanzeige(recordID: hit.recordID, term: isbn, trefferliste: resultHTML, ctx: ctx) else {
            ArchiveStore.shared.markDetailBackfilled(mediaNumber: mediaNumber)
            return
        }
        ArchiveStore.shared.updateDetailFields(mediaNumber: mediaNumber, detail: HTMLParser.parseVollanzeige(vollHTML), recordID: hit.recordID)
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
        return try await ADISHTTP.postRaw(ctx.appURL, body: body, session: ctx.session, referer: ctx.appURL)
    }

    // MARK: - Catalog HTTP flow

    private struct Ctx {
        let session: URLSession
        let appURL: String
        let hidden: [String: String]
    }

    /// GET the start page (URLSession follows the redirect) → session-id URL + form hidden inputs.
    private func bootstrap() async throws -> Ctx {
        let session = ADISHTTP.makeSession()
        let html = try await ADISHTTP.get("\(base)/aDISWeb/app/prod00?sp=SPROD00", session: session)
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
        return try await ADISHTTP.postRaw(ctx.appURL, body: body, session: ctx.session, referer: "\(base)/aDISWeb/app/prod00")
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

    // HTTP primitives: `ADISHTTP` (shared with VOEBBSession; the VÖBB catalog is anonymous).

    // Shared with VOEBBSession via ADISForm.
    private func extractHiddenInputs(_ html: String) -> [String: String] { ADISForm.extractHiddenInputs(html) }
    private func urlEncode(_ string: String) -> String { ADISForm.urlEncode(string) }
}
