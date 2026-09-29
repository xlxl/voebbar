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

/// Per-account scraping session. Stateful and single-use: one instance per operation (refresh,
/// renewal), never shared between concurrent tasks.
final class VOEBBSession {
    private let baseURL = "https://www.voebb.de"
    private let session: URLSession
    private let account: LibraryAccount

    /// Session-bound form action every follow-up request posts to; set by `login`.
    private var appURL = ""
    /// The page loaded last. Every aDIS page carries a single-use identity token, so each request
    /// (the logout included) has to start from exactly this page — tracked here instead of being
    /// threaded through every call.
    private var currentPage = ""

    init(account: LibraryAccount) {
        self.account = account
        self.session = ADISHTTP.makeSession()
    }

    // MARK: - Public API

    /// Distinctive prefix for the parse-monitor errors so callers can tell "our scraping broke"
    /// apart from ordinary login/network failures (and notify about it).
    static let parseBrokenMarker = "Ausleihen nicht lesbar"

    func fetchAccountData(password: String, previousLoanCount: Int? = nil) async throws -> AccountData {
        try await withSession(password: password) { overviewHTML in
            var data = AccountData(account: account)

            // Everything account-level sits in the overview's <dt>/<dd> list — no *SGG navigation.
            // (Navigating *SGG from the probe result page is silently ignored by aDIS: it returns the
            // loans page again, and fees read as 0 € for accounts with loans AND fees.)
            Self.applyAccountInfo(fromOverview: overviewHTML, to: &data)

            // loanCount == 0  → definitiv keine Ausleihen
            // loanCount > 0   → Ausleihen vorhanden, Seite abrufen
            // loanCount == nil → Erkennung unsicher, Ausleihen trotzdem probieren
            let loanCount = HTMLParser.parseLoanCount(overviewHTML)
            if loanCount != 0 {
                let loansHTML = try await navigate("*SZA")
                var parsed = HTMLParser.parseLoans(loansHTML)

                // Parse-Monitor: a wrongly empty or short list would make the archive close open
                // loans as returned — history damage. So it throws instead (see validateLoans).
                try Self.validateLoans(parsed, expectedCount: loanCount,
                                       previousCount: previousLoanCount, pageHTML: loansHTML)

                // Verlängerbarkeit proben ("Markierte Medien verlängerbar?", lesend) und pro Buch
                // mergen. Fehlertolerant: ohne Probe bleiben die Felder einfach nil.
                if !parsed.isEmpty,
                   let rows = try? await probeRenewability(checkboxValues: parsed.map(\.checkboxValue).filter { !$0.isEmpty }) {
                    let byCheckbox = Dictionary(rows.map { ($0.checkboxValue, $0) }, uniquingKeysWith: { first, _ in first })
                    for i in parsed.indices {
                        if let s = byCheckbox[parsed[i].checkboxValue] {
                            parsed[i].isRenewable = s.renewable
                            parsed[i].renewalReason = s.reason
                        }
                    }
                }
                data.loans = parsed
            }

            data.pickups = await readPickups(expected: HTMLParser.parsePickupCount(overviewHTML), password: password)
            return data
        }
    }

    /// Pickups ("Bereitstellungen"), only when the overview announces some. aDIS silently ignores a
    /// list→list navigation (after *SZA, *SZS returns the loans again), so go back via the page's
    /// "Zur Übersicht" button first. Never press anything on the pickups page itself — it carries
    /// "Markierte Medien löschen". Fallback: a fresh session. nil = unknown (the archive then leaves
    /// this account's pickups untouched).
    private func readPickups(expected: Int?, password: String) async -> [PickupItem]? {
        guard let expected else { return nil }
        guard expected > 0 else { return [] }

        var pickups: [PickupItem]?
        if (try? await returnToOverview()) != nil,
           let html = try? await navigate("*SZS"), HTMLParser.isPickupsPage(html) {
            pickups = HTMLParser.parsePickups(html)
        }
        if pickups == nil {
            pickups = try? await VOEBBSession(account: account).fetchPickups(password: password)
        }
        // A short list would drop pickups from the archive snapshot — treat it as unknown.
        guard let pickups, pickups.count >= expected else { return nil }
        return pickups
    }

