import Foundation

enum HTMLParser {
    // MARK: - Overview Page

    static func parseLoanCount(_ html: String) -> Int? {
        // Suche NUR innerhalb des #konto-services Blocks, damit
        // "Keine Ausleihen" in der Navigationsleiste nicht stört.
        let servicesHTML = extractKontoServices(html) ?? html

        if servicesHTML.contains("Keine Ausleihen") { return 0 }
        if let m = servicesHTML.range(of: #"(\d+)\s+Ausleihen"#, options: .regularExpression),
           let numStr = String(servicesHTML[m]).split(separator: " ").first,
           let n = Int(numStr) {
            return n
        }
        return nil
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
            mediaType: Loan.mediaType(typeTag: parsedTitle.typeTag, signature: parsedTitle.signature)
        )
    }

    // MARK: - Fees Page

    static func parseFees(_ html: String) -> (fees: Double, cardValid: String) {
        var fees = 0.0
        var cardValid = ""

        // Pattern: Fällige Gebühren 1.00
        // Fallback: a bare "1.00 EUR" — but ONLY on a page that talks about Gebühren at all,
        // otherwise any unrelated EUR amount (e.g. a fee-schedule hint) would be picked up.
        var feePatterns = [#"Fällige Gebühren\s+([\d,\.]+)"#]
        if html.contains("Gebühr") {
            feePatterns.append(#"([\d]+[,\.][\d]+)\s*EUR"#)
        }
        for pattern in feePatterns {
            if let m = html.range(of: pattern, options: .regularExpression) {
                let matchStr = String(html[m])
                // Extract number
                let numPattern = try! NSRegularExpression(pattern: #"([\d]+[,\.][\d]+)"#)
                let matchRange = NSRange(matchStr.startIndex..., in: matchStr)
                if let numMatch = numPattern.firstMatch(in: matchStr, range: matchRange),
                   let numRange = Range(numMatch.range(at: 1), in: matchStr) {
                    let numStr = String(matchStr[numRange])
                        .replacingOccurrences(of: ",", with: ".")
                    fees = Double(numStr) ?? 0
                    break
                }
            }
        }

        // Card validity: "Ausweis gültig bis 5.7.2026"
        if let m = html.range(of: #"Ausweis gültig bis\s+([^\s<]+)"#, options: .regularExpression) {
            let matchStr = String(html[m])
            cardValid = matchStr
                .replacingOccurrences(of: "Ausweis gültig bis", with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        return (fees, cardValid)
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
        return CatalogDetail(
            blurb: blurb,
            subjects: subjects,
            systematik: vollField(html, "Verbundsystematik"),
            author: vollField(html, "Verfasser"),
            published: vollField(html, "Veröffentlichung"),
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

    // MARK: - Helpers

    /// Title column: split on <br>, drop leading media-type tags like "[DVD-Video]".
    static func cleanTitleColumn(_ raw: String) -> String {
        parseTitleColumn(raw).title
    }

    /// Full breakdown of the title cell, which is `<br>`-separated:
    /// an optional leading media-type tag "[…]", the title, a shelf signature,
    /// and a trailing 9+ digit media number (barcode). Any part may be absent.
    static func parseTitleColumn(_ raw: String) -> (title: String, signature: String, mediaNumber: String, typeTag: String) {
        var parts = raw
            .components(separatedBy: "<br>")
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
