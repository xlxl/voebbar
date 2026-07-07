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
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Distinctive prefix for the parse-monitor errors so callers can tell "our scraping broke"
    /// apart from ordinary login/network failures (and notify about it).
    static let parseBrokenMarker = "Ausleihen nicht lesbar"

    func fetchAccountData(password: String, previousLoanCount: Int? = nil) async throws -> AccountData {
        let (appURL, overviewHTML) = try await login(password: password)
        var data = AccountData(account: account)

        let loanCount = HTMLParser.parseLoanCount(overviewHTML)

        // loanCount == 0  → definitiv keine Ausleihen, direkt zu Gebühren
        // loanCount > 0   → Ausleihen vorhanden, Seite abrufen
        // loanCount == nil → Erkennung unsicher, Ausleihen trotzdem probieren
        if loanCount != 0 {
            let (loansHTML, loansURL) = try await navigate(appURL: appURL, fromHTML: overviewHTML, navCode: "*SZA", rc: 3)
            var parsed = HTMLParser.parseLoans(loansHTML)

            // Parse-Monitor: käme hier fälschlich eine leere Liste durch, würde das Archiv ALLE
            // offenen Ausleihen als zurückgegeben schließen — Historienschaden. Zwei Fälle:
            // (a) Übersicht sagt N > 0, aber die Ausleihen-Tabelle ist unparsebar → Markup-Bruch.
            // (b) Übersicht selbst unlesbar (nil) UND vorher gab es Ausleihen → konservativ
            //     ebenfalls Fehler (echte Komplett-Rückgabe läuft über loanCount == 0).
            if parsed.isEmpty {
                if let n = loanCount, n > 0 {
                    throw VOEBBError.parseError("\(Self.parseBrokenMarker) (Übersicht meldet \(n)) – VÖBB-Markup geändert? Archiv bleibt unangetastet.")
                }
                if loanCount == nil, let prev = previousLoanCount, prev > 0 {
                    throw VOEBBError.parseError("\(Self.parseBrokenMarker) (vorher \(prev), Übersicht unlesbar) – VÖBB-Markup geändert? Archiv bleibt unangetastet.")
                }
            }

            // Gebühren: von der Ausleihseite aus (rc=4) falls Bücher gefunden,
            // sonst von der Übersicht (rc=3) – Fallback falls *SZA kein loans-HTML lieferte
            if !parsed.isEmpty {
                // Verlängerbarkeit proben ("Markierte Medien verlängerbar?", lesend) und
                // pro Buch mergen. Fehlertolerant: ohne Probe bleiben die Felder einfach nil.
                var feesSourceHTML = loansHTML
                var feesRC = 4
                do {
                    let probe = try await probeRenewability(
                        appURL: appURL, fromHTML: loansHTML, referer: loansURL, requestCount: 4,
                        checkboxValues: parsed.map(\.checkboxValue).filter { !$0.isEmpty }
                    )
                    if !probe.rows.isEmpty {
                        let byCheckbox = Dictionary(probe.rows.map { ($0.checkboxValue, $0) },
                                                    uniquingKeysWith: { first, _ in first })
                        for i in parsed.indices {
                            if let s = byCheckbox[parsed[i].checkboxValue] {
                                parsed[i].isRenewable = s.renewable
                                parsed[i].renewalReason = s.reason
                            }
                        }
                        feesSourceHTML = probe.html
                        feesRC = 5
                    }
                } catch {
                    // Probe fehlgeschlagen → Ausleihen ohne Verlängerbarkeits-Info anzeigen
                }
                data.loans = parsed

                let (feesHTML, _) = try await navigate(appURL: appURL, fromHTML: feesSourceHTML, navCode: "*SGG", rc: feesRC)
                let (fees, cardValid) = HTMLParser.parseFees(feesHTML)
                data.fees = fees
                data.cardValidUntil = cardValid
            } else {
                let (feesHTML, _) = try await navigate(appURL: appURL, fromHTML: overviewHTML, navCode: "*SGG", rc: 3)
                let (fees, cardValid) = HTMLParser.parseFees(feesHTML)
                data.fees = fees
                data.cardValidUntil = cardValid
            }
        } else {
            // Keine Ausleihen laut Übersicht → direkt Gebühren
            let (feesHTML, _) = try await navigate(appURL: appURL, fromHTML: overviewHTML, navCode: "*SGG", rc: 3)
            let (fees, cardValid) = HTMLParser.parseFees(feesHTML)
            data.fees = fees
            data.cardValidUntil = cardValid
        }

        data.lastUpdated = Date()
        return data
    }

    /// Renews all renewable loans.
    func renewAllLoans(password: String) async throws -> RenewalOutcome {
        try await renewLoans(password: password) { _ in true }
    }

    /// Renews only loans due within `days` days (overdue included), and only those.
    func renewDueLoans(password: String, withinDays days: Int) async throws -> RenewalOutcome {
        try await renewLoans(password: password) { $0.daysUntilDue <= days }
    }

    /// Renewal is a two-step flow because BOTH "Alle verlängern" and "Markierte Medien
    /// verlängern" abort the entire batch if a single selected item is blocked (e.g. by a
    /// Vormerkung). So we first probe renewability ("Markierte Medien verlängerbar?",
    /// $Button$2) on the selected candidates, then submit only the confirmed-renewable ones
    /// ("Markierte Medien verlängern", $Button$1). See memory `voebb-renewal-button-mapping`.
    /// `select` narrows which loans are considered (e.g. only soon-due ones).
    private func renewLoans(password: String, selecting select: (Loan) -> Bool) async throws -> RenewalOutcome {
        let (appURL, overviewHTML) = try await login(password: password)

        let (loansHTML, loansURL) = try await navigate(appURL: appURL, fromHTML: overviewHTML, navCode: "*SZA", rc: 3)
        let loans = HTMLParser.parseLoans(loansHTML)

        guard !loans.isEmpty else {
            return RenewalOutcome(specialMessage: "Keine Ausleihen vorhanden")
        }

        // Only the selected candidates are probed/renewed — never touch the others.
        let candidateCheckboxes = loans.filter(select).map(\.checkboxValue).filter { !$0.isEmpty }
        guard !candidateCheckboxes.isEmpty else {
            return RenewalOutcome()
        }

        // Step 1: probe "verlängerbar?" ($Button$2) with only the candidates checked.
        let probe = try await probeRenewability(
            appURL: appURL, fromHTML: loansHTML, referer: loansURL, requestCount: 4,
            checkboxValues: candidateCheckboxes
        )
        // The probe reports on the marked media; restrict to our candidate set defensively.
        let candidateSet = Set(candidateCheckboxes)
        let statuses = probe.rows.filter { candidateSet.contains($0.checkboxValue) }
        let renewable = statuses.filter { $0.renewable }
        let blocked = statuses.filter { !$0.renewable }

        guard !renewable.isEmpty else {
            return RenewalOutcome(renewed: [], blocked: blocked)
        }

        // Step 2: renew only the confirmed-renewable candidates ($Button$1).
        let resultHTML = try await pressRenewalButton(
            appURL: appURL, fromHTML: probe.html, referer: appURL,
            buttonField: "$Button$1", focusID: "$$GFBO_4", requestCount: 5,
            checkboxValues: renewable.map(\.checkboxValue)
        )

        var outcome = RenewalOutcome(renewed: renewable, blocked: blocked)

        // Sanity check: if the response renders the loans table again and its due dates are
        // completely unchanged, the submit likely didn't take effect — warn instead of
        // claiming success. (If the response isn't a loans table, we can't verify; stay quiet.)
        let afterLoans = HTMLParser.parseLoans(resultHTML)
        if !afterLoans.isEmpty,
           afterLoans.map(\.dueDateString).sorted() == loans.map(\.dueDateString).sorted() {
            outcome.verificationNote = "Verlängerung konnte nicht bestätigt werden – die Fälligkeitsdaten sind unverändert. Bitte Liste prüfen."
        }

        return outcome
    }

    /// Presses "Markierte Medien verlängerbar?" ($Button$2, read-only) for the given
    /// checkboxes and parses the per-row renewability markers from the response.
    private func probeRenewability(
        appURL: String, fromHTML: String, referer: String, requestCount: Int,
        checkboxValues: [String]
    ) async throws -> (html: String, rows: [RenewabilityRow]) {
        let html = try await pressRenewalButton(
            appURL: appURL, fromHTML: fromHTML, referer: referer,
            buttonField: "$Button$2", focusID: "$$GFBO_7", requestCount: requestCount,
            checkboxValues: checkboxValues
        )
        return (html, HTMLParser.parseRenewability(html))
    }

    /// Presses one of the renewal-page buttons by re-POSTing the page's hidden fields plus the
    /// selected checkboxes. aDISWeb expects duplicate `$RTable_checkbox[]` keys, so the body is
    /// encoded manually (URLSession can't send duplicate keys via a dictionary).
    private func pressRenewalButton(
        appURL: String, fromHTML: String, referer: String,
        buttonField: String, focusID: String, requestCount: Int,
        checkboxValues: [String]
    ) async throws -> String {
        var postData = extractHiddenInputs(fromHTML)
        postData["requestCount"] = "\(requestCount)"
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

        // Extract new session ID from current URL (stored in response header tracking)
        // Parse from the HTML's form action or JS
        // Extract session ID: look in form action or JS timeout URL
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

    private func navigate(appURL: String, fromHTML: String, navCode: String, rc: Int) async throws -> (html: String, url: String) {
        var data = extractHiddenInputs(fromHTML)
        data["scriptEnabled"] = "true"
        data["overrideScrollPos"] = "0"
        data["requestCount"] = "\(rc)"
        data["selected"] = "ZTEXT       \(navCode)"
        data["$Select"] = "Überall suchen"

        let html = try await post(url: appURL, data: data, referer: appURL)
        return (html, appURL)
    }

    // MARK: - Private: HTTP

    private func get(url: String) async throws -> String {
        var req = URLRequest(url: URL(string: url)!)
        req.addValue(ADISForm.userAgent, forHTTPHeaderField: "User-Agent")
        req.addValue("de-DE,de;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.addValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        try Self.checkHTTP(response)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Error pages (5xx/4xx) would otherwise be silently "parsed" as empty results.
    static func checkHTTP(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw VOEBBError.networkError("HTTP \(http.statusCode)")
        }
    }

    private func post(url: String, data: [String: String], referer: String) async throws -> String {
        let body = data.map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }.joined(separator: "&")
        return try await postRaw(url: url, body: body, referer: referer)
    }

    private func postRaw(url: String, body: String, referer: String) async throws -> String {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.addValue(ADISForm.userAgent, forHTTPHeaderField: "User-Agent")
        req.addValue("de-DE,de;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.addValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if !referer.isEmpty {
            req.addValue(referer, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await session.data(for: req)
        try Self.checkHTTP(response)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Helpers (shared with CatalogEnricher via ADISForm)

    private func extractHiddenInputs(_ html: String) -> [String: String] { ADISForm.extractHiddenInputs(html) }

    private func urlEncode(_ string: String) -> String { ADISForm.urlEncode(string) }
}
