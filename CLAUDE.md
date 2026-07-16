# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS menu bar (status item) app that shows loan/due-date info from VÖBB (Verbund der Öffentlichen Bibliotheken Berlins) for one or more library cards. Pure AppKit, no SwiftUI, no Xcode project — built entirely via Swift Package Manager. Runs as an accessory app (`LSUIElement`, no Dock icon).

## Build & run

```
swift build                 # debug build
swift build -c release      # release build
```

To produce a runnable `.app` bundle:

```
./build_app.sh
open VOEBBMenu.app
```

`build_app.sh` builds the release binary, assembles `VOEBBMenu.app/Contents/{MacOS,Resources}`, and writes `Info.plist` (bundle id `de.voebb.menubar`, `LSUIElement=true`, min macOS 13). It also tries to copy an icon from a hardcoded path (`/Users/nicolasoestreich/Desktop/icon.icns`) — silently skipped if that path doesn't exist on the current machine.

`swift test` currently fails with "no tests found" — `Tests/VOEBBMenuTests` exists (Swift Testing framework, one empty stub) but `Package.swift` only declares the executable target, no test target. If you add real tests, wire up a `testTarget` in `Package.swift` first.

No linter/formatter is configured.

## Architecture

### Entry point
`main.swift` sets `.accessory` activation policy and hands off to `AppDelegate`, which owns a single `StatusBarController` and wires it to `PreferencesWindowController.shared`.

### VOEBBSession — screen-scraping client (`VOEBBService.swift`)
This is the core and most fragile part of the app. VÖBB's site (`aDISWeb`, an ADIS-based legacy system) is a form-based, session-driven web app with no public API — there is no DOM parser, everything is regex-based HTML scraping (`HTMLParser.swift`).

- `login()` scrapes a session ID out of an HTML form action, POSTs a nav request, then POSTs credentials.
- `navigate()` "changes pages" by re-POSTing the current page's hidden `<input>` fields plus a `selected` field encoding a nav code (e.g. `*SZA` = loans list, `*SGG` = fees).
- Parsing relies on VÖBB's markup (row class `rTable_tr`, literal status substrings like `"nicht verlängerbar"`). It has broken before when VÖBB changed its markup — see commits `54e9f39` and `bff5340`. Any change to `HTMLParser.swift` or the nav-code POSTs should be treated as coupled to VÖBB's current HTML, not a stable contract.
- Loan-row columns are parsed **by position** (`td[0]`=checkbox, `td[1]`=due date, `td[2]`=library, `td[3]`=title, `td[4]`=status), NOT by td class: cells with red hints (Vormerkung, "nicht verlängerbar") use class `zellef` instead of `rTable_td_text`, so class-based filtering silently drops exactly the rows that carry problems.

### Renewal flow
Both VÖBB renewal buttons ("Alle verlängern" and "Markierte Medien verlängern") abort the **entire batch** if any selected loan is blocked (e.g. by a hold/"Vormerkung"). `renewAllLoans()` therefore runs a two-step flow: first probe renewability via "Markierte Medien verlängerbar?" (`$Button$2`, read-only), then submit only the confirmed-renewable checkboxes via "Markierte Medien verlängern" (`$Button$1`). Button-field ↔ action mapping was reverse-engineered from live HTML; buttons are position-numbered (`$Button$0` = Alle verlängern). The result is a `RenewalOutcome` (renewed + blocked incl. per-item reason).

### Storage
- `AccountStorage` (UserDefaults key `voebb_accounts_v1`) — account metadata (name + card number), the refresh interval (`voebb_refresh_interval_hours`, constrained to `AccountStorage.availableRefreshIntervalsHours`), and the "due soon" threshold in days for the per-account "Fällige verlängern" action (`voebb_renewal_due_days`, constrained to `availableRenewalDueDays`).
- `KeychainHelper` — passwords, keyed by card number, Keychain service `de.voebb.menubar`. Passwords never touch UserDefaults.
- The bundle id `de.voebb.menubar` is shared between `KeychainHelper`'s service name and `Info.plist` — if one changes, existing saved passwords become unreachable via Keychain lookup.

