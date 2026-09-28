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

        // Per-item enrichment fetched from VÖBB's catalog (ISBN/cover/blurb/…). Keyed by the
        // item barcode. voebbar writes this; the archive app reads it.
        exec("""
        CREATE TABLE IF NOT EXISTS media_details (
            media_number TEXT PRIMARY KEY,
            isbn         TEXT NOT NULL DEFAULT '',
            cover_path   TEXT NOT NULL DEFAULT '',
            blurb        TEXT NOT NULL DEFAULT '',
            subjects     TEXT NOT NULL DEFAULT '',
            systematik   TEXT NOT NULL DEFAULT '',
            source       TEXT NOT NULL DEFAULT '',   -- 'title' | 'isbn' | 'manual' | 'tonie'
            status       TEXT NOT NULL DEFAULT '',   -- 'found' | 'notfound'
            fetched_at   TEXT NOT NULL DEFAULT '',
            author          TEXT NOT NULL DEFAULT '',
            published       TEXT NOT NULL DEFAULT '',   -- "Verlag, [Jahr]" (Fundus derives the year)
            series          TEXT NOT NULL DEFAULT '',
            interessenkreis TEXT NOT NULL DEFAULT '',   -- e.g. age recommendation
            detail_version  INTEGER NOT NULL DEFAULT 0,  -- bumped when the Vollanzeige fields are captured
            record_id       TEXT NOT NULL DEFAULT '',    -- aDIS record key (AK…); Fundus builds the Vollanzeige permalink from it
            cover_attempts  INTEGER NOT NULL DEFAULT 0,  -- failed VLB cover-heal tries; caps the retry loop
            notfound_attempts INTEGER NOT NULL DEFAULT 0 -- title searches that came back empty; caps the notfound retry
        );
        """)
        // Lightweight upgrade for DBs created before these columns existed. ALTER errors
        // ("duplicate column") are ignored on a fresh DB that already has them.
        for col in ["author TEXT NOT NULL DEFAULT ''",
                    "published TEXT NOT NULL DEFAULT ''",
                    "series TEXT NOT NULL DEFAULT ''",
                    "interessenkreis TEXT NOT NULL DEFAULT ''",
                    "detail_version INTEGER NOT NULL DEFAULT 0",
                    "record_id TEXT NOT NULL DEFAULT ''",
                    "cover_attempts INTEGER NOT NULL DEFAULT 0",
                    "notfound_attempts INTEGER NOT NULL DEFAULT 0"] {
            exec("ALTER TABLE media_details ADD COLUMN \(col);", ignoringErrors: true)
        }
        // Manual ISBN corrections. The archive app WRITES these; voebbar reads them and
        // re-fetches the record by ISBN (unambiguous). Small shared contract, reverse direction.
        exec("""
        CREATE TABLE IF NOT EXISTS media_isbn_override (
            media_number TEXT PRIMARY KEY,
            isbn         TEXT NOT NULL,
            created_at   TEXT NOT NULL DEFAULT ''
        );
        """)
        // Items ready for pickup ("Bereitstellungen"). voebbar writes, Fundus reads (return
        // checklist). A CURRENT SNAPSHOT, not history: each successfully read account's rows are
        // replaced; an account whose pickups are unknown this refresh stays untouched.
        exec("""
        CREATE TABLE IF NOT EXISTS pickups (
            account_card TEXT NOT NULL,
            account_name TEXT NOT NULL,
            media_number TEXT NOT NULL,             -- barcode, else 't:<title>|<library>' (like borrow_events)
            title        TEXT NOT NULL,
            library      TEXT NOT NULL DEFAULT '',  -- raw "Bezirk: Name" pickup location
            ready_until  TEXT NOT NULL DEFAULT '',  -- yyyy-MM-dd pickup deadline, '' if unknown
            first_seen   TEXT NOT NULL,
            last_seen    TEXT NOT NULL,
            PRIMARY KEY (account_card, media_number)
        );
        """)
        // Schema marker for external tools only — neither voebbar nor Fundus reads it (checked
        // 2026-09). Kept because the DB is shared; bump it with schema changes.
        exec("PRAGMA user_version=5;")
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

        if let pickups = data.pickups {
            recordPickups(pickups, card: card, name: data.account.name, now: now)
        }
    }

    /// Replaces this account's pickup snapshot: upsert what's listed now (keeping `first_seen`),
    /// delete what's gone (picked up or expired). One transaction, so Fundus never sees it half-done.
    private func recordPickups(_ pickups: [PickupItem], card: String, name: String, now: String) {
        exec("BEGIN;")
        var keys: [String] = []
        for p in pickups {
            let key = p.mediaNumber.isEmpty ? "t:\(p.title)|\(p.library)" : p.mediaNumber
            keys.append(key)
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO pickups (account_card, account_name, media_number, title, library, ready_until, first_seen, last_seen)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(account_card, media_number) DO UPDATE SET
                account_name=excluded.account_name, title=excluded.title, library=excluded.library,
                ready_until=excluded.ready_until, last_seen=excluded.last_seen;
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bind(stmt, 1, card)
                bind(stmt, 2, name)
                bind(stmt, 3, key)
                bind(stmt, 4, p.title)
                bind(stmt, 5, p.library)
                bind(stmt, 6, Self.isoDay(fromGerman: p.readyUntilString))
                bind(stmt, 7, now)
                bind(stmt, 8, now)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        // Everything of this account not seen in this refresh is gone.
        var stmt: OpaquePointer?
        let placeholders = keys.map { _ in "?" }.joined(separator: ",")
        let sql = keys.isEmpty
            ? "DELETE FROM pickups WHERE account_card=?;"
            : "DELETE FROM pickups WHERE account_card=? AND media_number NOT IN (\(placeholders));"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bind(stmt, 1, card)
            for (i, key) in keys.enumerated() { bind(stmt, Int32(i + 2), key) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT;")
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
        bind(stmt, 10, Self.isoDay(fromGerman: loan.dueDateString))
        sqlite3_step(stmt)
    }

    private func update(id: Int64, loan: Loan, now: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // signature/media_type/library follow the page too (media_type feeds the Tonie gate), but an
        // empty parse never blanks a value we already have.
        let sql = """
        UPDATE borrow_events SET last_seen=?, due_date=?, title=?,
            signature=COALESCE(NULLIF(?, ''), signature),
            media_type=COALESCE(NULLIF(?, ''), media_type),
            library=COALESCE(NULLIF(?, ''), library)
        WHERE id=?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bind(stmt, 1, now)
        bind(stmt, 2, Self.isoDay(fromGerman: loan.dueDateString))
        bind(stmt, 3, loan.title)
        bind(stmt, 4, loan.signature)
        bind(stmt, 5, loan.mediaType)
        bind(stmt, 6, loan.library)
        sqlite3_bind_int64(stmt, 7, id)
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
                let key = col(stmt, 1)
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

    // MARK: - Media details (enrichment from VÖBB's catalog)

    struct EnrichTarget {
        let mediaNumber: String
        let title: String
        /// Typed Tonie by VÖBB or by a Fundus correction — as opposed to a CD/Hörbuch that is only
        /// a Tonie candidate. Set by `toniesNeedingImage()` only.
        var isTonie = false
    }
    struct ISBNOverride { let mediaNumber: String; let isbn: String }

    /// Items in borrow_events not yet in media_details (neither 'found' nor 'notfound').
    /// Drives the strictly-incremental crawl — processed items are never re-crawled.
    func mediaNeedingEnrichment() -> [EnrichTarget] {
        return queue.sync {
            guard db != nil else { return [] }
            var out: [EnrichTarget] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT b.media_number, b.title FROM borrow_events b
            LEFT JOIN media_details d ON d.media_number = b.media_number
            WHERE d.media_number IS NULL AND b.media_number <> ''
            GROUP BY b.media_number;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(EnrichTarget(mediaNumber: col(stmt, 0), title: col(stmt, 1)))
            }
            return out
        }
    }

    /// Title-searched items locked as 'notfound' that deserve another try: an empty search is not
    /// always a real miss (VÖBB once answered a search that works fine a day later with a cover-less
    /// page, and a loan-list title the catalog can't match used to be locked for good). Retried at
    /// most `maxNotFoundAttempts` times in total, each after `notFoundRetryDays`. Rows from before
    /// the counter existed (attempts = 0) are due at once, so the fallback search terms reach them.
    func mediaNeedingNotFoundRetry() -> [EnrichTarget] {
        return queue.sync {
            guard db != nil else { return [] }
            var out: [EnrichTarget] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT d.media_number, b.title FROM media_details d
            JOIN borrow_events b ON b.media_number = d.media_number
            WHERE d.status = 'notfound' AND d.source = 'title'
              AND d.notfound_attempts < \(Self.maxNotFoundAttempts)
              AND (d.notfound_attempts = 0
                   OR d.fetched_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-\(Self.notFoundRetryDays) days'))
            GROUP BY d.media_number;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(EnrichTarget(mediaNumber: col(stmt, 0), title: col(stmt, 1)))
            }
            return out
        }
    }

    static let maxNotFoundAttempts = 3
    static let notFoundRetryDays = 3

    func bumpNotFoundAttempt(mediaNumber: String) {
        queue.sync {
            guard db != nil else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE media_details SET notfound_attempts = notfound_attempts + 1 WHERE media_number=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, mediaNumber)
            sqlite3_step(stmt)
        }
    }

    /// Manual ISBN corrections not yet applied (missing details, or not locked as 'manual',
    /// or a different ISBN). Re-crawled by ISBN, then locked with source='manual'.
    func pendingISBNOverrides() -> [ISBNOverride] {
        return queue.sync {
            guard db != nil else { return [] }
            var out: [ISBNOverride] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT o.media_number, o.isbn FROM media_isbn_override o
            LEFT JOIN media_details d ON d.media_number = o.media_number
            WHERE d.media_number IS NULL OR d.source <> 'manual' OR d.isbn <> o.isbn;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(ISBNOverride(mediaNumber: col(stmt, 0), isbn: col(stmt, 1)))
            }
            return out
        }
    }

    /// Borrowed Tonies (and CD/Hörbuch items, which may be mislabelled Tonies) that don't yet have
    /// a Tonie image. A prior VÖBB-catalog row (source='title'/'notfound') doesn't count — only a
    /// real `source='tonie'` cover does — so the Tonie enricher still fills it. Not locked as
    /// notfound: an unmatched Tonie may simply not have been on the box yet.
    func toniesNeedingImage() -> [EnrichTarget] {
        return queue.sync {
            guard db != nil else { return [] }
            // Also honour a Fundus media-type correction to "Tonie": a Tonie that VÖBB catalogues
            // under a non-Tonie type (e.g. "Gerät") is invisible to the media_type gate, but the user
            // can mark it as a Tonie in Fundus (fundus_media_types). That table is Fundus-owned, so we
            // only join it when it actually exists — otherwise a LEFT JOIN on a missing table would
            // fail `prepare` and silently kill Tonie enrichment for everyone. The override is purely
            // additive: it can pull an item INTO the pass, never remove one VÖBB already types Tonie.
            let hasOverrides = tableExists("fundus_media_types")
            let overrideJoin = hasOverrides
                ? "LEFT JOIN fundus_media_types f ON f.media_number = b.media_number"
                : ""
            let overrideMatch = hasOverrides ? " OR f.media_type = 'Tonie'" : ""
            let sql = """
            SELECT b.media_number, b.title, MAX(b.media_type = 'Tonie'\(overrideMatch)) FROM borrow_events b
            LEFT JOIN media_details d ON d.media_number = b.media_number
            \(overrideJoin)
            WHERE b.media_number <> ''
              AND (b.media_type = 'Tonie' OR b.media_type LIKE '%Hörbuch%' OR b.media_type LIKE '%CD%'\(overrideMatch))
              AND (d.media_number IS NULL OR d.source <> 'tonie' OR d.cover_path = '')
            GROUP BY b.media_number;
            """
            var out: [EnrichTarget] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(EnrichTarget(mediaNumber: col(stmt, 0), title: col(stmt, 1),
                                        isTonie: sqlite3_column_int(stmt, 2) != 0))
            }
            return out
        }
    }

    /// Whether a table exists in the shared DB. Lets us optionally read a Fundus-owned table without
    /// creating it or failing `prepare` when Fundus has never run. MUST be called on `queue` (it uses
    /// `db` directly and must not re-enter `queue.sync`).
    private func tableExists(_ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return false }
        bind(stmt, 1, name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Sets a Tonie's cover image without clobbering any book fields (isbn/blurb/… stay untouched on
    /// conflict). Marks the row `source='tonie'`, `status='found'`.
    func upsertToniImage(mediaNumber: String, coverPath: String) {
        queue.sync {
            guard db != nil else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            INSERT INTO media_details (media_number, cover_path, source, status, fetched_at)
            VALUES (?,?,'tonie','found',?)
            ON CONFLICT(media_number) DO UPDATE SET cover_path=excluded.cover_path,
                source='tonie', status='found', fetched_at=excluded.fetched_at;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, mediaNumber); bind(stmt, 2, coverPath); bind(stmt, 3, Self.iso8601(Date()))
            sqlite3_step(stmt)
        }
    }

    func upsertMediaDetails(mediaNumber: String, isbn: String, coverPath: String,
                            detail: HTMLParser.CatalogDetail, source: String, status: String,
                            recordID: String) {
        queue.sync {
            guard db != nil else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            INSERT INTO media_details
                (media_number, isbn, cover_path, blurb, subjects, systematik, source, status, fetched_at,
                 author, published, series, interessenkreis, detail_version, record_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,4,?)
            ON CONFLICT(media_number) DO UPDATE SET isbn=excluded.isbn, cover_path=excluded.cover_path,
                blurb=excluded.blurb, subjects=excluded.subjects, systematik=excluded.systematik,
                source=excluded.source, status=excluded.status, fetched_at=excluded.fetched_at,
                author=excluded.author, published=excluded.published, series=excluded.series,
                interessenkreis=excluded.interessenkreis, detail_version=excluded.detail_version,
                record_id=excluded.record_id;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, mediaNumber); bind(stmt, 2, isbn); bind(stmt, 3, coverPath); bind(stmt, 4, detail.blurb)
            bind(stmt, 5, detail.subjects); bind(stmt, 6, detail.systematik); bind(stmt, 7, source); bind(stmt, 8, status)
            bind(stmt, 9, Self.iso8601(Date()))
            bind(stmt, 10, detail.author); bind(stmt, 11, detail.published); bind(stmt, 12, detail.series)
            bind(stmt, 13, detail.interessenkreis); bind(stmt, 14, recordID)
            sqlite3_step(stmt)
        }
    }

    /// One-time backfill target: an already-enriched book whose Vollanzeige fields predate the
    /// current parser. Re-fetched by ISBN (unambiguous); the cover/source/status stay put.
    /// `detail_version` marks the parser generation: 1 = author/year/… columns, 2 = the
    /// "Zusammenfassung" blurb fallback, 3 = multi-value author/Veröffentlichung (co-authors with a
    /// separator, year from a second Veröffentlichung row), 4 = the `record_id` (Vollanzeige
    /// permalink key). Gen 4 re-reads every found book once so existing rows gain their record_id.
    struct DetailTarget { let mediaNumber: String; let isbn: String }

    func mediaNeedingDetailBackfill() -> [DetailTarget] {
        return queue.sync {
            guard db != nil else { return [] }
            var out: [DetailTarget] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            // Tonies take part too: `updateDetailFields` touches neither cover_path nor source, so
            // their my.tonies image survives, and their `isbn` holds the EAN box code — which the
            // catalog search resolves just like an ISBN. Without them they'd never get a record_id
            // and thus no catalog link.
            let sql = """
            SELECT media_number, isbn FROM media_details
            WHERE detail_version < 4 AND status = 'found' AND isbn <> '';
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DetailTarget(mediaNumber: col(stmt, 0), isbn: col(stmt, 1)))
            }
            return out
        }
    }

    /// Backfill: refresh only the Vollanzeige text fields plus the `record_id` (cover/source/status/
    /// isbn untouched) and mark the row as up to date.
    func updateDetailFields(mediaNumber: String, detail: HTMLParser.CatalogDetail, recordID: String) {
        queue.sync {
            guard db != nil else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            UPDATE media_details SET blurb=?, subjects=?, systematik=?, author=?, published=?,
                series=?, interessenkreis=?, record_id=?, detail_version=4 WHERE media_number=?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, detail.blurb); bind(stmt, 2, detail.subjects); bind(stmt, 3, detail.systematik)
            bind(stmt, 4, detail.author); bind(stmt, 5, detail.published); bind(stmt, 6, detail.series)
            bind(stmt, 7, detail.interessenkreis); bind(stmt, 8, recordID); bind(stmt, 9, mediaNumber)
            sqlite3_step(stmt)
        }
    }

    /// Marks a row as backfilled without changing any field. For a search that succeeded but found
    /// nothing: the row has no Vollanzeige to read, and leaving `detail_version` behind would
    /// re-crawl it on every single refresh.
    func markDetailBackfilled(mediaNumber: String) {
        queue.sync {
            guard db != nil else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE media_details SET detail_version=4 WHERE media_number=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, mediaNumber)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Cover self-heal

    /// Found catalog books that carry a real ISBN but never got a cover file (a transient download
    /// miss at enrichment time, then frozen as 'found' so nothing retries them). Restricted to
    /// ISBN-shaped keys (`97…`) so Tonie EAN box codes stay with the Tonie image pass, and capped
    /// via `cover_attempts` so a genuinely cover-less book (VÖBB 404) isn't retried forever.
    func coversNeedingHeal() -> [DetailTarget] {
        return queue.sync {
            guard db != nil else { return [] }
            var out: [DetailTarget] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT media_number, isbn FROM media_details
            WHERE status = 'found' AND cover_path = '' AND isbn LIKE '97%'
              AND source IN ('title','isbn','manual') AND cover_attempts < 3;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DetailTarget(mediaNumber: col(stmt, 0), isbn: col(stmt, 1)))
            }
            return out
        }
    }

    func setCoverPath(mediaNumber: String, coverPath: String) {
        queue.sync {
            guard db != nil else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE media_details SET cover_path=? WHERE media_number=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, coverPath); bind(stmt, 2, mediaNumber)
            sqlite3_step(stmt)
        }
    }

    func bumpCoverAttempt(mediaNumber: String) {
        queue.sync {
            guard db != nil else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE media_details SET cover_attempts = cover_attempts + 1 WHERE media_number=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, mediaNumber)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Manual rescrape (Fundus-triggered)

    struct RescrapeTarget { let mediaNumber: String; let title: String; let overrideISBN: String }

    /// Items Fundus has flagged for a fresh catalog crawl (`fundus_rescrape`). Self-resolving: a row
    /// is a target only while its `requested_at` is newer than the last enrichment (`fetched_at`), so
    /// once we re-crawl it stops firing — voebbar never has to write back into the Fundus table. The
    /// table is Fundus-owned, so we only read it when it exists (like `toniesNeedingImage`).
    func mediaNeedingRescrape() -> [RescrapeTarget] {
        return queue.sync {
            guard db != nil, tableExists("fundus_rescrape") else { return [] }
            var out: [RescrapeTarget] = []
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT r.media_number, b.title, COALESCE(o.isbn, '')
            FROM fundus_rescrape r
            JOIN (SELECT media_number, title, MAX(last_seen) FROM borrow_events GROUP BY media_number) b
                 ON b.media_number = r.media_number
            LEFT JOIN media_details d       ON d.media_number = r.media_number
            LEFT JOIN media_isbn_override o ON o.media_number = r.media_number
            WHERE d.media_number IS NULL OR d.fetched_at = '' OR d.fetched_at < r.requested_at;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(RescrapeTarget(mediaNumber: col(stmt, 0), title: col(stmt, 1), overrideISBN: col(stmt, 2)))
            }
            return out
        }
    }

    /// Clears the cover-heal attempt cap for an item so a manual rescrape gets fresh tries.
    func resetCoverAttempts(mediaNumber: String) {
        queue.sync {
            guard db != nil else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "UPDATE media_details SET cover_attempts = 0 WHERE media_number=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            bind(stmt, 1, mediaNumber)
            sqlite3_step(stmt)
        }
    }

    /// Directory next to the DB where cover images are cached (`…/de.voebb.menubar/covers`).
    static var coversDirectory: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("covers", isDirectory: true)
    }

    private func col(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    // MARK: - Helpers

    /// Logs failures (full disk, corrupt DB …) so they don't vanish silently. `ignoringErrors` is
    /// only for the column upgrades, where "duplicate column" is the expected outcome.
    private func exec(_ sql: String, ignoringErrors: Bool = false) {
        guard sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK, !ignoringErrors else { return }
        NSLog("voebbar archive: SQL failed (%@): %@", String(sql.prefix(80)), String(cString: sqlite3_errmsg(db)))
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

    /// "19.09.2026" → "2026-09-19" by plain string surgery (no Date round-trip, so no timezone
    /// shift); '' for anything else. Used for `due_date` and `ready_until`: formatting the parsed
    /// local-midnight Date in UTC used to store every due date one day early (fixed 2026-09-28).
    static func isoDay(fromGerman s: String) -> String {
        let parts = s.split(separator: ".").map(String.init)
        guard parts.count == 3, let d = Int(parts[0]), let m = Int(parts[1]), let y = Int(parts[2]),
              (1...31).contains(d), (1...12).contains(m), y > 1900 else { return "" }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
