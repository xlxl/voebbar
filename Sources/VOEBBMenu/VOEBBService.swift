import Foundation

enum VOEBBError: LocalizedError {
    case loginFailed(String)
    case networkError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .loginFailed(let msg): return "Login fehlgeschlagen: \(msg)"
        case .networkError(let msg): return "Netzwerkfehler: \(msg)"
        case .parseError(let msg): return "Fehler beim Lesen: \(msg)"
        }
    }
}

// Per-account scraping session
final class VOEBBSession {
    private let baseURL = "https://www.voebb.de"
    private let session: URLSession
    private let account: LibraryAccount

    init(account: LibraryAccount) {
        self.account = account
        self.session = ADISHTTP.makeSession()
    }

    // MARK: - Public API

    /// Distinctive prefix for the parse-monitor errors so callers can tell "our scraping broke"
    /// apart from ordinary login/network failures (and notify about it).
    static let parseBrokenMarker = "Ausleihen nicht lesbar"

    func fetchAccountData(password: String, previousLoanCount: Int? = nil) async throws -> AccountData {
        let (appURL, overviewHTML) = try await login(password: password)
        var data = AccountData(account: account)

        // Everything account-level sits in the overview's <dt>/<dd> list — no *SGG navigation.
        // (Navigating *SGG from the probe result page is silently ignored by aDIS: it returns the
        // loans page again, and fees read as 0 € for accounts with loans AND fees.)
        Self.applyAccountInfo(fromOverview: overviewHTML, to: &data)

        let loanCount = HTMLParser.parseLoanCount(overviewHTML)
        // Every page carries a new single-use identity token, so the next request (incl. the
        // logout) always has to start from the page loaded last.
        var currentHTML = overviewHTML

        // loanCount == 0  → definitiv keine Ausleihen
        // loanCount > 0   → Ausleihen vorhanden, Seite abrufen
        // loanCount == nil → Erkennung unsicher, Ausleihen trotzdem probieren
        if loanCount != 0 {
            let (loansHTML, loansURL) = try await navigate(appURL: appURL, fromHTML: overviewHTML, navCode: "*SZA")
            currentHTML = loansHTML
            var parsed = HTMLParser.parseLoans(loansHTML)

            // Parse-Monitor: a wrongly empty or short list would make the archive close open
            // loans as returned — history damage. So it throws instead (see validateLoans).
            do {
                try Self.validateLoans(parsed, expectedCount: loanCount,
                                       previousCount: previousLoanCount, pageHTML: loansHTML)
            } catch {
                await logout(appURL: appURL, fromHTML: loansHTML)
                throw error
            }

            if !parsed.isEmpty {
                // Verlängerbarkeit proben ("Markierte Medien verlängerbar?", lesend) und
                // pro Buch mergen. Fehlertolerant: ohne Probe bleiben die Felder einfach nil.
                do {
                    let probe = try await probeRenewability(
                        appURL: appURL, fromHTML: loansHTML, referer: loansURL,
                        checkboxValues: parsed.map(\.checkboxValue).filter { !$0.isEmpty }
                    )
                    currentHTML = probe.html
                    let byCheckbox = Dictionary(probe.rows.map { ($0.checkboxValue, $0) },
                                                uniquingKeysWith: { first, _ in first })
                    for i in parsed.indices {
                        if let s = byCheckbox[parsed[i].checkboxValue] {
                            parsed[i].isRenewable = s.renewable
                            parsed[i].renewalReason = s.reason
                        }
                    }
                } catch {
                    // Probe fehlgeschlagen → Ausleihen ohne Verlängerbarkeits-Info anzeigen
                }
                data.loans = parsed
            }
        }

        // Pickups ("Bereitstellungen"), only when the overview announces some. aDIS silently
        // ignores a list→list navigation (after *SZA, *SZS returns the loans again), so go back
        // via the page's "Zur Übersicht" button first. Never press anything on the pickups page
        // itself — it carries "Markierte Medien löschen". Fallback: a fresh session.
        switch HTMLParser.parsePickupCount(overviewHTML) {
        case .some(0):
            data.pickups = []
        case .some(let expected):
            var pickups: [PickupItem]?
            do {
                let overviewAgain = try await returnToOverview(appURL: appURL, fromHTML: currentHTML)
                let (html, _) = try await navigate(appURL: appURL, fromHTML: overviewAgain, navCode: "*SZS")
                currentHTML = html
                if HTMLParser.isPickupsPage(html) { pickups = HTMLParser.parsePickups(html) }
            } catch {
                // Back-navigation or *SZS failed → fresh session below
            }
            if pickups == nil {
                pickups = try? await VOEBBSession(account: account).fetchPickups(password: password)
            }
            // A short list would drop pickups from the archive snapshot — treat it as unknown.
            if let pickups, pickups.count >= expected { data.pickups = pickups }
        case .none:
            break  // unknown → archive leaves this account's pickups untouched
        }

        await logout(appURL: appURL, fromHTML: currentHTML)
        data.lastUpdated = Date()
        return data
    }

