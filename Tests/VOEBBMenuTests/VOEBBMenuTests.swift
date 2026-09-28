import Foundation
import Testing
@testable import VOEBBMenu

// Pure-function tests for the fragile parts: regex scraping of aDISWeb HTML and the Tonie title
// match. Fixtures are minimal hand-written excerpts in the live markup's shape — no real account data.

// MARK: - Overview / loan count

@Suite struct LoanCountTests {
    @Test func plainSpace() {
        #expect(HTMLParser.parseLoanCount(#"<div id="konto-services">12 Ausleihen</div>"#) == 12)
    }

    @Test func newlineOrNbspBetweenNumberAndWord() {
        #expect(HTMLParser.parseLoanCount("<div id=\"konto-services\">3\n Ausleihen</div>") == 3)
        #expect(HTMLParser.parseLoanCount("<div id=\"konto-services\">7\u{00A0}Ausleihen</div>") == 7)
    }

    @Test func keineAusleihen() {
        #expect(HTMLParser.parseLoanCount(#"<div id="konto-services">Keine Ausleihen</div>"#) == 0)
    }

    @Test func navigationOutsideServicesBlockIsIgnored() {
        let html = #"<nav>Keine Ausleihen</nav><section id="konto-services">4 Ausleihen</section>"#
        #expect(HTMLParser.parseLoanCount(html) == 4)
    }
}

// MARK: - Title column

@Suite struct TitleColumnTests {
    @Test func fullCell() {
        let p = HTMLParser.parseTitleColumn("[Tonie]<br>Räuber Ratte<br>Tonie Donaldson<br>10000000042")
        #expect(p.typeTag == "[Tonie]")
        #expect(p.title == "Räuber Ratte")
        #expect(p.signature == "Tonie Donaldson")
        #expect(p.mediaNumber == "10000000042")
    }

    @Test(arguments: ["<br/>", "<br />", "<BR>", "<Br/>"])
    func everyBrSpelling(_ br: String) {
        let p = HTMLParser.parseTitleColumn("Der Grüffelo\(br)Kinder 1 Don\(br)12345678901")
        #expect(p.title == "Der Grüffelo")
        #expect(p.signature == "Kinder 1 Don")
        #expect(p.mediaNumber == "12345678901")
    }

    @Test func titleOnly() {
        let p = HTMLParser.parseTitleColumn("Nur ein Titel")
        #expect(p.title == "Nur ein Titel")
        #expect(p.signature.isEmpty && p.mediaNumber.isEmpty && p.typeTag.isEmpty)
    }
}

// MARK: - Loans page

@Suite struct LoansTests {
    private func row(_ statusCell: String) -> String {
        """
        <tr class="rTable_tr"><td><input type="checkbox" value="CheckCell$1"></td>\
        <td class="rTable_td_text">05.10.2026</td>\
        <td class="rTable_td_text">Mitte: Stadtbibliothek</td>\
        <td class="rTable_td_text">[DVD-Video]<br>Findet Nemo<br>DVD Kinder<br>12345678901</td>\
        \(statusCell)</tr>
        """
    }

