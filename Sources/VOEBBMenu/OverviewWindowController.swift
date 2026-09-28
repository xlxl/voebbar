import AppKit

@MainActor
final class OverviewWindowController: NSObject, NSWindowDelegate {
    static let shared = OverviewWindowController()

    private var window: NSWindow?
    private var tableView: NSTableView?
    /// The account is kept whole (not just its name): a renewal from here needs the card number to
    /// look up the password and open a session for exactly that account.
    private var allLoans: [(account: LibraryAccount, loan: Loan)] = []
    private var sortOrder: NSSortDescriptor?
    private var renewButton: NSButton?

    private var statusBar: StatusBarController? {
        (NSApp.delegate as? AppDelegate)?.statusBarController
    }

    // MARK: - Public API

    func showWindow(with data: [AccountData]) {
        buildWindowIfNeeded()
        reload(with: data)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload(with data: [AccountData]) {
        let selected = selectedLoanIDs()
        allLoans = data.flatMap { accountData in
            accountData.loans.map { (account: accountData.account, loan: $0) }
        }
        .sorted { $0.loan.dueDate < $1.loan.dueDate }

        tableView?.reloadData()
        restoreSelection(selected)
        updateSummaryLabel()
        updateRenewButton()
    }

    // MARK: - Build Window

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        // Wide enough that the renewal reason and the library are readable without resizing;
        // clamped to the screen. After that the user's own size/position wins (autosave).
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: min(1080, visible.width - 40), height: min(600, visible.height - 40)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "VÖBB – Alle Ausleihen"
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 500, height: 300)
        win.setFrameAutosaveName("VOEBBOverviewWindow")

        let cv = NSView()
        cv.translatesAutoresizingMaskIntoConstraints = false

        // ── Toolbar area ──────────────────────────────────────────
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = label("Alle ausgeliehenen Medien", font: .boldSystemFont(ofSize: 14))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(titleLabel)

        let summaryLabel = label("", font: .systemFont(ofSize: 11))
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.tag = 1001
        toolbar.addSubview(summaryLabel)

        let refreshBtn = NSButton(title: "↺  Aktualisieren", target: self, action: #selector(onRefresh))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(refreshBtn)

        let renewBtn = NSButton(title: "↺  Auswahl verlängern …", target: self, action: #selector(onRenewSelection))
        renewBtn.bezelStyle = .rounded
        renewBtn.isEnabled = false
        renewBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(renewBtn)
        renewButton = renewBtn

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: -8),
            summaryLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            summaryLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor, constant: 8),
            refreshBtn.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            refreshBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            renewBtn.trailingAnchor.constraint(equalTo: refreshBtn.leadingAnchor, constant: -8),
            renewBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            // Titel/Zusammenfassung dürfen nicht unter die Knöpfe laufen (kleines Fenster).
            renewBtn.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            toolbar.heightAnchor.constraint(equalToConstant: 56),
        ])

        // ── Table ──────────────────────────────────────────────────
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true

        // Rechtsklick → „Verlängern …". Titel/Zustand werden in `menuNeedsUpdate` gesetzt.
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        rowMenu.autoenablesItems = false   // sonst überschreibt AppKit das isEnabled aus menuNeedsUpdate
        rowMenu.addItem(NSMenuItem(title: "Verlängern …", action: #selector(onRenewSelection), keyEquivalent: ""))
        rowMenu.items.forEach { $0.target = self }
        table.menu = rowMenu

        let cols: [(id: String, title: String, width: CGFloat, minWidth: CGFloat)] = [
            ("emoji",   "",              24,  24),
            ("title",   "Titel",         300, 100),
            ("account", "Konto",         70,  50),
            ("due",     "Fällig am",     85,  80),
            ("days",    "Tage",          45,  40),
            ("renew",   "Verlängerbar",  270, 90),
            ("library", "Bibliothek",    200, 80),
        ]
        for col in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            c.title = col.title
            c.width = col.width
            c.minWidth = col.minWidth
            if col.id == "due" || col.id == "days" {
                c.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: true)
            }
            if col.id == "title" {
                c.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: true)
            }
            table.addTableColumn(c)
        }

        // Remember column widths/order the user sets (initial widths above apply only once).
        table.autosaveName = "VOEBBOverviewTable"
        table.autosaveTableColumns = true
        table.delegate = self
        table.dataSource = self
        scrollView.documentView = table
        tableView = table

        // ── Layout ────────────────────────────────────────────────
        cv.addSubview(toolbar)
        cv.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: cv.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: cv.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])

        win.contentView = cv
        window = win
    }

    // MARK: - Summary Label

    private func updateSummaryLabel() {
        guard let win = window,
              let label = win.contentView?.viewWithTag(1001) as? NSTextField else { return }

        let total = allLoans.count
        if total == 0 {
            label.stringValue = "Keine Ausleihen"
            return
        }
        let urgent = allLoans.filter { $0.loan.daysUntilDue < Urgency.urgentDays }.count
        var parts = ["\(total) Ausleihe\(total == 1 ? "" : "n")"]
        if urgent > 0 {
            parts.append("\(urgent) bald fällig")
        }
        label.stringValue = parts.joined(separator: "  ·  ")
    }

    // MARK: - Selection

    /// Rows a row action applies to: the right-clicked row, unless it is part of the current
    /// multi-row selection (then the whole selection) — Finder's behaviour. Without a click
    /// (toolbar button) it is simply the selection.
    private func targetRows() -> [Int] {
        guard let table = tableView else { return [] }
        let selected = table.selectedRowIndexes
        let clicked = table.clickedRow
        if clicked >= 0, !selected.contains(clicked) { return [clicked] }
        return selected.sorted()
    }

    private func updateRenewButton() {
        renewButton?.isEnabled = !(tableView?.selectedRowIndexes.isEmpty ?? true)
    }

    /// Identity of a row for selection purposes: account + loan, because `reloadData()` keeps row
    /// *indexes*. Without remapping, sorting by a column header or a refresh would silently move
    /// the selection onto different media — and then renew those.
    private func rowID(_ item: (account: LibraryAccount, loan: Loan)) -> String {
        "\(item.account.cardNumber)|\(item.loan.renewalKey)"
    }

    private func selectedLoanIDs() -> Set<String> {
        guard let table = tableView else { return [] }
        return Set(table.selectedRowIndexes.filter { $0 < allLoans.count }.map { rowID(allLoans[$0]) })
    }

    private func restoreSelection(_ ids: Set<String>) {
        guard let table = tableView, !ids.isEmpty else { return }
        table.selectRowIndexes(IndexSet(allLoans.indices.filter { ids.contains(rowID(allLoans[$0])) }),
                               byExtendingSelection: false)
    }

    // MARK: - Actions

    @objc private func onRefresh() {
        statusBar?.refresh()
    }

    /// Verlängert die markierten (bzw. rechtsgeklickte) Medien — die Bestätigung und der
    /// Netzwerkteil liegen im StatusBarController, damit Menü- und Fenster-Weg identisch laufen.
    @objc private func onRenewSelection() {
        let rows = targetRows().filter { $0 < allLoans.count }
        guard !rows.isEmpty else { return }
        statusBar?.renewSelected(rows.map { allLoans[$0] }, anchor: window)
    }

    // MARK: - Helper

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.isBezeled = false
        f.isEditable = false
        f.backgroundColor = .clear
        return f
    }
}