    /// Back to the account overview via the current page's "Zur Übersicht" button (looked up by
    /// label — its $Button$N differs per page). Returns the page unchanged if it already is the
    /// overview; throws if there's no such button or the response isn't the overview.
    private func returnToOverview(appURL: String, fromHTML: String) async throws -> String {
        if HTMLParser.isOverviewPage(fromHTML) { return fromHTML }
        guard let button = HTMLParser.findSubmitButton(labelContaining: "Zur Übersicht", in: fromHTML) else {
            throw VOEBBError.parseError("„Zur Übersicht“-Button nicht gefunden")
        }
        let html = try await pressButton(appURL: appURL, fromHTML: fromHTML, referer: appURL,
                                         buttonField: button, focusID: "", checkboxValues: [])
        guard HTMLParser.isOverviewPage(html) else {
            throw VOEBBError.parseError("Rücksprung lieferte keine Kontoübersicht")
        }
        return html
    }

    /// Fallback in a fresh session: login → pickups (*SZS) → logout.
    private func fetchPickups(password: String) async throws -> [PickupItem] {
        let (appURL, overviewHTML) = try await login(password: password)
        let (html, _) = try await navigate(appURL: appURL, fromHTML: overviewHTML, navCode: "*SZS")
        await logout(appURL: appURL, fromHTML: html)
        guard HTMLParser.isPickupsPage(html) else {
            throw VOEBBError.parseError("Bereitstellungs-Seite nicht erkannt")
        }
        return HTMLParser.parsePickups(html)
    }

    /// Fees, pickup code, card validity and VÖBB's expiry warning from the overview's `<dt>/<dd>`
    /// list. A missing fees row counts as 0 € only when the page is recognizably the overview
    /// (other terms present); otherwise `feesUnknown` is set instead of silently reporting 0.
    static func applyAccountInfo(fromOverview html: String, to data: inout AccountData) {
        if let raw = HTMLParser.parseAccountInfo(html, term: "Fällige Gebühren"),
           let amount = HTMLParser.parseAmount(raw) {
            data.fees = amount
        } else if HTMLParser.parseAccountInfo(html, term: "Kontostand vom:") != nil
                    || HTMLParser.parseAccountInfo(html, term: "Abholcode") != nil
                    || HTMLParser.parseAccountInfo(html, term: "Ausweis gültig bis") != nil {
            data.fees = 0
        } else {
            data.feesUnknown = true
        }
        data.pickupCode = HTMLParser.parseAccountInfo(html, term: "Abholcode")
        data.cardValidUntil = HTMLParser.parseAccountInfo(html, term: "Ausweis gültig bis") ?? ""
        data.cardExpiryWarning = HTMLParser.parseAccountInfo(html, term: "Achtung")
    }

    /// Cross-checks the parsed loans list against the overview's count. A parser/page failure must
    /// never look like an empty (or shorter) account:
    /// - overview says N > 0, list is empty or shorter → markup break
    /// - overview unreadable (nil), list empty, and there were loans before → conservatively broken
    /// - overview unreadable, list empty, page not even recognizable as the loans list → broken
    static func validateLoans(_ parsed: [Loan], expectedCount: Int?, previousCount: Int?, pageHTML: String) throws {
        if let expected = expectedCount {
            guard expected > 0 else { return }  // Übersicht sagt explizit: keine Ausleihen
            if parsed.isEmpty {
                throw VOEBBError.parseError("\(parseBrokenMarker) (Übersicht meldet \(expected)) – VÖBB-Markup geändert? Archiv bleibt unangetastet.")
            }
            if parsed.count < expected {
                throw VOEBBError.parseError("\(parseBrokenMarker) (nur \(parsed.count) von \(expected) gelesen) – VÖBB-Markup geändert? Archiv bleibt unangetastet.")
            }
        } else if parsed.isEmpty {
            if let prev = previousCount, prev > 0 {
                throw VOEBBError.parseError("\(parseBrokenMarker) (vorher \(prev), Übersicht unlesbar) – VÖBB-Markup geändert? Archiv bleibt unangetastet.")
            }
            let looksLikeLoansPage = pageHTML.contains("Meine Ausleihen") || pageHTML.contains("rTable")
            if !looksLikeLoansPage {
                throw VOEBBError.parseError("\(parseBrokenMarker) (Ausleihseite nicht erkannt) – VÖBB-Markup geändert? Archiv bleibt unangetastet.")
            }
        }
    }