    @Test func parsesRow() throws {
        let loans = HTMLParser.parseLoans(row(#"<td class="rTable_td_text">1x verlängert</td>"#))
        let loan = try #require(loans.first)
        #expect(loans.count == 1)
        #expect(loan.title == "Findet Nemo")
        #expect(loan.dueDateString == "05.10.2026")
        #expect(loan.library == "Mitte: Stadtbibliothek")
        #expect(loan.mediaNumber == "12345678901")
        #expect(loan.mediaType == "DVD/Video")
        #expect(loan.checkboxValue == "CheckCell$1")
    }

    @Test func zellefStatusCellStillCounts() {
        let loans = HTMLParser.parseLoans(row(#"<td class="zellef">Keine Verlängerung: Vormerkungen</td>"#))
        #expect(loans.first?.renewalStatus == "Keine Verlängerung: Vormerkungen")
    }
}

// MARK: - Renewability probe

@Suite struct RenewabilityTests {
    private let html = """
    <tr class="rTable_tr"><td><input value="CheckCell$1"></td><td>x</td><td>x</td><td>Buch A</td>\
    <td><b>verlängerbar - Stand 28.09.2026</b></td></tr>
    <tr class="rTable_tr"><td><input value="CheckCell$2"></td><td>x</td><td>x</td><td>Buch B</td>\
    <td><b>nicht verlängerbar : Verlängerung noch nicht möglich- Stand 28.09.2026</b></td></tr>
    """

    @Test func bothMarkers() {
        let rows = HTMLParser.parseRenewability(html)
        #expect(rows.map(\.renewable) == [true, false])
        #expect(rows.map(\.title) == ["Buch A", "Buch B"])
        #expect(rows.last?.shortReason == "Verlängerung noch nicht möglich")
    }
}

// MARK: - Account info (overview <dt>/<dd>)

@Suite struct AccountInfoTests {
    /// Shape of the live overview's definition list (whitespace/newlines inside dt/dd included).
    static func overview(_ rows: [(String, String)]) -> String {
        let items = rows.map { "<dt class=\"adis-term\">\n  \($0.0)\n </dt>\n <dd class=\"adis-value\">\n  \($0.1)\n </dd>" }
        return "<title>Mein Konto</title><dl>\n" + items.joined(separator: "\n") + "\n</dl>"
    }

    @Test func fieldsAreRead() {
        let html = Self.overview([("Fällige Gebühren", "1,50 EUR"), ("Ausweis gültig bis", "12.08.2027"),
                                  ("Kontostand vom:", "01.10.2026"), ("Abholcode", "00 Xx")])
        #expect(HTMLParser.parseAccountInfo(html, term: "Fällige Gebühren") == "1,50 EUR")
        #expect(HTMLParser.parseAccountInfo(html, term: "Ausweis gültig bis") == "12.08.2027")
        #expect(HTMLParser.parseAccountInfo(html, term: "Abholcode") == "00 Xx")
        #expect(HTMLParser.parseAccountInfo(html, term: "Achtung") == nil)
    }

    @Test func amounts() {
        #expect(HTMLParser.parseAmount("0.40 EUR") == 0.40)
        #expect(HTMLParser.parseAmount("1,50") == 1.5)
        #expect(HTMLParser.parseAmount("12 EUR") == 12)
        #expect(HTMLParser.parseAmount("keine") == nil)
    }

    @Test func applyReadsEverything() {
        var data = AccountData(account: LibraryAccount(name: "T", cardNumber: "0"))
        VOEBBSession.applyAccountInfo(fromOverview: Self.overview([
            ("Fällige Gebühren", "0.40 EUR"), ("Ausweis gültig bis", "12.08.2027"),
            ("Abholcode", "00 Xx"), ("Achtung", "Ausweis läuft in 14 Tagen ab"),
        ]), to: &data)
        #expect(data.fees == 0.40)
        #expect(!data.feesUnknown)
        #expect(data.pickupCode == "00 Xx")
        #expect(data.cardValidUntil == "12.08.2027")
        #expect(data.cardExpiryWarning == "Ausweis läuft in 14 Tagen ab")
    }

    @Test func missingFeesRowOnRecognizableOverviewIsZero() {
        var data = AccountData(account: LibraryAccount(name: "T", cardNumber: "0"))
        VOEBBSession.applyAccountInfo(fromOverview: Self.overview([("Kontostand vom:", "01.10.2026")]), to: &data)
        #expect(data.fees == 0)
        #expect(!data.feesUnknown)
    }

    @Test func unrecognizablePageMeansFeesUnknown() {
        var data = AccountData(account: LibraryAccount(name: "T", cardNumber: "0"))
        VOEBBSession.applyAccountInfo(fromOverview: "<html>Wartungsarbeiten</html>", to: &data)
        #expect(data.feesUnknown)
        #expect(data.pickupCode == nil)
    }
}

// MARK: - Loan list validation (parse monitor)

@Suite struct ValidateLoansTests {
    static func loans(_ n: Int) -> [Loan] {
        (0..<n).map { Loan(title: "T\($0)", dueDate: Date(), dueDateString: "", library: "B",
                          renewalStatus: "", checkboxValue: "c\($0)") }
    }

    @Test func overviewSaysNoneIsFine() throws {
        try VOEBBSession.validateLoans([], expectedCount: 0, previousCount: 5, pageHTML: "")
    }

    @Test func emptyOrShortListAgainstOverviewThrows() {
        #expect(throws: VOEBBError.self) {
            try VOEBBSession.validateLoans([], expectedCount: 3, previousCount: nil, pageHTML: "rTable")
        }
        #expect(throws: VOEBBError.self) {
            try VOEBBSession.validateLoans(Self.loans(2), expectedCount: 3, previousCount: nil, pageHTML: "rTable")
        }
    }

    @Test func completeListPasses() throws {
        try VOEBBSession.validateLoans(Self.loans(3), expectedCount: 3, previousCount: nil, pageHTML: "")
    }

    @Test func unknownOverviewCount() throws {
        // Loans before → an empty list is suspicious.
        #expect(throws: VOEBBError.self) {
            try VOEBBSession.validateLoans([], expectedCount: nil, previousCount: 2, pageHTML: "Meine Ausleihen")
        }
        // No history: empty is fine only on a recognizable loans page.
        try VOEBBSession.validateLoans([], expectedCount: nil, previousCount: nil, pageHTML: "<h1>Meine Ausleihen</h1>")
        #expect(throws: VOEBBError.self) {
            try VOEBBSession.validateLoans([], expectedCount: nil, previousCount: nil, pageHTML: "<html>Fehler</html>")
        }
    }

