import Foundation
import SQLite3
import Testing
@testable import VOEBBMenu

// ArchiveStore is the data contract with Fundus: every test runs against its own temp database
// (never the real one) and reads it back with raw SQLite, the way Fundus would. Fixtures are invented.

// MARK: - Helpers

private let t1 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z
private let t2 = Date(timeIntervalSince1970: 1_800_086_400)   // 2027-01-16T08:00:00Z
private let t3 = Date(timeIntervalSince1970: 1_800_172_800)   // 2027-01-17T08:00:00Z
private let s1 = "2027-01-15T08:00:00Z"
private let s2 = "2027-01-16T08:00:00Z"
private let s3 = "2027-01-17T08:00:00Z"

/// Runs `body` with a fresh store on a temp file and removes the file afterwards.
private func withStore(_ body: (ArchiveStore, URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = dir.appendingPathComponent("archive.sqlite")
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        let store = ArchiveStore(databaseURL: url)
        try body(store, url)
    }
}

/// Opens the DB independently, runs `sql` and returns every value as text ("NULL" for NULL).
@discardableResult
private func raw(_ url: URL, _ sql: String, write: Bool = false) -> [[String]] {
    var db: OpaquePointer?
    let flags = write ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
    guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5000)
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        Issue.record("raw SQL failed: \(sql): \(String(cString: sqlite3_errmsg(db)))")
        return []
    }
    defer { sqlite3_finalize(stmt) }
    var rows: [[String]] = []
    while true {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(stmt)).map { i in
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? "NULL" : String(cString: sqlite3_column_text(stmt, i))
            })
        } else {
            if rc != SQLITE_DONE { Issue.record("raw step failed: \(sql)") }
            break
        }
    }
    return rows
}

private func account(_ card: String) -> LibraryAccount { LibraryAccount(name: "Name \(card)", cardNumber: card) }

private func loan(_ title: String, barcode: String = "", due: String = "19.09.2027", library: String = "Lib A",
                  signature: String = "Sig 1", type: String = "Buch") -> Loan {
    Loan(title: title, dueDate: Date(), dueDateString: due, library: library, checkboxValue: "cb",
         mediaNumber: barcode, signature: signature, mediaType: type)
}

private func data(_ card: String, _ loans: [Loan], pickups: [PickupItem]? = nil, error: String? = nil) -> AccountData {
    var d = AccountData(account: account(card), loans: loans)
    d.pickups = pickups
    d.error = error
    return d
}

private func pickup(_ title: String, barcode: String, until: String = "25.09.2027") -> PickupItem {
    PickupItem(title: title, mediaNumber: barcode, readyUntilString: until, readyUntil: nil, library: "Mitte: Lib")
}

private let loanCols = "account_card, media_number, title, is_open, first_seen, last_seen, due_date, returned_at"
private func events(_ url: URL, _ card: String) -> [[String]] {
    raw(url, "SELECT \(loanCols) FROM borrow_events WHERE account_card='\(card)' ORDER BY id;")
}

private let emptyDetail = HTMLParser.CatalogDetail.empty

// MARK: - borrow_events

