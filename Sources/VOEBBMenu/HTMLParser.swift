import Foundation

enum HTMLParser {
    // MARK: - Overview Page

    static func parseLoanCount(_ html: String) -> Int? {
        // Suche NUR innerhalb des #konto-services Blocks, damit
        // "Keine Ausleihen" in der Navigationsleiste nicht stört.
        let servicesHTML = extractKontoServices(html) ?? html

        if servicesHTML.contains("Keine Ausleihen") { return 0 }
        // Read the capture group, not a split on " " — the whitespace may be a newline, tab or
        // decoded &nbsp;, and a failed parse here disarms the parse monitor's strongest check.
        let regex = try! NSRegularExpression(pattern: #"(\d+)\s+Ausleihen"#)
        guard let m = regex.firstMatch(in: servicesHTML, range: NSRange(servicesHTML.startIndex..., in: servicesHTML)),
              let r = Range(m.range(at: 1), in: servicesHTML) else { return nil }
        return Int(servicesHTML[r])
    }

    private static func extractKontoServices(_ html: String) -> String? {
        guard let start = html.range(of: #"id="konto-services""#, options: .regularExpression) else { return nil }
        // Suche das Ende des Blocks: </section> oder </div> nach dem Start
        let tail = html[start.lowerBound...]
        if let end = tail.range(of: "</section>") {
            return String(tail[tail.startIndex..<end.upperBound])
        }
        return String(tail.prefix(2000))
    }

    // MARK: - Loans Page

    static func parseLoans(_ html: String) -> [Loan] {
        var loans: [Loan] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        formatter.locale = Locale(identifier: "de_DE")

        // Extract <tr> rows from the rTable_table
        let trPattern = try! NSRegularExpression(
            pattern: #"<tr[^>]*class="[^"]*rTable_tr[^"]*"[^>]*>(.*?)</tr>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        let fullRange = NSRange(html.startIndex..., in: html)
        let matches = trPattern.matches(in: html, range: fullRange)

        for match in matches {
            guard let rowRange = Range(match.range(at: 1), in: html) else { continue }
            let rowHTML = String(html[rowRange])

            guard let loan = parseLoanRow(rowHTML, formatter: formatter) else { continue }
            loans.append(loan)
        }

        return loans
    }

    private static func parseLoanRow(_ rowHTML: String, formatter: DateFormatter) -> Loan? {
        // Column order is positional: [0]=checkbox, [1]=date, [2]=library, [3]=title, [4]=status.
        // Cell classes vary (normally rTable_td_text, but red hints like "Keine Verlängerung:
        // Vormerkungen…" use zellef), so extract ALL <td>s instead of filtering by class.
        let cols = extractAllTDContents(rowHTML)
        guard cols.count >= 5 else { return nil }

        let dateStr = stripHTML(cols[1]).trimmingCharacters(in: .whitespaces)
        guard let dueDate = formatter.date(from: dateStr) else { return nil }

        let library = stripHTML(cols[2]).trimmingCharacters(in: .whitespaces)

        let parsedTitle = parseTitleColumn(cols[3])

        let status = stripHTML(cols[4]).trimmingCharacters(in: .whitespaces)

        // Checkbox value for renewal
        let cbPattern = try! NSRegularExpression(
            pattern: #"value="(CheckCell[^"]*)"#,
            options: .caseInsensitive
        )
        let cbMatch = cbPattern.firstMatch(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML))
        let cbValue = cbMatch.flatMap { Range($0.range(at: 1), in: rowHTML).map { String(rowHTML[$0]) } } ?? ""

        return Loan(
            title: parsedTitle.title,
            dueDate: dueDate,
            dueDateString: dateStr,
            library: library,
            renewalStatus: status,
            checkboxValue: cbValue,
            mediaNumber: parsedTitle.mediaNumber,
            signature: parsedTitle.signature,
            mediaType: Loan.inferMediaType(typeTag: parsedTitle.typeTag, signature: parsedTitle.signature)
        )
    }

    // MARK: - Pickups ("Bereitstellungen")

    /// Pickup count from the overview's service block: "Keine Bereitstellungen" → 0,
    /// "1 Bereitstellung" / "2 Bereitstellungen" → n, unrecognizable → nil.
    static func parsePickupCount(_ html: String) -> Int? {
        let servicesHTML = extractKontoServices(html) ?? html
        if servicesHTML.contains("Keine Bereitstellungen") { return 0 }
        let regex = try! NSRegularExpression(pattern: #"(\d+)\s+Bereitstellung"#)
        guard let m = regex.firstMatch(in: servicesHTML, range: NSRange(servicesHTML.startIndex..., in: servicesHTML)),
              let r = Range(m.range(at: 1), in: servicesHTML) else { return nil }
        return Int(servicesHTML[r])
    }

    /// The pickups list shares its <title> with the loans list ("Meine Ausleihen"); only the
    /// page heading tells them apart.
    static func isPickupsPage(_ html: String) -> Bool {
        html.contains("Mein Konto - Bereitstellungen")
    }

    /// Rows of the pickups list, by position like the loans list: [0]=checkbox, [1]=deadline
    /// ("Bis"), [2]=pickup location, [3]=title cell (title<br>signature<br>barcode).
    /// Returns [] for any page that isn't recognizably the pickups list.
    static func parsePickups(_ html: String) -> [PickupItem] {
        guard isPickupsPage(html) else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        formatter.locale = Locale(identifier: "de_DE")

        let trPattern = try! NSRegularExpression(
            pattern: #"<tr[^>]*class="[^"]*rTable_tr[^"]*"[^>]*>(.*?)</tr>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        var items: [PickupItem] = []
        for match in trPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let rowRange = Range(match.range(at: 1), in: html) else { continue }
            let cols = extractAllTDContents(String(html[rowRange]))
            guard cols.count >= 4 else { continue }
            let parsedTitle = parseTitleColumn(cols[3])
            guard !parsedTitle.title.isEmpty else { continue }
            let dateStr = stripHTML(cols[1]).trimmingCharacters(in: .whitespaces)
            items.append(PickupItem(
                title: parsedTitle.title,
                mediaNumber: parsedTitle.mediaNumber,
                readyUntilString: dateStr,
                readyUntil: formatter.date(from: dateStr),
                library: stripHTML(cols[2]).trimmingCharacters(in: .whitespaces)
            ))
        }
        return items
    }

    /// `name` of the submit button whose label contains `label` (e.g. "Zur Übersicht") — its
    /// `$Button$N` number differs per page, so it is looked up by label, never hardcoded.
    static func findSubmitButton(labelContaining label: String, in html: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"<input[^>]+type=['"]submit['"][^>]*>"#, options: .caseInsensitive)
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let value = ADISForm.attr(tag, "value"), value.contains(label),
                  let name = ADISForm.attr(tag, "name") else { continue }
            return name
        }
        return nil
    }

    /// Account overview: <title> "Mein Konto …" (the lists are titled "Meine Ausleihen") and a
    /// recognizable service block. Checked after "Zur Übersicht" before navigating on from it.
    static func isOverviewPage(_ html: String) -> Bool {
        guard html.range(of: #"<title>\s*Mein Konto\b"#, options: .regularExpression) != nil else { return false }
        return parseLoanCount(html) != nil || parsePickupCount(html) != nil
    }

    // MARK: - Account info (overview page <dt>/<dd> list)

    /// One value of the overview page's `<dt>/<dd>` list ("Fällige Gebühren", "Abholcode",
    /// "Ausweis gültig bis", "Achtung" …), tags stripped; nil when the term is absent or empty.
    static func parseAccountInfo(_ html: String, term: String) -> String? {
        let pattern = "<dt[^>]*>\\s*" + NSRegularExpression.escapedPattern(for: term) + "\\s*</dt>\\s*<dd[^>]*>(.*?)</dd>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let value = stripHTML(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// First decimal amount in a text ("1,50 EUR" → 1.5).
    static func parseAmount(_ text: String) -> Double? {
        guard let m = text.range(of: #"\d+(?:[.,]\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[m].replacingOccurrences(of: ",", with: "."))
    }

    // MARK: - Renewability Probe ("Markierte Medien verlängerbar?")

    /// Parses the response of the "Markierte Medien verlängerbar?" probe. Each loan row
    /// then carries an explicit marker in the status cell: "verlängerbar - Stand …"
    /// (renewable) or "nicht verlängerbar : <Grund>- Stand …" (blocked).
    static func parseRenewability(_ html: String) -> [RenewabilityRow] {
        var rows: [RenewabilityRow] = []

        let trPattern = try! NSRegularExpression(
            pattern: #"<tr[^>]*class="[^"]*rTable_tr[^"]*"[^>]*>(.*?)</tr>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        let matches = trPattern.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard let rowRange = Range(match.range(at: 1), in: html) else { continue }
            let rowHTML = String(html[rowRange])

            // Checkbox value identifies the row for a follow-up submit; skip rows without one.
            let cbPattern = try! NSRegularExpression(pattern: #"value="(CheckCell[^"]*)"#, options: .caseInsensitive)
            guard let cbMatch = cbPattern.firstMatch(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML)),
                  let cbRange = Range(cbMatch.range(at: 1), in: rowHTML) else { continue }
            let checkboxValue = String(rowHTML[cbRange])

            // The renewability marker sits in a <b> tag: "verlängerbar …" or "nicht verlängerbar …".
            let markerPattern = try! NSRegularExpression(
                pattern: #"<b>\s*((?:nicht\s+)?verlängerbar[^<]*)"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
            guard let mMatch = markerPattern.firstMatch(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML)),
                  let mRange = Range(mMatch.range(at: 1), in: rowHTML) else { continue }
            let marker = stripHTML(String(rowHTML[mRange]))
            let lower = marker.lowercased()

            // Conservative: only "verlängerbar" without the "nicht" prefix counts as renewable.
            let renewable = !lower.contains("nicht verlängerbar")

            // Reason (blocked rows): text after " : ", e.g. "Verlängerung noch nicht möglich- Stand …".
            var reason = ""
            if let colon = marker.range(of: " : ") {
                reason = String(marker[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            let cols = extractAllTDContents(rowHTML)
            let title = cols.count > 3 ? cleanTitleColumn(cols[3]) : ""

            rows.append(RenewabilityRow(
                checkboxValue: checkboxValue,
                title: title,
                renewable: renewable,
                reason: reason
            ))
        }

        return rows
    }

    // MARK: - Catalog (Recherche) — enrichment

    struct CatalogHit {
        let isbn: String
        let coverURL: String
        let recordID: String
    }

    /// From a Trefferliste: the first cover-bearing result's ISBN + VLB cover URL (the cover
    /// `<img>` carries the ISBN in its `data-src`) and that SAME record's id (`data-ajax`, for the
    /// optional Vollanzeige). Returns nil when the search yields no ISBN-bearing result.
    static func parseCatalogResult(_ html: String) -> CatalogHit? {
        guard let isbnRange = html.range(of: #"/vlb/cover/(\d{10,13}[Xx]?)"#, options: .regularExpression) else {
            return nil
        }
        let isbn = String(html[isbnRange]).replacingOccurrences(of: "/vlb/cover/", with: "")
        let coverURL = "https://www.voebb.de/vlb/cover/\(isbn)/m"

        // Pick the data-ajax record id belonging to the SAME hit as the matched cover: the ISBN
        // may come from hit #2 when hit #1 has no cover, so "first id on the page" could pair the
        // cover with a different record's Vollanzeige. Nearest id before the cover wins (each
        // hit's container precedes its cover image), else the first one after, else none.
        var recordID = ""
        let idRegex = try! NSRegularExpression(pattern: #"data-ajax="([A-Z0-9]+)""#)
        var lastBefore: String?
        var firstAfter: String?
        for m in idRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let whole = Range(m.range, in: html), let value = Range(m.range(at: 1), in: html) else { continue }
            if whole.lowerBound < isbnRange.lowerBound {
                lastBefore = String(html[value])
            } else if firstAfter == nil {
                firstAfter = String(html[value])
            }
        }
        recordID = lastBefore ?? firstAfter ?? ""
        return CatalogHit(isbn: isbn, coverURL: coverURL, recordID: recordID)
    }

    struct CatalogDetail {
        let blurb: String
        let subjects: String
        let systematik: String
        let author: String
        let published: String
        let series: String
        let interessenkreis: String

        static let empty = CatalogDetail(blurb: "", subjects: "", systematik: "",
                                         author: "", published: "", series: "", interessenkreis: "")
    }

    /// From a Vollanzeige: blurb (Inhalt), subjects (Schlagwörter), shelf classification
    /// (Verbundsystematik), author (Verfasser), publication (Veröffentlichung → holds the year),
    /// series (Reihe) and target-audience/age (Interessenkreis). Fields are
    /// `<tr><th scope="row">L</th><td>…</td></tr>`; every field is optional.
    static func parseVollanzeige(_ html: String) -> CatalogDetail {
        // VÖBB labels the thematic subjects "Schlagwortkette" (older records: "Schlagwörter").
        var subjects = vollField(html, "Schlagwortkette")
        if subjects.isEmpty { subjects = vollField(html, "Schlagwörter") }
        var series = vollField(html, "Reihe")
        if series.isEmpty { series = vollField(html, "Gesamttitel") }
        // Der Klappentext steht mal unter "Inhalt", mal unter "Zusammenfassung".
        var blurb = vollField(html, "Inhalt")
        if blurb.isEmpty { blurb = vollField(html, "Zusammenfassung") }
        // "Veröffentlichung" kommt in manchen Datensätzen zweimal vor (Verlag + Jahr, in getrennten
        // Tabellen) → alle Zeilen zusammenfassen, damit die Jahreszahl mitkommt; notfalls das Jahr
        // aus einem separaten Feld nachziehen.
        var published = vollFieldAll(html, "Veröffentlichung", join: ", ")
        if published.range(of: #"\d{4}"#, options: .regularExpression) == nil {
            for yearLabel in ["Erscheinungsjahr", "Jahr"] {
                let y = vollField(html, yearLabel)
                if !y.isEmpty { published = published.isEmpty ? y : "\(published), \(y)"; break }
            }
        }
        return CatalogDetail(
            blurb: blurb,
            subjects: subjects,
            systematik: vollField(html, "Verbundsystematik"),
            // Mehrere Verfasser stehen als <a>…</a><br><a>…</a> in einer Zelle (oder in mehreren
            // Verfasser-Zeilen) → mit "; " trennen statt zu einem Namen zu verschmelzen.
            author: vollFieldAll(html, "Verfasser", join: "; "),
            published: published,
            series: series,
            interessenkreis: vollField(html, "Interessenkreis")
        )
    }

    private static func vollField(_ html: String, _ label: String) -> String {
        let pattern = "<th[^>]*>\\s*\(NSRegularExpression.escapedPattern(for: label))\\s*</th>\\s*<td[^>]*>(.*?)</td>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else { return "" }
        return stripHTML(String(html[r]))
    }

    /// Like `vollField`, but collects **every** `<th>label</th><td>…</td>` row and splits each cell
    /// on `<br>` — so repeated fields (a second "Veröffentlichung" row for the year) and multiple
    /// `<br>`-separated entries in one cell (co-authors) are all captured. Deduped, non-empty,
    /// joined with `separator`.
    private static func vollFieldAll(_ html: String, _ label: String, join separator: String) -> String {
        let pattern = "<th[^>]*>\\s*\(NSRegularExpression.escapedPattern(for: label))\\s*</th>\\s*<td[^>]*>(.*?)</td>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return "" }
        var parts: [String] = []
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let cell = String(html[r]).replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\u{1}", options: .regularExpression)
            for piece in cell.components(separatedBy: "\u{1}") {
                let clean = stripHTML(piece)
                if !clean.isEmpty, !parts.contains(clean) { parts.append(clean) }
            }
        }
        return parts.joined(separator: separator)
    }

    // MARK: - Helpers

    /// Title column: split on <br>, drop leading media-type tags like "[DVD-Video]".
    static func cleanTitleColumn(_ raw: String) -> String {
        parseTitleColumn(raw).title
    }

    /// Full breakdown of the title cell, which is `<br>`-separated:
    /// an optional leading media-type tag "[…]", the title, a shelf signature,
    /// and a trailing 9+ digit media number (barcode). Any part may be absent.
    static func parseTitleColumn(_ raw: String) -> (title: String, signature: String, mediaNumber: String, typeTag: String) {
        // Any <br> spelling (`<br/>`, `<BR />` …), like `vollFieldAll` — a literal split would fuse
        // title, signature and barcode into one part and lose the item's archive identity.
        var parts = raw
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\u{1}", options: .regularExpression)
            .components(separatedBy: "\u{1}")
            .map { stripHTML($0).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "¬", with: "") }
            .filter { !$0.isEmpty }

        // Leading media-type tag like "[DVD-Video]", "[Gerät (Laptop u.a.)]".
        let typeTagPattern = try! NSRegularExpression(pattern: #"^\[.+\]$"#)
        func isTypeTag(_ s: String) -> Bool {
            typeTagPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        var typeTag = ""
        if let first = parts.first, isTypeTag(first) {
            typeTag = first
            parts.removeFirst()
        }

        // Trailing media number: a part that is only digits (barcode), 9+ chars.
        var mediaNumber = ""
        if let last = parts.last, last.range(of: #"^\d{9,}$"#, options: .regularExpression) != nil {
            mediaNumber = last
            parts.removeLast()
        }

        // Shelf signature: whatever remains after the title (last remaining part),
        // but only if there is still a title line before it.
        var signature = ""
        if parts.count > 1, let last = parts.last {
            signature = last
            parts.removeLast()
        }

        let title = parts.first ?? ""
        return (title, signature, mediaNumber, typeTag)
    }

    /// All <td> contents in document order, regardless of class.
    private static func extractAllTDContents(_ html: String) -> [String] {
        matchAllFirstGroups(#"<td[^>]*>(.*?)</td>"#, in: html)
    }

    private static func matchAllFirstGroups(_ pattern: String, in html: String) -> [String] {
        var results: [String] = []
        let regex = try! NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            if let range = Range(match.range(at: 1), in: html) {
                results.append(String(html[range]))
            }
        }
        return results
    }

    private static let htmlEntities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#039;", "'"), ("&apos;", "'"),
        ("&nbsp;", " "), ("&#160;", " "),
        ("&auml;", "ä"), ("&ouml;", "ö"), ("&uuml;", "ü"),
        ("&Auml;", "Ä"), ("&Ouml;", "Ö"), ("&Uuml;", "Ü"), ("&szlig;", "ß"),
        ("&amp;", "&"),
    ]

    static func stripHTML(_ html: String) -> String {
        var result = html
        // Remove tags
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        // Decode numeric character references (&#8211; / &#x2013; — dashes, typographic quotes …)
        result = decodeNumericEntities(result)
        // Decode common named entities (&amp; last, so "&amp;lt;" doesn't double-decode)
        for (entity, char) in Self.htmlEntities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // Collapse whitespace
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces decimal (`&#8222;`) and hex (`&#x201E;`) character references with their characters.
    private static func decodeNumericEntities(_ s: String) -> String {
        guard s.contains("&#") else { return s }
        let regex = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#)
        var out = ""
        var cursor = s.startIndex
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s), let numRange = Range(m.range(at: 1), in: s) else { continue }
            let num = s[numRange]
            let value = num.hasPrefix("x") ? UInt32(num.dropFirst(), radix: 16) : UInt32(num)
            out += s[cursor..<whole.lowerBound]
            if let value, let scalar = Unicode.Scalar(value) {
                out.append(Character(scalar))
            } else {
                out += s[whole]   // undecodable — keep the raw reference
            }
            cursor = whole.upperBound
        }
        out += s[cursor...]
        return out
    }
}
