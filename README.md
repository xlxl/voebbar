# voebbar

macOS-Menüleisten-App (AppKit, Swift Package Manager, macOS 13+) für die Ausleihen des
**VÖBB** (Verbund der Öffentlichen Bibliotheken Berlins). Zeigt Ausleihen, Fälligkeiten und
Gebühren mehrerer Bibliothekskarten und verlängert auf Wunsch.

> Fork von [noestreich/voebbar](https://github.com/noestreich/voebbar). Dieser Fork erweitert
> die App um eine **Archiv-/Anreicherungs-Schicht**, die die Begleit-App
> [Fundus](https://github.com/xlxl/Fundus) speist. Die allgemeinen Verlängern-/Refresh-
> Verbesserungen liegen als PR beim Original.

## Bauen & starten

```sh
swift build              # Debug
./build_app.sh           # baut, signiert, deployt nach /Applications und startet von dort
DEPLOY=0 ./build_app.sh  # nur bauen, nicht deployen
```

Läuft als Accessory-App (`LSUIElement`, kein Dock-Icon). Passwörter liegen im macOS-Schlüsselbund,
nie in UserDefaults.

`build_app.sh` startet die App bewusst immer vom **selben** Pfad (`/Applications/VOEBBMenu.app`,
via `DEPLOY_DIR` änderbar) und löscht die Kopie im Repo: Die Schlüsselbund-Freigabe („Immer
erlauben") hängt nicht nur an der Signatur (`VOEBBMenu Dev`), sondern auch am Startpfad — ein aus
dem Repo gestartetes Bundle gilt als andere App und fragt erneut nach den gespeicherten Passwörtern.

## Funktionen

**Ausleihen & Verlängern**
- Übersicht pro Konto in der Menüleiste: Anzahl Ausleihen, nächste Fälligkeit (farbcodiert),
  Gebühren; sortierbares Gesamtfenster über alle Konten.
- Aufschlüsselung „Nach Bibliothek" – wie viele Medien vor der Abgabe je Standort herauszusuchen
  sind.
- Zwei-Schritt-Verlängerung (erst Verlängerbarkeit prüfen, dann nur die verlängerbaren
  einreichen), weil VÖBB sonst die ganze Aktion abbricht, sobald ein Titel gesperrt ist.
- Benachrichtigungen bei bald fälligen/überfälligen Medien (abschaltbar).
- Konfigurierbares Auto-Refresh-Intervall und „fällig in ≤ N Tagen"-Schwelle.

**Archiv & Anreicherung (für Fundus)**
- Schreibt jede Ausleihe in eine geteilte SQLite-DB
  (`~/Library/Application Support/de.voebb.menubar/archive.sqlite`) und rekonzilliert Rückgaben.
- Reichert Bücher aus dem **öffentlichen VÖBB-Katalog** an: ISBN, Cover, Klappentext,
  Schlagwörter, Autor(en), Jahr, Reihe (strikt inkrementell, nur neue Items).
- **Tonie-Bilder** von my.tonies.com: einmaliger OAuth-Login (Passwort nie im Code, Refresh-Token
  im Schlüsselbund), Fuzzy-Titel-Match, Cover in den geteilten Cache.
- Fortschrittsanzeige im Menüleisten-Symbol während der Anreicherung.
- Parse-Fehler-Monitor: wird die Ausleihen-Seite unlesbar (VÖBB-Markup geändert), meldet die App
  einen Fehler statt fälschlich alle Ausleihen als zurückgegeben zu schließen – die Historie
  bleibt geschützt.

## Architektur (Kurz)

Reines HTML-Scraping der aDIS-Weboberfläche (`VOEBBService`/`HTMLParser`), kein öffentliches API →
gekoppelt an VÖBBs aktuelles Markup. `StatusBarController` steuert Statusitem, Menü und
Refresh-Timer. `ArchiveStore` ist der einzige Vertrag mit Fundus (geteilte DB, keine gemeinsamen
Code-Pfade). Siehe `CLAUDE.md` für Details.