    /// Ends the aDIS session server-side (nav code *SE). Fire-and-forget: errors are ignored on
    /// purpose; it only avoids orphaned sessions at VÖBB.
    private func logout(appURL: String, fromHTML: String) async {
        _ = try? await navigate(appURL: appURL, fromHTML: fromHTML, navCode: "*SE")
    }

    /// Renews all renewable loans.
    func renewAllLoans(password: String) async throws -> RenewalOutcome {
        try await renewLoans(password: password) { _ in true }
    }

    /// Renews only loans due within `days` days (overdue included), and only those.
    func renewDueLoans(password: String, withinDays days: Int) async throws -> RenewalOutcome {
        try await renewLoans(password: password) { $0.daysUntilDue <= days }
    }

    /// Renews exactly the loans identified by `keys` (see `Loan.renewalKey`), and only those.
    /// The keys come from an earlier refresh, so an item may have been returned meanwhile — that
    /// case is reported instead of silently renewing nothing.
    func renewLoans(password: String, keys: Set<String>) async throws -> RenewalOutcome {
        try await renewLoans(
            password: password,
            noMatchMessage: "Nicht mehr in der Ausleihliste – zwischenzeitlich zurückgegeben oder verlängert? Bitte aktualisieren."
        ) { keys.contains($0.renewalKey) }
    }

    /// Renewal is a two-step flow because BOTH "Alle verlängern" and "Markierte Medien
    /// verlängern" abort the entire batch if a single selected item is blocked (e.g. by a
    /// Vormerkung). So we first probe renewability ("Markierte Medien verlängerbar?",
    /// $Button$2) on the selected candidates, then submit only the confirmed-renewable ones
    /// ("Markierte Medien verlängern", $Button$1). See memory `voebb-renewal-button-mapping`.
    /// `select` narrows which loans are considered (e.g. only soon-due ones); `noMatchMessage` is
    /// reported when the selection matches no current loan (relevant for key-based selection,
    /// where the target may have been returned since the last refresh).
    private func renewLoans(
        password: String,
        noMatchMessage: String? = nil,
        selecting select: (Loan) -> Bool
    ) async throws -> RenewalOutcome {
        let (appURL, overviewHTML) = try await login(password: password)

        let (loansHTML, loansURL) = try await navigate(appURL: appURL, fromHTML: overviewHTML, navCode: "*SZA")
        let loans = HTMLParser.parseLoans(loansHTML)
        // An unreadable loans page must not end as "Keine Ausleihen vorhanden".
        do {
            try Self.validateLoans(loans, expectedCount: HTMLParser.parseLoanCount(overviewHTML),
                                   previousCount: nil, pageHTML: loansHTML)
        } catch {
            await logout(appURL: appURL, fromHTML: loansHTML)
            throw error
        }

        guard !loans.isEmpty else {
            await logout(appURL: appURL, fromHTML: loansHTML)
            return RenewalOutcome(specialMessage: "Keine Ausleihen vorhanden")
        }

        // Only the selected candidates are probed/renewed — never touch the others.
        let candidateCheckboxes = loans.filter(select).map(\.checkboxValue).filter { !$0.isEmpty }
        guard !candidateCheckboxes.isEmpty else {
            await logout(appURL: appURL, fromHTML: loansHTML)
            return RenewalOutcome(specialMessage: noMatchMessage)
        }

        // Step 1: probe "verlängerbar?" ($Button$2) with only the candidates checked.
        let probe = try await probeRenewability(
            appURL: appURL, fromHTML: loansHTML, referer: loansURL,
            checkboxValues: candidateCheckboxes
        )
        // The probe reports on the marked media; restrict to our candidate set defensively.
        let candidateSet = Set(candidateCheckboxes)
        let statuses = probe.rows.filter { candidateSet.contains($0.checkboxValue) }
        // Every marked row must carry a marker — otherwise the response isn't a probe page
        // (session error etc.) and the media's state is unknown; don't report "nothing renewed".
        guard statuses.count == candidateCheckboxes.count else {
            await logout(appURL: appURL, fromHTML: probe.html)
            throw VOEBBError.parseError(
                "Verlängerbarkeits-Prüfung nicht lesbar (\(statuses.count) von \(candidateCheckboxes.count) Medien erkannt)"
            )
        }
        let renewable = statuses.filter { $0.renewable }
        let blocked = statuses.filter { !$0.renewable }

        guard !renewable.isEmpty else {
            await logout(appURL: appURL, fromHTML: probe.html)
            return RenewalOutcome(renewed: [], blocked: blocked)
        }

        // Step 2: renew only the confirmed-renewable candidates ($Button$1).
        let resultHTML = try await pressButton(
            appURL: appURL, fromHTML: probe.html, referer: appURL,
            buttonField: "$Button$1", focusID: "$$GFBO_4",
            checkboxValues: renewable.map(\.checkboxValue)
        )

        // Report success per item from the moved due date on the result page — never infer it
        // from the probe alone.
        let verification = RenewalVerifier.verify(
            submitted: renewable,
            before: loans,
            after: HTMLParser.parseLoans(resultHTML)
        )

        await logout(appURL: appURL, fromHTML: resultHTML)
        return RenewalOutcome(
            renewed: verification.confirmed,
            blocked: blocked,
            unconfirmed: verification.unconfirmed,
            unverifiable: verification.unverifiable
        )
    }