@Suite struct ArchiveRecordTests {
    @Test func firstRecordWritesOpenRows() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", barcode: "12345678901", due: "05.03.2027",
                                           library: "Lib A", signature: "Sig 1", type: "Tonie")])], now: t1)
            #expect(raw(url, "SELECT account_card, account_name, media_number, title, signature, media_type, library, first_seen, last_seen, due_date, is_open, returned_at FROM borrow_events;")
                    == [["A1", "Name A1", "12345678901", "Alpha", "Sig 1", "Tonie", "Lib A", s1, s1, "2027-03-05", "1", "NULL"]])
        }
    }

    @Test func rerecordUpdatesInPlaceAndNeverBlanks() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", barcode: "12345678901", due: "05.03.2027")])], now: t1)
            store.record([data("A1", [loan("Alpha 2", barcode: "12345678901", due: "02.04.2027",
                                           library: "", signature: "", type: "")])], now: t2)
            #expect(events(url, "A1") == [["A1", "12345678901", "Alpha 2", "1", s1, s2, "2027-04-02", "NULL"]])
            #expect(raw(url, "SELECT signature, media_type, library FROM borrow_events;") == [["Sig 1", "Buch", "Lib A"]])
        }
    }

    @Test func missingLoanIsClosedOthersStayOpen() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", barcode: "11111111111"), loan("Beta", barcode: "22222222222")])], now: t1)
            store.record([data("A1", [loan("Beta", barcode: "22222222222")])], now: t2)
            #expect(events(url, "A1") == [
                ["A1", "11111111111", "Alpha", "0", s1, s1, "2027-09-19", s2],
                ["A1", "22222222222", "Beta", "1", s1, s2, "2027-09-19", "NULL"],
            ])
        }
    }

    @Test func accountWithErrorIsSkippedEntirely() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", barcode: "11111111111")])], now: t1)
            store.record([data("A1", [], error: "Login fehlgeschlagen")], now: t2)
            #expect(events(url, "A1") == [["A1", "11111111111", "Alpha", "1", s1, s1, "2027-09-19", "NULL"]])
        }
    }

    @Test func otherAccountsAreIsolated() {
        withStore { store, url in
            // Same media_number held by both cards.
            store.record([data("A1", [loan("Alpha", barcode: "11111111111")]),
                          data("B1", [loan("Alpha", barcode: "11111111111")]),
                          data("C1", [loan("Gamma", barcode: "33333333333")])], now: t1)
            // A1 returns its loan; B1 is not in the results at all; C1 is just refreshed.
            store.record([data("A1", []), data("C1", [loan("Gamma", barcode: "33333333333")])], now: t2)
            #expect(events(url, "A1") == [["A1", "11111111111", "Alpha", "0", s1, s1, "2027-09-19", s2]])
            #expect(events(url, "B1") == [["B1", "11111111111", "Alpha", "1", s1, s1, "2027-09-19", "NULL"]])
            #expect(events(url, "C1") == [["C1", "33333333333", "Gamma", "1", s1, s2, "2027-09-19", "NULL"]])
        }
    }

    @Test func reborrowCreatesNewOpenRow() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", barcode: "11111111111")])], now: t1)
            store.record([data("A1", [])], now: t2)
            store.record([data("A1", [loan("Alpha", barcode: "11111111111")])], now: t3)
            #expect(events(url, "A1") == [
                ["A1", "11111111111", "Alpha", "0", s1, s1, "2027-09-19", s2],
                ["A1", "11111111111", "Alpha", "1", s3, s3, "2027-09-19", "NULL"],
            ])
        }
    }

    @Test func loanWithoutBarcodeUsesTitleLibraryKey() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", library: "Lib A")])], now: t1)
            #expect(raw(url, "SELECT media_number FROM borrow_events;") == [["t:Alpha|Lib A"]])
        }
    }

    @Test func sameIdentityTwiceInOneRefreshIsOneRow() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", due: "01.03.2027"), loan("Alpha", due: "08.03.2027")])], now: t1)
            #expect(events(url, "A1") == [["A1", "t:Alpha|Lib A", "Alpha", "1", s1, s1, "2027-03-08", "NULL"]])
        }
    }
}

// MARK: - pickups

@Suite struct ArchivePickupTests {
    private let cols = "account_card, media_number, title, ready_until, first_seen, last_seen"
    private func rows(_ url: URL, _ card: String) -> [[String]] {
        raw(url, "SELECT \(cols) FROM pickups WHERE account_card='\(card)' ORDER BY media_number;")
    }

    @Test func nilLeavesPickupsUntouched() {
        withStore { store, url in
            store.record([data("A1", [], pickups: [pickup("Alpha", barcode: "11111111111")])], now: t1)
            store.record([data("A1", [], pickups: nil)], now: t2)
            #expect(rows(url, "A1") == [["A1", "11111111111", "Alpha", "2027-09-25", s1, s1]])
        }
    }

