import AppKit

/// Lives on the main thread: the status item, the menu and the `isLoading`/`isEnriching`/`isRenewing`
/// flags are only touched there, which `@MainActor` now has the compiler check. The one piece of
/// real background work — scraping + archive write + enrichment in `refresh()` — runs in a detached
/// task and hops back via `MainActor.run`.
@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private var refreshTimer: Timer?
    var currentData: [AccountData] = []
    private var isLoading = false
    /// True while the background enrichment (catalog crawl + Tonie images) of a refresh is still
    /// running. Blocks a second refresh (timer / menuWillOpen / manual) from starting a parallel
    /// crawl of the same targets — `isLoading` alone drops too early for that.
    private var isEnriching = false
    /// True from the moment a renewal is triggered (including while its confirmation dialog is up)
    /// until its result was shown. Blocks a second renewal and any refresh in between — the timer
    /// or `menuWillOpen` must not log in again or replace the list mid-submit.
    private var isRenewing = false

    private static let maxTitleLength = 40

    /// True while the background enrichment counter is showing, so we only rebuild the menu / restore
    /// the button at the start/end of a run (not on every item).
    private var enrichmentActive = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupButton()
        updateButton()
        EnrichmentProgress.shared.onChange = { [weak self] in self?.updateEnrichmentUI() }
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: "VÖBB")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeft
    }

    func startRefreshing() {
        refresh()
        scheduleTimer()
    }

    /// Startet den automatischen Aktualisierungs-Timer neu, z.B. nachdem das Intervall
    /// in den Einstellungen geändert wurde.
    func refreshIntervalDidChange() {
        scheduleTimer()
    }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        let interval = AccountStorage.shared.refreshIntervalHours * 3600
        // A scheduled timer fires on the run loop it was added to — the main one here.
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval * 0.05
        refreshTimer = timer
    }

    // MARK: - Refresh

    func refresh() {
        guard !isLoading, !isEnriching, !isRenewing else { return }

        let accounts = AccountStorage.shared.accounts
        guard !accounts.isEmpty else {
            currentData = []
            updateButton()
            updateMenu()
            return
        }

        isLoading = true
        updateButtonForLoading()

        // Vorherige Ausleihzahlen (auf dem Main-Thread erfasst) für den Parse-Monitor.
        let previousCounts = Dictionary(uniqueKeysWithValues: currentData.map {
            ($0.account.cardNumber, $0.loans.count)
        })

        // Detached: the scraping, the synchronous SQLite write and the enrichment crawl must not
        // run on the main actor (a plain `Task` here would inherit it).
        Task.detached {
            var results: [AccountData] = []
            for account in accounts {
                guard let password = AccountStorage.shared.password(for: account) else {
                    var data = AccountData(account: account)
                    data.error = "Kein Passwort gespeichert"
                    results.append(data)
                    continue
                }
                do {
                    let voebbSession = VOEBBSession(account: account)
                    let data = try await voebbSession.fetchAccountData(
                        password: password,
                        previousLoanCount: previousCounts[account.cardNumber])
                    results.append(data)
                } catch {
                    var data = AccountData(account: account)
                    data.error = error.localizedDescription
                    results.append(data)
                }
            }

            let finalResults = results

            // Ausleihen ins persistente Archiv schreiben (nur erfolgreiche Konten),
            // noch im Hintergrund-Task – nicht auf dem Main-Thread.
            ArchiveStore.shared.record(finalResults)

            await MainActor.run {
                self.currentData = finalResults
                self.isLoading = false
                self.isEnriching = true
                self.updateButton()
                self.updateMenu()
                OverviewWindowController.shared.reload(with: finalResults)
                self.notifyDueSoonIfNeeded(finalResults)
                self.notifyParseFailures(finalResults)
            }

            // Anreicherung (ISBN/Cover aus dem VÖBB-Katalog) im Hintergrund, nachdem die UI
            // aktualisiert ist. Strikt inkrementell: crawlt nur noch nicht verarbeitete Medien
            // (+ ausstehende manuelle ISBN-Korrekturen). Nur für die Archiv-App relevant.
            await CatalogEnricher.shared.enrichMissing()

            // Tonie-Bilder aus my.tonies.com (nur wenn verbunden). Ein GraphQL-Call pro Refresh,
            // matcht neue Tonie-Ausleihen und lädt das Tonie-Bild in denselben Cover-Cache.
            await ToniesEnricher.shared.enrichMissing()

            EnrichmentProgress.shared.stop()
            await MainActor.run { self.isEnriching = false }
        }
    }

    // MARK: - Renewal

    func renewAll(for accountData: AccountData) {
        performRenewal(
            for: accountData.account,
            confirmTitle: "Alle verlängern?",
            confirmMessage: confirmationMessage(
                lead: "Für »\(accountData.account.name)« \(loanPhrase(accountData.loans.count)) zur Verlängerung eingereicht.",
                loans: accountData.loans),
            resultTitle: accountData.account.name
        ) { session, password in
            try await session.renewAllLoans(password: password)
        }
    }

    /// Verlängert für ein Konto nur die demnächst fälligen Bücher (und nur die).
    func renewDueSoon(for accountData: AccountData) {
        let days = AccountStorage.shared.renewalDueDays
        let due = accountData.loans.filter { $0.daysUntilDue <= days }
        performRenewal(
            for: accountData.account,
            confirmTitle: "Fällige verlängern?",
            confirmMessage: confirmationMessage(
                lead: "Für »\(accountData.account.name)« \(loanPhrase(due.count)) mit Fälligkeit in ≤ \(days) Tagen zur Verlängerung eingereicht.",
                loans: due),
            resultTitle: "\(accountData.account.name) – fällige verlängern"
        ) { session, password in
            try await session.renewDueLoans(password: password, withinDays: days)
        }
    }

    /// Renews exactly the given loans (from the overview window's selection), which may span
    /// several accounts — one session per account, sequentially, results merged into one message.
    /// Loans are addressed by `Loan.renewalKey`, not by the session-local checkbox value.
    func renewSelected(_ selection: [(account: LibraryAccount, loan: Loan)], anchor: NSWindow?) {
        guard !selection.isEmpty else { return }

        let accountOf = Dictionary(selection.map { ($0.loan.renewalKey, $0.account.name) },
                                  uniquingKeysWith: { first, _ in first })
        let multipleAccounts = Set(selection.map(\.account.cardNumber)).count > 1
        let loans = selection.map(\.loan)
        let message = confirmationMessage(
            lead: "Es \(loanPhrase(loans.count)) zur Verlängerung eingereicht.",
            loans: loans,
            line: multipleAccounts
                ? { "• \(self.truncate($0.title, to: 40)) – \(accountOf[$0.renewalKey] ?? "") (bis \($0.dueDateString))" }
                : nil)

        // Gruppiert nach Konto: pro Konto ein Login, alle Schlüssel dieses Kontos in einem Durchlauf.
        let grouped = Dictionary(grouping: selection, by: { $0.account.cardNumber })
        guard beginRenewal() else { return }

        Task { @MainActor in
            guard await Alerts.confirm(
                title: loans.count == 1 ? "Medium verlängern?" : "\(loans.count) Medien verlängern?",
                message: message, confirmTitle: "Verlängern", window: anchor)
            else {
                self.endRenewal()
                return
            }
            self.updateButtonForLoading()

            var blocks: [String] = []
            for (_, entries) in grouped.sorted(by: { $0.value[0].account.name < $1.value[0].account.name }) {
                let account = entries[0].account
                let keys = Set(entries.map(\.loan.renewalKey))
                let body: String
                if let password = AccountStorage.shared.password(for: account) {
                    do {
                        body = try await VOEBBSession(account: account)
                            .renewLoans(password: password, keys: keys).userMessage
                    } catch {
                        // Ein defektes Konto darf die anderen nicht abbrechen.
                        body = "⚠️ \(error.localizedDescription)"
                    }
                } else {
                    body = "⚠️ Kein Passwort gespeichert"
                }
                blocks.append(grouped.count > 1 ? "\(account.name):\n\(body)" : body)
            }

            self.endRenewal()
            await Alerts.info(title: loans.count == 1 ? "Verlängerung" : "Verlängerung der Auswahl",
                              message: blocks.joined(separator: "\n\n"), window: anchor)
            // Erst den Button zurücksetzen: läuft z.B. gerade eine Anreicherung, steigt `refresh()`
            // sofort wieder aus und die Ladeanzeige würde hängen bleiben.
            self.updateButton()
            self.refresh()
        }
    }

    private func performRenewal(
        for account: LibraryAccount,
        confirmTitle: String,
        confirmMessage: String,
        resultTitle: String,
        anchor: NSWindow? = nil,
        _ run: @escaping (VOEBBSession, String) async throws -> RenewalOutcome
    ) {
        guard let password = AccountStorage.shared.password(for: account) else {
            Task { @MainActor in
                await Alerts.info(title: "Kein Passwort gespeichert",
                                  message: "Für »\(account.name)« liegt kein Passwort im Schlüsselbund.",
                                  window: anchor)
            }
            return
        }
        guard beginRenewal() else { return }

        Task { @MainActor in
            guard await Alerts.confirm(title: confirmTitle, message: confirmMessage,
                                       confirmTitle: "Verlängern", window: anchor)
            else {
                self.endRenewal()
                return
            }
            self.updateButtonForLoading()
            let session = VOEBBSession(account: account)
            do {
                let outcome = try await run(session, password)
                self.endRenewal()
                await Alerts.info(title: resultTitle, message: outcome.userMessage, window: anchor)
                self.updateButton()   // s. renewSelected: refresh() kann sofort aussteigen
                self.refresh()
            } catch {
                self.endRenewal()
                self.updateButton()
                await Alerts.info(title: "Fehler beim Verlängern",
                                  message: error.localizedDescription, window: anchor)
            }
        }
    }

    /// Claims the renewal slot (see `isRenewing`); false means one is already in flight.
    private func beginRenewal() -> Bool {
        guard !isRenewing, !isLoading else { return false }
        isRenewing = true
        return true
    }

    private func endRenewal() { isRenewing = false }

    private static let confirmListLimit = 8

    /// Body of a renewal confirmation: which items would be submitted (capped, one per line) plus
    /// what the last renewability probe said about them — blocked items are skipped by the
    /// two-step flow, so the dialog says so instead of letting the result surprise the user.
    private func confirmationMessage(lead: String, loans: [Loan], line: ((Loan) -> String)? = nil) -> String {
        var lines = [lead, ""]
        let format = line ?? { "• \(self.truncate($0.title, to: 48)) (bis \($0.dueDateString))" }
        lines += loans.prefix(Self.confirmListLimit).map(format)
        if loans.count > Self.confirmListLimit {
            lines.append("… und \(loans.count - Self.confirmListLimit) weitere")
        }

        let blocked = loans.filter { $0.isRenewable == false }.count
        if blocked > 0 {
            lines.append("")
            lines.append(blocked == 1
                ? "1 davon war bei der letzten Prüfung nicht verlängerbar und wird übersprungen."
                : "\(blocked) davon waren bei der letzten Prüfung nicht verlängerbar und werden übersprungen.")
        }
        return lines.joined(separator: "\n")
    }

    /// „wird 1 Ausleihe" / „werden 5 Ausleihen" — passendes Verb zur Anzahl.
    private func loanPhrase(_ count: Int) -> String {
        count == 1 ? "wird 1 Ausleihe" : "werden \(count) Ausleihen"
    }

    // MARK: - Button State

    func updateButton() {
        guard let button = statusItem.button else { return }

        let totalLoans = currentData.reduce(0) { $0 + $1.loans.count }
        let minDays    = currentData.compactMap(\.daysUntilNextDue).min()
        let hasUrgent  = minDays.map { $0 < Urgency.urgentDays } ?? false
        let hasError   = currentData.contains { $0.error != nil }

        // Icon: Bücherstapel; bei Dringlichkeit gefüllt
        let imageName = (hasUrgent || hasError) ? "books.vertical.fill" : "books.vertical"
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "VÖBB")
        button.image?.isTemplate = true

        // Zahl neben Symbol
        if totalLoans > 0 {
            button.title = " \(totalLoans)"
        } else {
            button.title = ""
        }

        // Tooltip mit kompaktem Status
        if let days = minDays, days < Urgency.urgentDays {
            button.toolTip = "⚠️ Nächste Rückgabe in \(days) Tag\(days == 1 ? "" : "en")"
        } else {
            button.toolTip = "VÖBB Bibliotheksausleihen"
        }
    }

    private func updateButtonForLoading() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Lädt…")
        button.image?.isTemplate = true
        button.title = ""
    }

    /// Reflects background-enrichment progress on the status item: a live "k/N" counter in the
    /// button while crawling, then restores the normal loan display. The menu is only rebuilt at the
    /// start/end of a run (the button carries the live count).
    func updateEnrichmentUI() {
        let p = EnrichmentProgress.shared
        if p.active {
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Reichere an …")
                button.image?.isTemplate = true
                button.title = " \(p.done)/\(p.total)"
                button.toolTip = "Reichere \(p.phase) an … (\(p.done)/\(p.total))"
            }
            if !enrichmentActive { enrichmentActive = true; updateMenu() }
        } else if enrichmentActive {
            enrichmentActive = false
            if !isLoading { updateButton() }
            updateMenu()
        }
    }

    // MARK: - Notifications (due soon / overdue)

    private static let notifiedKey = "voebb_notified_v1"

    /// One aggregated notification per refresh when loans are due soon or overdue — but only if
    /// at least one of them wasn't announced before. Dedupe keys are `mediaNumber|dueDate`, so a
    /// renewal (new due date) re-arms the item; the stored set is pruned to the current loans.
    private func notifyDueSoonIfNeeded(_ results: [AccountData]) {
        guard AccountStorage.shared.notificationsEnabled else { return }
        let threshold = AccountStorage.shared.renewalDueDays

        let due = results.filter { $0.error == nil }
            .flatMap(\.loans)
            .filter { $0.isOverdue || $0.daysUntilDue <= threshold }
            .sorted { $0.dueDate < $1.dueDate }
        // renewalKey, not mediaNumber: items without a barcode would all share "|<date>".
        let keys = Set(due.map { "\($0.renewalKey)|\($0.dueDateString)" })

        let defaults = UserDefaults.standard
        let previous = Set(defaults.stringArray(forKey: Self.notifiedKey) ?? [])
        defaults.set(Array(keys), forKey: Self.notifiedKey)   // prune + remember current state
        guard !due.isEmpty, !keys.subtracting(previous).isEmpty else { return }

        let overdue = due.filter(\.isOverdue).count
        let soon = due.count - overdue
        var titleParts: [String] = []
        if overdue > 0 { titleParts.append("⚠️ \(overdue) überfällig") }
        if soon > 0 { titleParts.append("\(soon) bald fällig") }
        let title = titleParts.joined(separator: " · ")

        var lines = due.prefix(4).map { "• \(truncate($0.title, to: 40)) (bis \($0.dueDateString))" }
        if due.count > 4 { lines.append("… und \(due.count - 4) weitere") }
        NotificationManager.shared.notify(title: title, body: lines.joined(separator: "\n"))
    }

    /// Loud alert when the loans page stopped being parseable (VÖBB markup change) — the account
    /// shows the ⚠️ in the menu anyway, but a notification is noticed without opening it.
    /// At most one notification per account and day.
    private func notifyParseFailures(_ results: [AccountData]) {
        let broken = results.filter { $0.error?.contains(VOEBBSession.parseBrokenMarker) == true }
        guard !broken.isEmpty else { return }

        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let keys = Set(broken.map { "\($0.account.cardNumber)|\(day)" })
        let defaults = UserDefaults.standard
        let notified = Set(defaults.stringArray(forKey: "voebb_parsefail_notified") ?? [])
        guard !keys.subtracting(notified).isEmpty else { return }
        defaults.set(Array(keys), forKey: "voebb_parsefail_notified")

        NotificationManager.shared.notify(
            title: "⚠️ VÖBB-Abruf defekt?",
            body: "Die Ausleihen-Seite konnte nicht gelesen werden (Markup geändert?). Das Archiv bleibt unangetastet — bitte prüfen.")
    }

    // MARK: - Menu

    func updateMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let accounts = AccountStorage.shared.accounts

        if accounts.isEmpty {
            add(to: menu, title: "Keine Konten konfiguriert", enabled: false)
        } else if isLoading {
            add(to: menu, title: "Lade Daten …", enabled: false)
        } else {
            for (i, data) in currentData.enumerated() {
                if i > 0 { menu.addItem(.separator()) }
                addAccountSection(to: menu, data: data)
            }
        }

        menu.addItem(.separator())

        // Übersicht
        let overviewItem = NSMenuItem(title: "Alle Ausleihen anzeigen …", action: #selector(onOverview), keyEquivalent: "o")
        overviewItem.target = self
        menu.addItem(overviewItem)

        // Archiv (zeigt vorerst die DB-Datei im Finder)
        let archiveItem = NSMenuItem(title: "Archiv anzeigen …", action: #selector(onShowArchive), keyEquivalent: "")
        archiveItem.target = self
        menu.addItem(archiveItem)

        // Tonie-Bilder (my.tonies.com) — Verbindung verwalten
        addToniesSection(to: menu)

        // Aktualisieren — während der Anreicherung stattdessen den Fortschritt zeigen (deaktiviert,
        // damit man nicht erneut klickt).
        let enriching = EnrichmentProgress.shared.active
        let refreshItem = NSMenuItem(
            title: enriching ? "Reichere \(EnrichmentProgress.shared.phase) an …" : buildRefreshTitle(),
            action: enriching ? nil : #selector(onRefresh),
            keyEquivalent: enriching ? "" : "r")
        refreshItem.target = self
        refreshItem.isEnabled = !enriching
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Einstellungen …", action: #selector(onSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        menu.delegate = self
    }

    // MARK: - Tonies Section

    private func addToniesSection(to menu: NSMenu) {
        let connected = ToniesAuth.isConnected
        let parent = NSMenuItem(title: "Tonie-Bilder", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        add(to: submenu, title: connected ? "  ✓  Verbunden" : "  –  Nicht verbunden", enabled: false)

        let connectItem = NSMenuItem(title: connected ? "Neu verbinden …" : "Mit tonies verbinden …",
                                     action: #selector(onToniesConnect), keyEquivalent: "")
        connectItem.target = self
        submenu.addItem(connectItem)

        if connected {
            let disconnectItem = NSMenuItem(title: "Verbindung trennen", action: #selector(onToniesDisconnect), keyEquivalent: "")
            disconnectItem.target = self
            submenu.addItem(disconnectItem)
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    // MARK: - Account Section

    private func addAccountSection(to menu: NSMenu, data: AccountData) {
        // Konto-Überschrift (fett)
        let headerItem = NSMenuItem(title: data.account.name, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        headerItem.attributedTitle = NSAttributedString(
            string: data.account.name,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(headerItem)

        if let error = data.error {
            add(to: menu, title: "  ⚠️  \(truncate(error, to: 50))", enabled: false)
            return
        }

        // Ausleihen-Zeile
        if data.loans.isEmpty {
            add(to: menu, title: "  📗  Keine Ausleihen", enabled: false)
        } else {
            let urgencyEmoji = urgencyBadge(for: data)
            let loanItem = add(to: menu,
                               title: "  \(urgencyEmoji)  \(data.loans.count) Ausleihe\(data.loans.count == 1 ? "" : "n")",
                               enabled: false)
            if let days = data.daysUntilNextDue {
                loanItem.toolTip = "Nächste Rückgabe: \(data.nextDueDateString ?? "") (\(days) Tag\(days == 1 ? "" : "e"))"
            }

            if let nextDate = data.nextDueDateString {
                add(to: menu, title: "  📅  Nächste Rückgabe: \(nextDate)", enabled: false)
            }
        }

        // Gebühren
        if data.fees > 0 {
            add(to: menu, title: String(format: "  💶  %.2f € Gebühren", data.fees), enabled: false)
        } else {
            add(to: menu, title: "  ✅  Keine Gebühren", enabled: false)
        }

        // Verlängern-Buttons
        if !data.loans.isEmpty {
            let days = AccountStorage.shared.renewalDueDays
            if data.loans.contains(where: { $0.daysUntilDue <= days }) {
                let dueItem = NSMenuItem(title: "  ↺  Fällige verlängern (≤ \(days) Tage)", action: #selector(onRenewDue(_:)), keyEquivalent: "")
                dueItem.target = self
                dueItem.representedObject = data.account.cardNumber
                menu.addItem(dueItem)
            }

            let renewItem = NSMenuItem(title: "  ↺  Alle verlängern", action: #selector(onRenew(_:)), keyEquivalent: "")
            renewItem.target = self
            renewItem.representedObject = data.account.cardNumber
            menu.addItem(renewItem)
        }

        // Bücherlist als Untermenü
        if !data.loans.isEmpty {
            let subItem = NSMenuItem(title: "  📖  Ausgeliehene Medien", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for loan in data.loans.sorted(by: { $0.dueDate < $1.dueDate }) {
                let short = truncate(loan.title, to: Self.maxTitleLength)
                let menuItem = NSMenuItem(title: "\(loan.bookEmoji)  \(short)", action: nil, keyEquivalent: "")
                menuItem.toolTip = "\(loan.title)\n📅 Fällig: \(loan.dueDateString)\n🏛 \(LibraryName.short(loan.library))"
                menuItem.isEnabled = false
                submenu.addItem(menuItem)
            }
            subItem.submenu = submenu
            menu.addItem(subItem)
        }

        // Aufschlüsselung nach Bibliothek — damit man vor der Abgabe weiß, wie viele Medien
        // pro Standort herauszusuchen sind. Bezirks-Präfix weggekürzt (LibraryName.short).
        if !data.loans.isEmpty {
            let byLibrary = Dictionary(grouping: data.loans, by: { LibraryName.short($0.library) })
                .map { (library: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.library < $1.library }

            let libItem = NSMenuItem(title: "  📍  Nach Bibliothek", action: nil, keyEquivalent: "")
            let libMenu = NSMenu()
            for entry in byLibrary {
                let name = entry.library.isEmpty ? "Unbekannte Bibliothek" : entry.library
                let row = NSMenuItem(title: "\(name): \(entry.count)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                libMenu.addItem(row)
            }
            libItem.submenu = libMenu
            menu.addItem(libItem)
        }
    }

    // MARK: - Helpers

    /// Dringlichkeits-Emoji für eine Account-Zusammenfassung
    private func urgencyBadge(for data: AccountData) -> String {
        guard let days = data.daysUntilNextDue else { return "📗" }
        if days < Urgency.urgentDays { return "📕" }
        if days <= Urgency.soonDays { return "📙" }
        return "📗"
    }

    private func truncate(_ s: String, to length: Int) -> String {
        guard s.count > length else { return s }
        return String(s.prefix(length - 1)) + "…"
    }

    @discardableResult
    private func add(to menu: NSMenu, title: String, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    private func buildRefreshTitle() -> String {
        var title = "Aktualisieren"
        if let updated = currentData.first?.lastUpdated {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "de_DE")
            formatter.unitsStyle = .short
            let ago = formatter.localizedString(for: updated, relativeTo: Date())
            title = "Aktualisieren (zuletzt \(ago))"
        }
        // Kurzlebige Spur eines (evtl. im Hintergrund gelaufenen) Anreicherungslaufs.
        let p = EnrichmentProgress.shared
        if let at = p.lastRunAt, Date().timeIntervalSince(at) < 600, p.lastRunCount > 0 {
            title += " · \(p.lastRunCount) neu angereichert"
        }
        return title
    }

    // MARK: - Actions

    @objc private func onRefresh() { refresh() }

    @objc private func onSettings() {
        PreferencesWindowController.shared.showWindow()
    }

    @objc private func onOverview() {
        OverviewWindowController.shared.showWindow(with: currentData)
    }

    @objc private func onToniesConnect() {
        ToniesLoginWindowController.shared.present { [weak self] success in
            self?.updateMenu()
            // Direkt nach dem Verbinden anreichern, damit Tonie-Bilder sofort geladen werden.
            if success { self?.refresh() }
        }
    }

    @objc private func onToniesDisconnect() {
        ToniesAuth.disconnect()
        updateMenu()
    }

    @objc private func onShowArchive() {
        let url = ArchiveStore.databaseURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Noch nichts geschrieben (z.B. vor dem ersten Refresh) → Ordner zeigen.
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    @objc private func onRenew(_ sender: NSMenuItem) {
        guard let cardNumber = sender.representedObject as? String,
              let data = currentData.first(where: { $0.account.cardNumber == cardNumber })
        else { return }
        renewAll(for: data)
    }

    @objc private func onRenewDue(_ sender: NSMenuItem) {
        guard let cardNumber = sender.representedObject as? String,
              let data = currentData.first(where: { $0.account.cardNumber == cardNumber })
        else { return }
        renewDueSoon(for: data)
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Aktualisieren wenn Daten älter als das eingestellte Intervall
        if let lastUpdate = currentData.first?.lastUpdated,
           Date().timeIntervalSince(lastUpdate) > AccountStorage.shared.refreshIntervalHours * 3600 {
            refresh()
        }
    }
}