    /// Presses "Markierte Medien verlängerbar?" ($Button$2, read-only) for the given
    /// checkboxes and parses the per-row renewability markers from the response.
    private func probeRenewability(
        appURL: String, fromHTML: String, referer: String,
        checkboxValues: [String]
    ) async throws -> (html: String, rows: [RenewabilityRow]) {
        let html = try await pressButton(
            appURL: appURL, fromHTML: fromHTML, referer: referer,
            buttonField: "$Button$2", focusID: "$$GFBO_7",
            checkboxValues: checkboxValues
        )
        return (html, HTMLParser.parseRenewability(html))
    }

    /// Presses a `$Button$N` submit button (renewal buttons, "Zur Übersicht") by re-POSTing the page's hidden fields plus the
    /// selected checkboxes. aDISWeb expects duplicate `$RTable_checkbox[]` keys, so the body is
    /// encoded manually (URLSession can't send duplicate keys via a dictionary).
    private func pressButton(
        appURL: String, fromHTML: String, referer: String,
        buttonField: String, focusID: String,
        checkboxValues: [String]
    ) async throws -> String {
        var postData = extractHiddenInputs(fromHTML)
        _ = try Self.requiredRequestCount(in: postData)
        postData["scriptEnabled"] = "true"
        postData["overrideScrollPos"] = "0"
        postData["focus"] = focusID
        postData["source"] = "$B"
        postData[buttonField] = "pressed"

        var parts: [String] = []
        for (k, v) in postData {
            parts.append("\(urlEncode(k))=\(urlEncode(v))")
        }
        for cbVal in checkboxValues {
            parts.append("$RTable_checkbox%5B%5D=\(urlEncode(cbVal))")
        }
        let body = parts.joined(separator: "&")

        return try await postRaw(url: appURL, body: body, referer: referer)
    }

    // MARK: - Private: Login

