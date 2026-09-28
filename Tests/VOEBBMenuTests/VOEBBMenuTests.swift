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

// MARK: - Fees

@Suite struct FeesTests {
    @Test func dueFeesAndCardValidity() {
        let r = HTMLParser.parseFees("Fällige Gebühren 1,50 … Ausweis gültig bis 5.7.2027<br>")
        #expect(r.fees == 1.5)
        #expect(r.cardValid == "5.7.2027")
    }

    @Test func noFees() {
        #expect(HTMLParser.parseFees("Ausweis gültig bis 1.1.2027").fees == 0)
    }

    @Test func bareEuroAmountNeedsAGebuehrenPage() {
        #expect(HTMLParser.parseFees("Hinweis: Ersatzausweis 2,50 EUR").fees == 0)
        #expect(HTMLParser.parseFees("Gebühren: 2,50 EUR").fees == 2.5)
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
        #expect(LibraryName.short("Charlottenburg-Wilmersdorf: Adolf-Reichwein-Bibliothek") == "Adolf-Reichwein-Bibliothek")
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
