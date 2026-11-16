import Testing
@testable import VOEBBMenu

// The exact form fields aDIS gets. They were reverse-engineered from the live site; a refactor
// that drops or renames one makes aDIS answer with the wrong page instead of an error, so each
// request's field set is pinned here.

@Suite struct ADISRequestTests {
    private let hidden = ["requestCount": "3", "token": "abc"]

    @Test func selectedKeepsTheFixedWidthColumn() {
        #expect(ADISForm.selected("*SZA") == "ZTEXT" + String(repeating: " ", count: 7) + "*SZA")
    }

    @Test func navigationAddsTheNavCodeAndEchoesThePage() {
        #expect(ADISForm.navigation("*SZA", from: hidden) == [
            "requestCount": "3", "token": "abc",
            "scriptEnabled": "true", "overrideScrollPos": "0",
            "selected": "ZTEXT       *SZA", "$Select": "Überall suchen",
        ])
    }

    @Test func appURLIsSessionBound() {
        #expect(ADISHTTP.appURL(sessionID: "_abc123") == "https://www.voebb.de/aDISWeb/_abc123/app")
    }

    @Test func catalogSearch() {
        #expect(CatalogEnricher.searchFields(hidden: hidden, term: "Findet Nemo") == [
            "token": "abc",
            "keyCode": "0", "focus": "$$GFBO_1", "stz": "", "source": "$B", "selected": "",
            "requestCount": "1", "scriptEnabled": "true", "scrollPos": "0", "overrideScrollPos": "0",
            "$Autosuggest": "Findet Nemo", "$Select": "Überall suchen", "$Button": "pressed",
        ])
    }

    @Test func catalogVollanzeige() {
        #expect(CatalogEnricher.vollanzeigeFields(hidden: hidden, recordID: "AK34420649", term: "Findet Nemo") == [
            "token": "abc",
            "keyCode": "0", "focus": "", "stz": "", "source": "", "selected": "ZTEXT       AK34420649",
            "requestCount": "2", "scriptEnabled": "true", "scrollPos": "0", "overrideScrollPos": "0",
            "$Autosuggest": "Findet Nemo", "$Select": "Überall suchen", "$Tab": "0",
        ])
    }
}