    private func login(password: String) async throws -> (appURL: String, overviewHTML: String) {
        // 1. Load main page to get session ID from form action
        let mainHTML = try await get(url: "\(baseURL)/aDISWeb/app/prod00?sp=SPROD00")
        guard let sessionMatch = mainHTML.range(of: #"/aDISWeb/(_[a-z0-9]+)/app"#, options: .regularExpression) else {
            throw VOEBBError.loginFailed("Session-ID nicht gefunden")
        }
        let sessionMatchStr = String(mainHTML[sessionMatch])
        guard let sessionIDRange = sessionMatchStr.range(of: #"_[a-z0-9]+"#, options: .regularExpression) else {
            throw VOEBBError.loginFailed("Session-ID nicht extrahierbar")
        }
        let sessionID = String(sessionMatchStr[sessionIDRange])
        let formActionURL = "\(baseURL)/aDISWeb/\(sessionID)/app"

        // 2. POST navigation to account section → triggers OIDC redirect
        var navData = extractHiddenInputs(mainHTML)
        navData["scriptEnabled"] = "true"
        navData["overrideScrollPos"] = "0"
        navData["selected"] = "ZTEXT       *SBK"
        navData["$Select"] = "Überall suchen"
        _ = try await post(url: formActionURL, data: navData, referer: "\(baseURL)/aDISWeb/app/prod00")

        // 3. POST credentials
        let loginData: [String: String] = [
            "L#AUSW": account.cardNumber,
            "LPASSW": password,
            "LLOGIN": "Login",
        ]
        let afterLoginHTML = try await post(
            url: "\(baseURL)/oidcp/logincheck",
            data: loginData,
            referer: "\(baseURL)/oidcp/authorize"
        )

        if afterLoginHTML.contains("schiefgegangen") || afterLoginHTML.contains("ausgeschalteten Cookies") {
            throw VOEBBError.loginFailed("Cookie-Problem. Bitte erneut versuchen.")
        }
        if afterLoginHTML.contains("Ungültig") || afterLoginHTML.contains("ungültig") ||
           afterLoginHTML.contains("nicht korrekt") {
            throw VOEBBError.loginFailed("Ausweisnummer oder Passwort falsch")
        }

        // Session-ID nach Login: aus der Form-Action, sonst aus der JS-Timeout-URL.
        let sessionSources = [
            (#"/aDISWeb/(_[a-z0-9]+)/app"#, #"_[a-z0-9]+"#),
            (#"/_[a-z0-9]+/timeout"#, #"_[a-z0-9]+"#),
        ]
        var newSessionID: String?
        for (outerPattern, innerPattern) in sessionSources {
            if let outerRange = afterLoginHTML.range(of: outerPattern, options: .regularExpression) {
                let outerStr = String(afterLoginHTML[outerRange])
                if let innerRange = outerStr.range(of: innerPattern, options: .regularExpression) {
                    newSessionID = String(outerStr[innerRange])
                    break
                }
            }
        }
        guard let sid = newSessionID else {
            throw VOEBBError.loginFailed("Session nach Login nicht gefunden")
        }
        let appURL = "\(baseURL)/aDISWeb/\(sid)/app"
        return (appURL, afterLoginHTML)
    }

    // MARK: - Private: Navigation

    // aDIS's request counter (`requestCount`) is a hidden field on every page and is echoed back
    // unchanged, like a browser does — never overwritten with fixed values: the sequence depends
    // on the session's history (a session that browsed before logging in starts at 5, not 3).

    /// aDIS expects the counter on every follow-up request. Without it the current page isn't a
    /// regular aDIS page (session expired, error page) — abort rather than send a broken request.
    static func requiredRequestCount(in hidden: [String: String]) throws -> String {
        guard let rc = hidden["requestCount"], Int(rc) != nil else {
            throw VOEBBError.parseError("Seite ohne gültigen Request-Zähler – Sitzung ungültig?")
        }
        return rc
    }

    private func navigate(appURL: String, fromHTML: String, navCode: String) async throws -> (html: String, url: String) {
        var data = extractHiddenInputs(fromHTML)
        _ = try Self.requiredRequestCount(in: data)
        data["scriptEnabled"] = "true"
        data["overrideScrollPos"] = "0"
        data["selected"] = "ZTEXT       \(navCode)"
        data["$Select"] = "Überall suchen"

        let html = try await post(url: appURL, data: data, referer: appURL)
        return (html, appURL)
    }

    // MARK: - Private: HTTP

    private func get(url: String) async throws -> String {
        try await ADISHTTP.get(url, session: session)
    }

    private func post(url: String, data: [String: String], referer: String) async throws -> String {
        let body = data.map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }.joined(separator: "&")
        return try await postRaw(url: url, body: body, referer: referer)
    }

    private func postRaw(url: String, body: String, referer: String) async throws -> String {
        try await ADISHTTP.postRaw(url, body: body, session: session, referer: referer)
    }

    // MARK: - Helpers (shared with CatalogEnricher via ADISForm)

    private func extractHiddenInputs(_ html: String) -> [String: String] { ADISForm.extractHiddenInputs(html) }

    private func urlEncode(_ string: String) -> String { ADISForm.urlEncode(string) }
}