    @Test func errorsCarryTheParseMonitorMarker() {
        do {
            try VOEBBSession.validateLoans(Self.loans(1), expectedCount: 3, previousCount: nil, pageHTML: "")
            Issue.record("expected throw")
        } catch {
            #expect(error.localizedDescription.contains(VOEBBSession.parseBrokenMarker))
        }
    }
}

// MARK: - requestCount

@Suite struct RequestCountTests {
    @Test func echoedFromThePage() throws {
        let html = #"<input type="hidden" name="requestCount" value="5"><input type="hidden" name="identity" value="x">"#
        #expect(try VOEBBSession.requiredRequestCount(in: ADISForm.extractHiddenInputs(html)) == "5")
    }

    @Test func missingOrInvalidThrows() {
        #expect(throws: VOEBBError.self) { try VOEBBSession.requiredRequestCount(in: [:]) }
        #expect(throws: VOEBBError.self) { try VOEBBSession.requiredRequestCount(in: ["requestCount": "abc"]) }
        #expect(throws: VOEBBError.self) { try VOEBBSession.requiredRequestCount(in: ["requestCount": ""]) }
    }
}

// MARK: - Renewal verification

@Suite struct RenewalVerifierTests {
    private static let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = day
        return Self.calendar.date(from: c)!
    }

    private func loan(_ title: String, due day: Int, cb: String, library: String = "Bib", barcode: String = "") -> Loan {
        Loan(title: title, dueDate: date(day), dueDateString: "\(day).10.2026", library: library,
             renewalStatus: "", checkboxValue: cb, mediaNumber: barcode)
    }

    private func row(_ title: String, cb: String) -> RenewabilityRow {
        RenewabilityRow(checkboxValue: cb, title: title, renewable: true, reason: "")
    }

    @Test func allRenewed() {
        let before = [loan("A", due: 5, cb: "c0"), loan("B", due: 5, cb: "c1")]
        let after  = [loan("A", due: 26, cb: "c0"), loan("B", due: 26, cb: "c1")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0"), row("B", cb: "c1")], before: before, after: after)
        #expect(r.confirmed.map(\.title) == ["A", "B"])
        #expect(r.unconfirmed.isEmpty)
        #expect(!r.unverifiable)
    }

    @Test func partialSuccess() {
        let before = [loan("A", due: 5, cb: "c0"), loan("B", due: 5, cb: "c1"), loan("C", due: 9, cb: "c2")]
        let after  = [loan("A", due: 26, cb: "c0"), loan("B", due: 5, cb: "c1"), loan("C", due: 9, cb: "c2")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0"), row("B", cb: "c1")], before: before, after: after)
        #expect(r.confirmed.map(\.title) == ["A"])
        #expect(r.unconfirmed.map(\.title) == ["B"])
    }

    @Test func nothingChangedIsNotSuccess() {
        let before = [loan("A", due: 5, cb: "c0")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0")], before: before, after: before)
        #expect(r.confirmed.isEmpty)
        #expect(r.unconfirmed.map(\.title) == ["A"])
        #expect(!r.unverifiable)
    }

    @Test func unreadableResultPageIsUnverifiable() {
        let before = [loan("A", due: 5, cb: "c0")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0")], before: before, after: [])
        #expect(r.unconfirmed.map(\.title) == ["A"])
        #expect(r.unverifiable)
    }

    @Test func reorderedResultStillMatches() {
        let before = [loan("A", due: 5, cb: "c0"), loan("B", due: 9, cb: "c1")]
        let after  = [loan("B", due: 9, cb: "c0"), loan("A", due: 26, cb: "c1")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0")], before: before, after: after)
        #expect(r.confirmed.map(\.title) == ["A"])
    }

    @Test func duplicateCopiesCountedNotDoubled() {
        let before = [loan("A", due: 5, cb: "c0"), loan("A", due: 5, cb: "c1")]
        let after  = [loan("A", due: 26, cb: "c0"), loan("A", due: 5, cb: "c1")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0"), row("A", cb: "c1")], before: before, after: after)
        #expect(r.confirmed.count == 1)
        #expect(r.unconfirmed.count == 1)
    }

    @Test func barcodeIdentifiesTheExactCopy() {
        // With barcodes, the renewed copy is attributed exactly, not just counted per group.
        let before = [loan("A", due: 5, cb: "c0", barcode: "11"), loan("A", due: 5, cb: "c1", barcode: "22")]
        let after  = [loan("A", due: 5, cb: "c0", barcode: "11"), loan("A", due: 26, cb: "c1", barcode: "22")]
        let r = RenewalVerifier.verify(submitted: [row("A1", cb: "c0"), row("A2", cb: "c1")], before: before, after: after)
        #expect(r.confirmed.map(\.title) == ["A2"])
        #expect(r.unconfirmed.map(\.title) == ["A1"])
    }

    @Test func sameTitleDifferentLibraryIsSeparate() {
        let before = [loan("A", due: 5, cb: "c0", library: "X"), loan("A", due: 5, cb: "c1", library: "Y")]
        let after  = [loan("A", due: 26, cb: "c0", library: "X"), loan("A", due: 5, cb: "c1", library: "Y")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c1")], before: before, after: after)
        #expect(r.confirmed.isEmpty)
    }

    @Test func preexistingLaterCopyIsNotSuccess() {
        let before = [loan("A", due: 5, cb: "c0"), loan("A", due: 26, cb: "c1")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0")], before: before, after: before)
        #expect(r.confirmed.isEmpty)
        #expect(r.unconfirmed.count == 1)
    }

    @Test func renewedNextToAlreadyLaterCopy() {
        let before = [loan("A", due: 5, cb: "c0"), loan("A", due: 26, cb: "c1")]
        let after  = [loan("A", due: 26, cb: "c0"), loan("A", due: 26, cb: "c1")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0")], before: before, after: after)
        #expect(r.confirmed.count == 1)
    }

    @Test func unrelatedCopyChangeDoesNotConfirm() {
        let before = [loan("A", due: 5, cb: "c0"), loan("A", due: 9, cb: "c1")]
        let after  = [loan("A", due: 5, cb: "c0"), loan("A", due: 30, cb: "c1")]
        let r = RenewalVerifier.verify(submitted: [row("A", cb: "c0")], before: before, after: after)
        #expect(r.confirmed.isEmpty)
    }

    @Test func outcomeMessages() {
        let a = row("A", cb: "c0"), b = row("B", cb: "c1")
        #expect(RenewalOutcome(renewed: [a]).userMessage.hasPrefix("1 Medium verlängert."))
        let partial = RenewalOutcome(renewed: [a], unconfirmed: [b]).userMessage
        #expect(partial.contains("Nicht bestätigt"))
        #expect(partial.contains("• B"))
        let unverifiable = RenewalOutcome(unconfirmed: [a], unverifiable: true).userMessage
        #expect(unverifiable.hasPrefix("Keine Verlängerung bestätigt."))
        #expect(unverifiable.contains("nicht überprüft"))
        #expect(RenewalOutcome().userMessage == "Keine Medien verlängert.")
    }
}

// MARK: - HTML helpers

@Suite struct HTMLHelperTests {
    @Test func stripHTMLDecodesEntities() {
        #expect(HTMLParser.stripHTML("<b>Max &amp; Moritz</b> &#8211; &uuml;ber&nbsp;alles") == "Max & Moritz – über alles")
        #expect(HTMLParser.stripHTML("&amp;lt;") == "&lt;")   // &amp; decoded last, no double decode
    }

    @Test func hiddenInputs() {
        let html = #"<input type="hidden" name="sp" value="SAK123"><input type='hidden' name='empty'><input type="text" name="q" value="x">"#
        #expect(ADISForm.extractHiddenInputs(html) == ["sp": "SAK123", "empty": ""])
    }

    @Test func attr() {
        #expect(ADISForm.attr(#"<form action="/aDISWeb/_abc/app" method="post">"#, "action") == "/aDISWeb/_abc/app")
        #expect(ADISForm.attr("<form>", "action") == nil)
    }

    @Test func catalogHitPairsCoverWithItsOwnRecord() throws {
        let html = #"<div data-ajax="AK1">no cover</div><div data-ajax="AK2"><img data-src="/vlb/cover/9783551551672/m"></div>"#
        let hit = try #require(HTMLParser.parseCatalogResult(html))
        #expect(hit.isbn == "9783551551672")
        #expect(hit.recordID == "AK2")
        #expect(HTMLParser.parseCatalogResult("<p>Keine Treffer</p>") == nil)
    }
}

// MARK: - Models

@Suite struct ModelTests {
    @Test func libraryShortName() {
        #expect(LibraryName.short("Charlottenburg-Wilmersdorf: Adolf-Reichwein-Bibliothek") == "Adolf Reichwein")
        #expect(LibraryName.short("Ohne Bezirk") == "Ohne Bezirk")
    }

    @Test func mediaTypeInference() {
        #expect(Loan.inferMediaType(typeTag: "[Tonie]", signature: "") == "Tonie")
        #expect(Loan.inferMediaType(typeTag: "", signature: "CD Kinder") == "CD/Hörbuch")
        #expect(Loan.inferMediaType(typeTag: "[Gerät (Laptop u.a.)]", signature: "") == "Gerät")
        #expect(Loan.inferMediaType(typeTag: "", signature: "Kinder 1 Don") == "Buch")
    }
}

// MARK: - Tonie title match

@Suite struct TonieMatchTests {
    private typealias T = ToniesEnricher.Tonie

    @Test func apostropheLinesUpWithVOEBBGenitive() {
        #expect(ToniesEnricher.tokens("Leo's Tag").contains("leos"))
        #expect(ToniesEnricher.tokens("Der, die & das 3 du").isEmpty)   // stopwords, short, digits
    }

    @Test func titleVariants() {
        #expect(ToniesEnricher.titleVariants("Der kleine Wassermann (Neuauflage 2022)")
            .map { $0.trimmingCharacters(in: .whitespaces) } == ["Der kleine Wassermann"])
        #expect(ToniesEnricher.titleVariants("Räuber Ratte/Superwurm") == ["Räuber Ratte/Superwurm", "Räuber Ratte", "Superwurm"])
    }

    // The three cases that used to miss (2026-09-28) plus a regular hit.
    @Test(arguments: [
        ("Der kleine Wassermann / Otfried Preußler ; Frauke Poolman [Erzähler/in]", "Der kleine Wassermann (Neuauflage 2022)", "Der kleine Wassermann"),
        ("Räuber Ratte : mit Liedern / Julia Donaldson ; Axel Scheffler", "Räuber Ratte/Superwurm", "Räuber Ratte"),
        ("Der Tag, an dem Michel besonders nett sein wollte / Peter Kaempfe [Erzähler/in]",
         "Der Tag, an dem Michel besonders nett sein wollte", "Michel aus Lönneberga"),
        ("Sternenschweif : geheimnisvolle Verwandlung / Linda Chapman", "Geheimnisvolle Verwandlung", "Sternenschweif"),
    ])
    func matches(_ voebb: String, _ title: String, _ series: String) {
        let pool = [T(title: "Kindischer Ozean", series: "Willy Astor", imageUrl: "other"),
                    T(title: title, series: series, imageUrl: "hit")]
        #expect(ToniesEnricher.bestMatch(for: voebb, in: pool)?.imageUrl == "hit")
    }

    @Test func sameSeriesDifferentEpisodeDoesNotMatch() {
        let pool = [T(title: "Rock'n Rarrr Music", series: "Heavysaurus", imageUrl: "x")]
        #expect(ToniesEnricher.bestMatch(for: "Heavysaurus - Pommesgabel : Best of Dino Metal / X", in: pool) == nil)
    }
}

// MARK: - Catalog title search terms

@Suite struct TitleSearchTermsTests {
    @Test func foldsNonLatin1DiacriticsButKeepsGermanLetters() {
        #expect(CatalogEnricher.foldRareDiacritics("Sasha Ḥaddad") == "Sasha Haddad")
        #expect(CatalogEnricher.foldRareDiacritics("Übersetzer/in Größe Café") == "Übersetzer/in Größe Café")
    }

    @Test func fallsBackToFoldedThenBareTitle() {
        let terms = CatalogEnricher.titleSearchTerms("Ob nah / Racha Mourtada [Textdichter/in] ; Sasha Ḥaddad [Illustrator/in]")
        #expect(terms == ["Ob nah / Racha Mourtada [Textdichter/in] ; Sasha Ḥaddad [Illustrator/in]",
                          "Ob nah / Racha Mourtada [Textdichter/in] ; Sasha Haddad [Illustrator/in]",
                          "Ob nah"])
    }

    @Test func noDuplicateTermsForAPlainTitle() {
        #expect(CatalogEnricher.titleSearchTerms("Räuber Ratte") == ["Räuber Ratte"])
        #expect(CatalogEnricher.titleSearchTerms("Wohin fließt das Badewasser? : mit Klappen / Katja Reider")
                == ["Wohin fließt das Badewasser? : mit Klappen / Katja Reider", "Wohin fließt das Badewasser? : mit Klappen"])
    }
}

// MARK: - Library short names

@Suite struct LibraryNameTests {
    @Test func tableAndAmbiguity() {
        #expect(LibraryName.short("Lichtenberg: Egon-Erwin-Kisch-Bibliothek") == "Egon Erwin Kisch")
        #expect(LibraryName.short("Pankow: Kurt-Tucholsky-Bibliothek") == "Kurt Tucholsky · Pankow")
        #expect(LibraryName.short("Mitte: Kurt-Tucholsky-Bibliothek") == "Kurt Tucholsky · Mitte")
    }

    @Test func fallbackForUnknownNames() {
        #expect(LibraryName.short("Steglitz-Zehlendorf: Stadtteilbibliothek Neuerfunden") == "Neuerfunden")
    }
}
