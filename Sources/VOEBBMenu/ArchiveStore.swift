import Foundation
import SQLite3

/// Persistent archive of every borrowed item, written on each successful refresh.
///
/// voebbar only WRITES here; a separate archive app reads the same file. The single
/// contract between the two is this SQLite file and its `borrow_events` schema — no
/// shared code, no IPC. The schema is designed so the archive app can add its own
/// tables (ratings, covers, …) without voebbar knowing.
final class ArchiveStore {
    static let shared = ArchiveStore()

    /// `~/Library/Application Support/de.voebb.menubar/archive.sqlite`
    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("de.voebb.menubar", isDirectory: true)
            .appendingPathComponent("archive.sqlite", isDirectory: false)
    }

    // SQLITE_TRANSIENT tells SQLite to copy bound strings (they outlive the bind call otherwise).
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let queue = DispatchQueue(label: "de.voebb.menubar.archive")
    private var db: OpaquePointer?

    private init() {
        queue.sync { open() }
    }

    // MARK: - Public API

    /// Upserts the current loans of every successfully-fetched account and reconciles returns.
    /// Accounts with a fetch error are skipped entirely (never treated as "all returned").
    func record(_ results: [AccountData]) {
        queue.sync {
            guard db != nil else { return }
            let now = Self.iso8601(Date())
            for data in results where data.error == nil {
                recordAccount(data, now: now)
            }
        }
    }

    // MARK: - Setup

    private func open() {
        let url = Self.databaseURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        migrate()
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS borrow_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_card TEXT NOT NULL,
            account_name TEXT NOT NULL,
            media_number TEXT NOT NULL,
            title TEXT NOT NULL,
            signature TEXT NOT NULL DEFAULT '',
            media_type TEXT NOT NULL DEFAULT '',
            library TEXT NOT NULL DEFAULT '',
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            due_date TEXT NOT NULL DEFAULT '',
            returned_at TEXT,
            is_open INTEGER NOT NULL DEFAULT 1
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_open ON borrow_events (account_card, media_number, is_open);")
        exec("PRAGMA user_version=1;")
    }

    // MARK: - Per-account write

    private func recordAccount(_ data: AccountData, now: String) {
        let card = data.account.cardNumber
        var seenKeys = Set<String>()

        for loan in data.loans {
            let key = Self.identity(for: loan)
            seenKeys.insert(key)

            if let id = openEventID(card: card, mediaNumber: key) {
                update(id: id, loan: loan, now: now)
            } else {
                insert(card: card, name: data.account.name, key: key, loan: loan, now: now)
            }
        }

        // Reconcile returns: open events of this account no longer present → returned.
        markReturned(card: card, keeping: seenKeys, now: now)
    }

    /// Stable identity: the barcode when present, else a title+library fallback.
    private static func identity(for loan: Loan) -> String {
        loan.mediaNumber.isEmpty ? "t:\(loan.title)|\(loan.library)" : loan.mediaNumber
    }

    private func openEventID(card: String, mediaNumber: String) -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT id FROM borrow_events WHERE account_card=? AND media_number=? AND is_open=1 LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        bind(stmt, 1, card)
        bind(stmt, 2, mediaNumber)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func insert(card: String, name: String, key: String, loan: Loan, now: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT INTO borrow_events
            (account_card, account_name, media_number, title, signature, media_type, library,
             first_seen, last_seen, due_date, is_open)
        VALUES (?,?,?,?,?,?,?,?,?,?,1);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt, 1, card)
        bind(stmt, 2, name)
        bind(stmt, 3, key)
        bind(stmt, 4, loan.title)
        bind(stmt, 5, loan.signature)
        bind(stmt, 6, loan.mediaType)
        bind(stmt, 7, loan.library)
        bind(stmt, 8, now)
        bind(stmt, 9, now)
        bind(stmt, 10, Self.isoDate(loan.dueDate))
        sqlite3_step(stmt)
    }

    private func update(id: Int64, loan: Loan, now: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "UPDATE borrow_events SET last_seen=?, due_date=?, title=? WHERE id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt, 1, now)
        bind(stmt, 2, Self.isoDate(loan.dueDate))
        bind(stmt, 3, loan.title)
        sqlite3_bind_int64(stmt, 4, id)
        sqlite3_step(stmt)
    }

    private func markReturned(card: String, keeping seenKeys: Set<String>, now: String) {
        // Collect open keys, then close those not seen this run. Done in Swift to keep the
        // SQL simple and avoid building a variable-length IN(...) clause.
        var toClose: [Int64] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, media_number FROM borrow_events WHERE account_card=? AND is_open=1;"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bind(stmt, 1, card)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let key = String(cString: sqlite3_column_text(stmt, 1))
                if !seenKeys.contains(key) { toClose.append(id) }
            }
        }
        sqlite3_finalize(stmt)

        for id in toClose {
            var up: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE borrow_events SET is_open=0, returned_at=? WHERE id=?;", -1, &up, nil) == SQLITE_OK {
                bind(up, 1, now)
                sqlite3_bind_int64(up, 2, id)
                sqlite3_step(up)
            }
            sqlite3_finalize(up)
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func iso8601(_ date: Date) -> String { iso8601Formatter.string(from: date) }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func isoDate(_ date: Date) -> String { dateFormatter.string(from: date) }
}