    /// Back to the account overview via the current page's "Zur Übersicht" button (looked up by
    /// label — its $Button$N differs per page). No-op if the current page already is the overview;
    /// throws if there's no such button or the response isn't the overview.
    private func returnToOverview() async throws {
        if HTMLParser.isOverviewPage(currentPage) { return }
        guard let button = HTMLParser.findSubmitButton(labelContaining: "Zur Übersicht", in: currentPage) else {
            throw VOEBBError.parseError("„Zur Übersicht“-Button nicht gefunden")
        }
        let html = try await pressButton(button, focusID: "", checkboxValues: [])
        guard HTMLParser.isOverviewPage(html) else {
            throw VOEBBError.parseError("Rücksprung lieferte keine Kontoübersicht")
        }
    }

    /// Fallback in a fresh session: login → pickups (*SZS) → logout.
    private func fetchPickups(password: String) async throws -> [PickupItem] {
        try await withSession(password: password) { _ in
            let html = try await navigate("*SZS")
            guard HTMLParser.isPickupsPage(html) else {
                throw VOEBBError.parseError("Bereitstellungs-Seite nicht erkannt")
            }
            return HTMLParser.parsePickups(html)
        }
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
        try await withSession(password: password) { overviewHTML in
            let loansHTML = try await navigate("*SZA")
            let loans = HTMLParser.parseLoans(loansHTML)
            // An unreadable loans page must not end as "Keine Ausleihen vorhanden".
            try Self.validateLoans(loans, expectedCount: HTMLParser.parseLoanCount(overviewHTML),
                                   previousCount: nil, pageHTML: loansHTML)
            guard !loans.isEmpty else { return RenewalOutcome(specialMessage: "Keine Ausleihen vorhanden") }

            // Only the selected candidates are probed/renewed — never touch the others.
            let candidateCheckboxes = loans.filter(select).map(\.checkboxValue).filter { !$0.isEmpty }
            guard !candidateCheckboxes.isEmpty else { return RenewalOutcome(specialMessage: noMatchMessage) }

            // Step 1: probe "verlängerbar?" ($Button$2) with only the candidates checked. The probe
            // reports on the marked media; restrict to our candidate set defensively.
            let candidateSet = Set(candidateCheckboxes)
            let statuses = try await probeRenewability(checkboxValues: candidateCheckboxes)
                .filter { candidateSet.contains($0.checkboxValue) }
            // Every marked row must carry a marker — otherwise the response isn't a probe page
            // (session error etc.) and the media's state is unknown; don't report "nothing renewed".
            guard statuses.count == candidateCheckboxes.count else {
                throw VOEBBError.parseError(
                    "Verlängerbarkeits-Prüfung nicht lesbar (\(statuses.count) von \(candidateCheckboxes.count) Medien erkannt)"
                )
            }
            let renewable = statuses.filter { $0.renewable }
            let blocked = statuses.filter { !$0.renewable }
            guard !renewable.isEmpty else { return RenewalOutcome(blocked: blocked) }

            // Step 2: renew only the confirmed-renewable candidates ($Button$1).
            let resultHTML = try await pressButton("$Button$1", focusID: "$$GFBO_4",
                                                   checkboxValues: renewable.map(\.checkboxValue))

            // Report success per item from the moved due date on the result page — never infer it
            // from the probe alone.
            let verification = RenewalVerifier.verify(
                submitted: renewable,
                before: loans,
                after: HTMLParser.parseLoans(resultHTML)
            )
            return RenewalOutcome(
                renewed: verification.confirmed,
                blocked: blocked,
                unconfirmed: verification.unconfirmed,
                unverifiable: verification.unverifiable
            )
        }
    }

    /// Presses "Markierte Medien verlängerbar?" ($Button$2, read-only) for the given
    /// checkboxes and parses the per-row renewability markers from the response.
    private func probeRenewability(checkboxValues: [String]) async throws -> [RenewabilityRow] {
        let html = try await pressButton("$Button$2", focusID: "$$GFBO_7", checkboxValues: checkboxValues)
        return HTMLParser.parseRenewability(html)
    }

    // MARK: - Private: Session lifecycle

    /// login → `body(overviewHTML)` → logout, the logout on success and on error alike: a parse
    /// error or a failed request mid-flow must not leave an orphaned session at VÖBB.
    private func withSession<T>(password: String, _ body: (String) async throws -> T) async throws -> T {
        let overviewHTML = try await login(password: password)
        do {
            let result = try await body(overviewHTML)
            await logout()
            return result
        } catch {
            await logout()
            throw error
        }
    }

