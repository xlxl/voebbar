# CLAUDE.md

## What this is

A native macOS menu bar (status item) app that shows loan/due-date info from VÖBB (Verbund der Öffentlichen Bibliotheken Berlins) for one or more library cards. Pure AppKit, no SwiftUI, no Xcode project — built entirely via Swift Package Manager. Runs as an accessory app (`LSUIElement`, no Dock icon).

## Build & run

To produce a runnable `.app` bundle:

```
./build_app.sh              # build + sign + deploy to /Applications + launch
DEPLOY=0 ./build_app.sh     # build only, leave VOEBBMenu.app in the repo
```

`build_app.sh` assembles and signs the bundle (icon source overridable with `ICON_SRC=…`, silently skipped when absent).

It then signs with a valid **`Apple Development`** cert (free Apple-ID team, Team ID `7WA5346BQ7`; picked by SHA-1 hash because an expired twin shares the name), falling back to the self-signed `VOEBBMenu Dev`, then ad-hoc (override via `SIGN_IDENTITY`), and — unless `DEPLOY=0` — quits the running instance, moves the bundle to `/Applications/VOEBBMenu.app` (`DEPLOY_DIR`), verifies the signature there, **deletes the repo copy**, and launches the deployed app. The stored VÖBB passwords / Tonies token live in the legacy Keychain, which checks three things before reading silently: the item's **ACL** (the app's designated requirement — any stable identity passes), the **launch path** (hence the single deploy location; launching the repo-local bundle re-prompts), and the **partition list**, which macOS derives from the cert's **Team ID**. A self-signed cert has no Team ID, so the partition falls back to the per-build `cdhash:` and every rebuild re-prompted despite a stable signature (the items had collected 25 cdhashes by 2026-09). Only a Team-ID cert gives a stable `teamid:` partition. The Apple Development cert expires yearly — renew it in Xcode → Einstellungen → Accounts → Manage Certificates; the build falls back to `VOEBBMenu Dev` (and prompts again) while it is expired.

`swift test` runs `Tests/VOEBBMenuTests` (Swift Testing, `@testable import VOEBBMenu`): pure-function tests for the HTML parsers, `ADISForm` helpers and the Tonie title match, on small hand-written fixtures in the live markup's shape. Never put real account data or scraped pages in fixtures. When a parser or the Tonie match changes because VÖBB/tonies.com changed, add the failing real-world case as a test first.

No linter/formatter is configured.

## Architecture

### VOEBBSession — screen-scraping client (`VOEBBService.swift`)
This is the core and most fragile part of the app. VÖBB's site (`aDISWeb`, an ADIS-based legacy system) is a form-based, session-driven web app with no public API — there is no DOM parser, everything is regex-based HTML scraping (`HTMLParser.swift`).

- `login()` scrapes a session ID out of an HTML form action, POSTs a nav request, then POSTs credentials.
- `navigate()` "changes pages" by re-POSTing the current page's hidden `<input>` fields plus a `selected` field encoding a nav code (e.g. `*SZA` = loans list, `*SE` = logout). The page's `requestCount` is echoed back unchanged (`requiredRequestCount` refuses to send without one) — never hardcode it. Every page carries a single-use identity token, so each request must start from the page loaded last — `VOEBBSession` tracks it as `currentPage` (one instance per operation, never shared). `withSession` wraps login → work → a best-effort `*SE` logout, on errors too.
- Fees, pickup code ("Abholcode"), card validity and VÖBB's card-expiry warning ("Achtung") come from the overview page's `<dt>/<dd>` list (`parseAccountInfo`), not from `*SGG`: navigating `*SGG` from the probe result page is silently ignored by aDIS and returned the loans page again (fees read as 0 €). An unrecognizable overview sets `feesUnknown` instead of reporting 0.
- Pickups ("Bereitstellungen", `*SZS`) are fetched only when the overview announces some. aDIS silently ignores a list→list navigation (after `*SZA`, `*SZS` returns the loans again), so the flow goes back via the page's "Zur Übersicht" button first (`findSubmitButton` by label — its `$Button$N` differs per page; `isOverviewPage` validates), with a fresh-session fallback. Nothing is ever pressed on the pickups page: it carries "Markierte Medien löschen". `AccountData.pickups == nil` means unknown (not fetched, or fewer rows than announced).
- `validateLoans` is the parse monitor: fewer (or no) parsed loans than the overview announces throws a `parseBrokenMarker` error instead of an empty/short list — the archive would otherwise close open loans as returned. It runs on refresh and before every renewal.
- Parsing relies on VÖBB's markup (row class `rTable_tr`, literal status substrings like `"nicht verlängerbar"`). It has broken before when VÖBB changed its markup — see commits `54e9f39` and `bff5340`. Any change to `HTMLParser.swift` or the nav-code POSTs should be treated as coupled to VÖBB's current HTML, not a stable contract.
- Loan-row columns are parsed **by position** (`td[0]`=checkbox, `td[1]`=due date, `td[2]`=library, `td[3]`=title, `td[4]`=status), NOT by td class: cells with red hints (Vormerkung, "nicht verlängerbar") use class `zellef` instead of `rTable_td_text`, so class-based filtering silently drops exactly the rows that carry problems.