    @Test func listReplacesSnapshot() {
        withStore { store, url in
            store.record([data("A1", [], pickups: [pickup("Alpha", barcode: "11111111111"),
                                                    pickup("Beta", barcode: "22222222222")])], now: t1)
            store.record([data("A1", [], pickups: [pickup("Beta", barcode: "22222222222", until: "30.09.2027")])], now: t2)
            #expect(rows(url, "A1") == [["A1", "22222222222", "Beta", "2027-09-30", s1, s2]])
        }
    }

    @Test func emptyListDeletesOnlyThatAccount() {
        withStore { store, url in
            store.record([data("A1", [], pickups: [pickup("Alpha", barcode: "11111111111")]),
                          data("B1", [], pickups: [pickup("Beta", barcode: "22222222222")])], now: t1)
            store.record([data("A1", [], pickups: [])], now: t2)
            #expect(rows(url, "A1").isEmpty)
            #expect(rows(url, "B1") == [["B1", "22222222222", "Beta", "2027-09-25", s1, s1]])
        }
    }
}

// MARK: - Enrichment queries

@Suite struct ArchiveEnrichmentTests {
    @Test func mediaNeedingEnrichment() {
        withStore { store, _ in
            store.record([data("A1", [loan("Alpha", barcode: "11111111111"), loan("NoCode", library: "Lib A")])], now: t1)
            // Pinned: title-keyed ("t:…") items are listed too — only an empty media_number is excluded.
            #expect(Set(store.mediaNeedingEnrichment().map(\.mediaNumber)) == ["11111111111", "t:NoCode|Lib A"])
            store.upsertMediaDetails(mediaNumber: "11111111111", isbn: "9780000000001", coverPath: "c.jpg",
                                     detail: emptyDetail, source: "title", status: "found", recordID: "AK1")
            #expect(store.mediaNeedingEnrichment().map(\.mediaNumber) == ["t:NoCode|Lib A"])
        }
    }