// MARK: - NSTableViewDataSource

extension OverviewWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { allLoans.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let desc = tableView.sortDescriptors.first else { return }
        let selected = selectedLoanIDs()
        allLoans.sort {
            switch desc.key {
            case "title":
                let cmp = $0.loan.title.localizedCompare($1.loan.title)
                return desc.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            case "due", "days":
                return desc.ascending
                    ? $0.loan.dueDate < $1.loan.dueDate
                    : $0.loan.dueDate > $1.loan.dueDate
            default: return false
            }
        }
        tableView.reloadData()
        restoreSelection(selected)
    }
}

// MARK: - NSTableViewDelegate

extension OverviewWindowController: NSTableViewDelegate {
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRenewButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < allLoans.count else { return nil }
        let item = allLoans[row]
        let loan = item.loan

        let cell = NSTextField(labelWithString: "")
        cell.isBezeled = false
        cell.isEditable = false
        cell.backgroundColor = .clear
        cell.lineBreakMode = .byTruncatingTail

        switch tableColumn?.identifier.rawValue {
        case "emoji":
            cell.stringValue = "●"
            cell.textColor = loan.urgencyColor
            cell.alignment = .center

        case "title":
            cell.stringValue = loan.title
            cell.toolTip = "\(loan.title)\n\(LibraryName.short(loan.library))"

        case "account":
            cell.stringValue = item.account.name

        case "due":
            cell.stringValue = loan.dueDateString
            if loan.daysUntilDue < Urgency.urgentDays {
                cell.textColor = .systemRed
            } else if loan.daysUntilDue <= Urgency.soonDays {
                cell.textColor = .systemOrange
            }

        case "days":
            let days = loan.daysUntilDue
            if loan.isOverdue {
                cell.stringValue = "überfällig"
                cell.textColor = .systemRed
            } else {
                cell.stringValue = "\(days)d"
                cell.textColor = days < Urgency.urgentDays ? .systemRed : days <= Urgency.soonDays ? .systemOrange : .secondaryLabelColor
            }

        case "renew":
            switch loan.isRenewable {
            case .some(true):
                cell.stringValue = "✓ verlängerbar"
                cell.textColor = .systemGreen
            case .some(false):
                let reason = RenewabilityRow.shorten(loan.renewalReason)
                cell.stringValue = reason.isEmpty ? "✗ nicht verlängerbar" : "✗ \(reason)"
                cell.textColor = .systemRed
                cell.toolTip = loan.renewalReason.isEmpty ? nil : loan.renewalReason
            case .none:
                cell.stringValue = "–"
                cell.textColor = .secondaryLabelColor
            }

        case "library":
            cell.stringValue = LibraryName.short(loan.library)
            cell.toolTip = loan.library

        default: break
        }

        return cell
    }
}

// MARK: - NSMenuDelegate (row context menu)

extension OverviewWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.items.first else { return }
        let count = targetRows().filter { $0 < allLoans.count }.count
        item.title = count > 1 ? "\(count) Medien verlängern …" : "Verlängern …"
        item.isEnabled = count > 0
    }
}