### Renewal flow
Both VÖBB renewal buttons ("Alle verlängern" and "Markierte Medien verlängern") abort the **entire batch** if any selected loan is blocked (e.g. by a hold/"Vormerkung"). `renewAllLoans()` therefore runs a two-step flow: first probe renewability via "Markierte Medien verlängerbar?" (`$Button$2`, read-only), then submit only the confirmed-renewable checkboxes via "Markierte Medien verlängern" (`$Button$1`). Button-field ↔ action mapping was reverse-engineered from live HTML; buttons are position-numbered (`$Button$0` = Alle verlängern). The probe must return a marker for every submitted row, else it throws. Success is never inferred from the probe: `RenewalVerifier` diffs due dates per item on the returned loans list (by barcode, else per title+library copy group as a multiset). The result is a `RenewalOutcome` with renewed (confirmed), unconfirmed, blocked (incl. per-item reason) and `unverifiable`.

Which loans take part is a predicate on the **freshly parsed** list inside `renewLoans(password:noMatchMessage:selecting:)` — `renewAllLoans` / `renewDueLoans(withinDays:)` / `renewLoans(password:keys:)` (targeted, from the overview window's selection) are all thin wrappers around it. Targeted renewal addresses loans by `Loan.renewalKey` (the barcode, else title+due date), **never** by `checkboxValue`: that value is only valid inside the aDIS session that produced it, and a renewal logs in again.

Every renewal path goes through `Alerts.confirm` first (`Alerts.swift`; sheet when a window is passed, free modal for the status menu) and lists what is about to be submitted — a misclick in the status menu used to renew everything immediately. `StatusBarController.isRenewing` is held from the moment a renewal is triggered (dialog included) until its result is shown, and it blocks `refresh()`, so timer/`menuWillOpen` can't log in again mid-submit.

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
  reconciles returns in one transaction per refresh (open rows of a **successfully fetched** account no longer seen → `is_open=0`;
  an account with a fetch *error* is skipped entirely, never mass-closed). voebbar owns and writes
  `borrow_events` and `media_details`; Fundus reads them and adds its own `fundus_*` tables to the
  same DB. voebbar also writes **`pickups`**: a current snapshot (not history) of items ready for
  pickup, replaced per account in one transaction when that account's pickups were read; an account
  with `pickups == nil` is left untouched. Fundus shows it in its return checklist. What voebbar reads back from Fundus is **`media_isbn_override`** plus exactly two
  Fundus-owned tables — **`fundus_media_types`** (Tonie-image gate, below) and **`fundus_rescrape`**
  (manual re-crawl, below). Both are read through `tableExists` guards and never written.
- **Enrichment runs after each refresh**, orchestrated in `StatusBarController.refresh()`:
  first `CatalogEnricher.enrichMissing()`, then `ToniesEnricher.enrichMissing()`.
  - **`CatalogEnricher`** — anonymous scrape of VÖBB's **public catalog** (`www.voebb.de/aDISWeb`,
    same fragile aDIS form/session mechanics as `VOEBBService`). Normally **incremental**: only items
    with no `media_details` row yet. Five passes, in order: Fundus `fundus_rescrape` requests, then
    pending `media_isbn_override`s (search by ISBN, lock `source='manual'`), then new items (search by
    **title**, `source='title'`), then the Vollanzeige backfill for older `detail_version`s, then the
    cover self-heal. Later passes skip whatever an earlier one already covered this run. A
    successful-but-empty search records `status='notfound'`; a network error leaves the item for a
    later run. A title search walks `titleSearchTerms` (as is → rare diacritics folded → only the part
    before " / "): the loan-list title carries the full responsibility statement, and one letter the
    catalog index folds differently (e.g. "Ḥ") makes VÖBB answer "erfolglos". Title-`notfound` rows
    are retried via `mediaNeedingNotFoundRetry()` — every `notFoundRetryDays`, capped by
    `notfound_attempts < maxNotFoundAttempts` — because a single empty answer has turned out to be
    transient (a search that returned nothing on one evening found the record the next day).
  - **Cover self-heal** — a transient download miss used to freeze a row as `status='found'` with an
    empty `cover_path`, and nothing retried it (`mediaNeedingEnrichment` only picks rows that don't
    exist). `coversNeedingHeal()` re-fetches the VLB cover directly — the URL is deterministic from
    the ISBN, so no aDIS search or login is needed. Limited to ISBN-shaped keys (`isbn LIKE '97%'`)
    so Tonie EAN box codes stay with `ToniesEnricher`, and capped by `cover_attempts < 3` so a
    genuinely cover-less record isn't hit every refresh.
  - **`record_id` / permalink** — `CatalogHit.recordID` (the `data-ajax` value, e.g. `AK34420649`) is
    stored in `media_details.record_id`; Fundus builds the site's "Kopierlink"
    `…/aDISWeb/app/prod00?sp=S<record_id>` from it. `detail_version` marks the parser generation
    (4 = record_id); the backfill re-reads every found row once per generation. It deliberately
    **includes** `source='tonie'` rows: `updateDetailFields` touches neither `cover_path` nor
    `source`, so the my.tonies image survives, and a Tonie's EAN in `isbn` resolves in the catalog
    just like an ISBN. `backfillOne` distinguishes a network failure (retry later) from a
    successful-but-empty search (`markDetailBackfilled`) — otherwise such a row is re-crawled forever.
  - **`ToniesEnricher`** — Tonie cover images from **my.tonies.com** (GraphQL, OAuth via
    `ToniesAuth`, one call per refresh). The Tonie chip id is unrelated to the VÖBB barcode, so the
    only join is a **fuzzy title-token match** (`ToniesEnricher.tokens` / `bestMatch`, confident hits
    only; unmatched candidates are *not* locked as notfound). Sets `source='tonie'`. A few Tonies
    ship as a flattened product photo on white instead of the usual transparent render; when a
    downloaded cover has no alpha channel, `removeBackgroundIfFlattened` lifts the subject via Vision
    (`VNGenerateForegroundInstanceMaskRequest`, macOS 14+, best-effort) so it matches the rest.