    @Test func pendingISBNOverrides() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", barcode: "11111111111")])], now: t1)
            raw(url, "INSERT INTO media_isbn_override (media_number, isbn) VALUES ('11111111111','9780000000002');", write: true)
            #expect(store.pendingISBNOverrides().map(\.isbn) == ["9780000000002"])
            store.upsertMediaDetails(mediaNumber: "11111111111", isbn: "9780000000002", coverPath: "",
                                     detail: emptyDetail, source: "title", status: "found", recordID: "")
            #expect(store.pendingISBNOverrides().count == 1)   // not locked as 'manual' yet
            store.upsertMediaDetails(mediaNumber: "11111111111", isbn: "9780000000003", coverPath: "",
                                     detail: emptyDetail, source: "manual", status: "found", recordID: "")
            #expect(store.pendingISBNOverrides().count == 1)   // manual, but a different isbn
            store.upsertMediaDetails(mediaNumber: "11111111111", isbn: "9780000000002", coverPath: "",
                                     detail: emptyDetail, source: "manual", status: "found", recordID: "")
            #expect(store.pendingISBNOverrides().isEmpty)
        }
    }

    @Test func coverHealStopsAfterThreeAttempts() {
        withStore { store, _ in
            store.upsertMediaDetails(mediaNumber: "11111111111", isbn: "9780000000001", coverPath: "",
                                     detail: emptyDetail, source: "title", status: "found", recordID: "")
            store.upsertMediaDetails(mediaNumber: "22222222222", isbn: "4000000000001", coverPath: "",
                                     detail: emptyDetail, source: "title", status: "found", recordID: "")
            #expect(store.coversNeedingHeal().map(\.mediaNumber) == ["11111111111"])   // EAN key is not ISBN-shaped
            for _ in 0..<2 { store.bumpCoverAttempt(mediaNumber: "11111111111") }
            #expect(store.coversNeedingHeal().count == 1)
            store.bumpCoverAttempt(mediaNumber: "11111111111")
            #expect(store.coversNeedingHeal().isEmpty)
        }
    }

    @Test func detailBackfillUntilMarked() {
        withStore { store, url in
            store.upsertMediaDetails(mediaNumber: "11111111111", isbn: "9780000000001", coverPath: "",
                                     detail: emptyDetail, source: "title", status: "found", recordID: "")
            #expect(store.mediaNeedingDetailBackfill().isEmpty)   // written at the current version
            raw(url, "UPDATE media_details SET detail_version=3;", write: true)
            #expect(store.mediaNeedingDetailBackfill().map(\.isbn) == ["9780000000001"])
            store.markDetailBackfilled(mediaNumber: "11111111111")
            #expect(store.mediaNeedingDetailBackfill().isEmpty)
        }
    }

    @Test func fundusTablesAbsent() {
        withStore { store, _ in
            store.record([data("A1", [loan("Tonie X", barcode: "11111111111", type: "Tonie"),
                                      loan("Geraet", barcode: "22222222222", type: "Gerät")])], now: t1)
            let tonies = store.toniesNeedingImage()
            #expect(tonies.map(\.mediaNumber) == ["11111111111"])
            #expect(tonies.first?.isTonie == true)
            #expect(store.mediaNeedingRescrape().isEmpty)
        }
    }

    @Test func fundusMediaTypeOverridePullsItemIn() {
        withStore { store, url in
            store.record([data("A1", [loan("Geraet", barcode: "22222222222", type: "Gerät")])], now: t1)
            raw(url, "CREATE TABLE fundus_media_types(media_number TEXT PRIMARY KEY, media_type TEXT);", write: true)
            #expect(store.toniesNeedingImage().isEmpty)
            raw(url, "INSERT INTO fundus_media_types VALUES ('22222222222','Tonie');", write: true)
            let tonies = store.toniesNeedingImage()
            #expect(tonies.map(\.mediaNumber) == ["22222222222"])
            #expect(tonies.first?.isTonie == true)
        }
    }

    @Test func rescrapePendingOnlyWhenNewerThanFetch() {
        withStore { store, url in
            store.record([data("A1", [loan("Alpha", barcode: "11111111111"), loan("Beta", barcode: "22222222222")])], now: t1)
            store.upsertMediaDetails(mediaNumber: "11111111111", isbn: "9780000000001", coverPath: "",
                                     detail: emptyDetail, source: "title", status: "found", recordID: "")
            store.upsertMediaDetails(mediaNumber: "22222222222", isbn: "9780000000002", coverPath: "",
                                     detail: emptyDetail, source: "title", status: "found", recordID: "")
            raw(url, "CREATE TABLE fundus_rescrape(media_number TEXT PRIMARY KEY, requested_at TEXT);", write: true)
            raw(url, "INSERT INTO fundus_rescrape VALUES ('11111111111','2999-01-01T00:00:00Z'), ('22222222222','2000-01-01T00:00:00Z');", write: true)
            #expect(store.mediaNeedingRescrape().map(\.mediaNumber) == ["11111111111"])
        }
    }

    @Test func tonieImageKeepsBookFields() {
        withStore { store, url in
            let detail = HTMLParser.CatalogDetail(blurb: "Klappentext", subjects: "", systematik: "", author: "",
                                                  published: "", series: "", interessenkreis: "")
            store.upsertMediaDetails(mediaNumber: "11111111111", isbn: "4000000000001", coverPath: "",
                                     detail: detail, source: "title", status: "found", recordID: "AK1")
            store.upsertTonieImage(mediaNumber: "11111111111", coverPath: "tonie.png")
            #expect(raw(url, "SELECT isbn, blurb, source, status, cover_path, record_id FROM media_details;")
                    == [["4000000000001", "Klappentext", "tonie", "found", "tonie.png", "AK1"]])
        }
    }
}