    /// Ends the aDIS session server-side (nav code *SE) from the page loaded last. Best-effort:
    /// errors are ignored on purpose; it only avoids orphaned sessions at VÖBB.
    private func logout() async {
        _ = try? await navigate("*SE")
    }

    /// Returns the overview page (the landing page after login) and sets `appURL`/`currentPage`.
    private func login(password: String) async throws -> String {
        // 1. Load main page to get session ID from form action
        let mainHTML = try await ADISHTTP.get("\(baseURL)/aDISWeb/app/prod00?sp=SPROD00", session: session)
        guard let sessionID = ADISForm.sessionID(in: mainHTML) else {
            throw VOEBBError.loginFailed("Session-ID nicht gefunden")
        }

        // 2. POST navigation to account section → triggers OIDC redirect
        var navData = ADISForm.extractHiddenInputs(mainHTML)
        navData["scriptEnabled"] = "true"
        navData["overrideScrollPos"] = "0"
        navData["selected"] = "ZTEXT       *SBK"
        navData["$Select"] = "Überall suchen"
        _ = try await ADISHTTP.postRaw("\(baseURL)/aDISWeb/\(sessionID)/app", body: ADISForm.encode(navData),
                                       session: session, referer: "\(baseURL)/aDISWeb/app/prod00")

        // 3. POST credentials
        let loginData = [
            "L#AUSW": account.cardNumber,
            "LPASSW": password,
            "LLOGIN": "Login",
        ]
        let afterLoginHTML = try await ADISHTTP.postRaw("\(baseURL)/oidcp/logincheck", body: ADISForm.encode(loginData),
                                                        session: session, referer: "\(baseURL)/oidcp/authorize")

        if afterLoginHTML.contains("schiefgegangen") || afterLoginHTML.contains("ausgeschalteten Cookies") {
            throw VOEBBError.loginFailed("Cookie-Problem. Bitte erneut versuchen.")
        }
        if afterLoginHTML.contains("Ungültig") || afterLoginHTML.contains("ungültig") ||
           afterLoginHTML.contains("nicht korrekt") {
            throw VOEBBError.loginFailed("Ausweisnummer oder Passwort falsch")
        }

        // Session-ID nach Login: aus der Form-Action, sonst aus der JS-Timeout-URL.
        guard let sid = ADISForm.sessionID(in: afterLoginHTML) else {
            throw VOEBBError.loginFailed("Session nach Login nicht gefunden")
        }
        appURL = "\(baseURL)/aDISWeb/\(sid)/app"
        currentPage = afterLoginHTML
        return afterLoginHTML
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

    /// "Changes page" by re-POSTing the current page's form with a nav code (e.g. *SZA = loans).
    private func navigate(_ navCode: String) async throws -> String {
        var fields = try followUpFields()
        fields["selected"] = "ZTEXT       \(navCode)"
        fields["$Select"] = "Überall suchen"
        return try await post(ADISForm.encode(fields))
    }

    /// Presses a `$Button$N` submit button (renewal buttons, "Zur Übersicht") by re-POSTing the
    /// page's hidden fields plus the selected checkboxes. aDISWeb expects duplicate
    /// `$RTable_checkbox[]` keys, which a dictionary can't hold — so they're appended to the body.
    private func pressButton(_ buttonField: String, focusID: String, checkboxValues: [String]) async throws -> String {
        var fields = try followUpFields()
        fields["focus"] = focusID
        fields["source"] = "$B"
        fields[buttonField] = "pressed"
        let checkboxes = checkboxValues.map { "&$RTable_checkbox%5B%5D=\(ADISForm.urlEncode($0))" }.joined()
        return try await post(ADISForm.encode(fields) + checkboxes)
    }

    /// The current page's hidden fields (incl. its echoed `requestCount`) plus the fields every
    /// aDIS form submit carries.
    private func followUpFields() throws -> [String: String] {
        var fields = ADISForm.extractHiddenInputs(currentPage)
        _ = try Self.requiredRequestCount(in: fields)
        fields["scriptEnabled"] = "true"
        fields["overrideScrollPos"] = "0"
        return fields
    }

    private func post(_ body: String) async throws -> String {
        let html = try await ADISHTTP.postRaw(appURL, body: body, session: session, referer: appURL)
        currentPage = html
        return html
    }
}