- **The Tonie-image gate:** `ArchiveStore.toniesNeedingImage()` selects candidates by the raw VÖBB
  `borrow_events.media_type` (`= 'Tonie'` OR `LIKE '%Hörbuch%'` OR `LIKE '%CD%'`). A Tonie that VÖBB
  catalogues under any other type (e.g. **`Gerät`**) would otherwise never enter the Tonie image pass
  and only get the coverless `source='title'` catalog record. To cover that, the query **also**
  honours a Fundus media-type correction: it LEFT JOINs the Fundus-owned `fundus_media_types` and
  includes rows whose override is `'Tonie'`. The join is added only when that table exists (guarded
  via `tableExists`), so a DB without Fundus behaves exactly as before instead of failing `prepare`.
  The override is purely additive — it can pull an item into the pass, never remove one VÖBB already
  types as a Tonie. (A match still requires the Tonie to be in the user's my.tonies.com collection.)
- **Manual rescrape (`fundus_rescrape`):** Fundus flags an item for a fresh crawl (independent of any
  ISBN change) by writing `media_number` + `requested_at`. `mediaNeedingRescrape()` treats a row as
  pending only while `requested_at` is newer than that item's `media_details.fetched_at`, so a
  completed crawl retires the request on its own — voebbar **never writes back** into the
  Fundus-owned table, and the one-directional contract holds. Rescrape re-searches by the item's
  ISBN override if there is one, else by title. For a Tonie this briefly flips `source` back to
  `'title'`; `ToniesEnricher` runs afterwards in the same refresh and restores the Tonie image.

### UI controllers
All windows are built by hand with explicit `NSRect` frames (no `.xib`/storyboard, minimal Auto Layout) — adjusting one element's position usually means recomputing the y-coordinates of everything below/above it in the same window.

- `PreferencesWindowController` (singleton) — account add/remove, plus two symmetric settings rows of custom pill-style `NSButton`s (built by hand via `makePillRow`/`stylePills`, not `NSSegmentedControl`): refresh interval and renewal "due soon" threshold.
- `OverviewWindowController` (singleton) — sortable table of all loans across all accounts, with multi-row selection that can be renewed (row context menu + toolbar button, both routed through `StatusBarController.renewSelected` so menu and window share one confirm/network path). Rows keep the whole `LibraryAccount` (a selection must map back to card number + password), and every `reloadData()` remaps the selection by account+`renewalKey` — row *indexes* survive a re-sort, so without that the selection would silently point at other media.