### Archive & enrichment layer (feeds the companion app Fundus)

This fork adds an archive layer on top of the loan scraping. It shares **one SQLite file** with the
reader app **Fundus** (`/Users/tim/Github/Fundus`) — no shared code, no IPC. `ArchiveStore` is the
entire contract.

- **`ArchiveStore` (`ArchiveStore.swift`)** — `~/Library/Application Support/de.voebb.menubar/archive.sqlite`
  (WAL). On each successful refresh, `record()` upserts current loans into `borrow_events` and
  reconciles returns (open rows of a **successfully fetched** account no longer seen → `is_open=0`;
  an account with a fetch *error* is skipped entirely, never mass-closed). voebbar owns and writes
  `borrow_events` and `media_details`; Fundus reads them and adds its own `fundus_*` tables to the
  same DB. The only thing voebbar reads back from Fundus is **`media_isbn_override`** — it does not
  read any `fundus_*` table.
- **Enrichment runs after each refresh**, orchestrated in `StatusBarController.refresh()`:
  first `CatalogEnricher.enrichMissing()`, then `ToniesEnricher.enrichMissing()`.
  - **`CatalogEnricher`** — anonymous scrape of VÖBB's **public catalog** (`www.voebb.de/aDISWeb`,
    same fragile aDIS form/session mechanics as `VOEBBService`). Strictly **incremental**: only items
    with no `media_details` row yet. Three passes: pending `media_isbn_override`s (search by ISBN,
    lock `source='manual'`), then new items (search by **title**, `source='title'`), then a one-time
    Vollanzeige backfill for older `detail_version`s. A successful-but-empty search records
    `status='notfound'` so it is never re-crawled; a network error leaves the item for a later run.
  - **`ToniesEnricher`** — Tonie cover images from **my.tonies.com** (GraphQL, OAuth via
    `ToniesAuth`, one call per refresh). The Tonie chip id is unrelated to the VÖBB barcode, so the
    only join is a **fuzzy title-token match** (`ToniesEnricher.tokens` / `bestMatch`, confident hits
    only; unmatched candidates are *not* locked as notfound). Sets `source='tonie'`.
- **The Tonie-image gate:** `ArchiveStore.toniesNeedingImage()` selects candidates by the raw VÖBB
  `borrow_events.media_type` (`= 'Tonie'` OR `LIKE '%Hörbuch%'` OR `LIKE '%CD%'`). A Tonie that VÖBB
  catalogues under any other type (e.g. **`Gerät`**) would otherwise never enter the Tonie image pass
  and only get the coverless `source='title'` catalog record. To cover that, the query **also**
  honours a Fundus media-type correction: it LEFT JOINs the Fundus-owned `fundus_media_types` and
  includes rows whose override is `'Tonie'`. The join is added only when that table exists (guarded
  via `tableExists`), so a DB without Fundus behaves exactly as before instead of failing `prepare`.
  The override is purely additive — it can pull an item into the pass, never remove one VÖBB already
  types as a Tonie. (A match still requires the Tonie to be in the user's my.tonies.com collection.)

### UI controllers
All windows are built by hand with explicit `NSRect` frames (no `.xib`/storyboard, minimal Auto Layout) — adjusting one element's position usually means recomputing the y-coordinates of everything below/above it in the same window.

- `StatusBarController` — the `NSStatusItem` and its dropdown menu (per-account submenus, refresh/renew actions, auto-refresh timer).
- `PreferencesWindowController` (singleton) — account add/remove, plus two symmetric settings rows of custom pill-style `NSButton`s (built by hand via `makePillRow`/`stylePills`, not `NSSegmentedControl`): refresh interval and renewal "due soon" threshold.
- `OverviewWindowController` (singleton) — sortable table of all loans across all accounts.

### Data flow
`StatusBarController.refresh()` reads accounts from `AccountStorage`, creates one `VOEBBSession` per account (fresh `URLSessionConfiguration.ephemeral`, no cookie persistence across sessions), fetches `AccountData` for each, then updates the status bar menu and pushes results into `OverviewWindowController`.
