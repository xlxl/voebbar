import Foundation

/// Shared progress of the background enrichment (catalog crawl + Tonie images), so the status item
/// can show "k/N" while it runs. The enrichers write from a background task; the status bar reads on
/// the main thread — all mutations hop to main via `DispatchQueue.main.async`, so no locking is
/// needed and `onChange` always fires on the main thread.
final class EnrichmentProgress {
    static let shared = EnrichmentProgress()
    private init() {}

    private(set) var phase = ""
    private(set) var done = 0
    private(set) var total = 0
    private(set) var active = false

    /// Trace of the most recent run so the menu can note "N neu angereichert" afterwards — a crawl
    /// often runs during a background/timer refresh, so a purely live counter is easy to miss.
    private(set) var lastRunCount = 0
    private(set) var lastRunAt: Date?

    /// Called on the main thread whenever the progress changes.
    var onChange: (() -> Void)?

    /// A single-item crawl finishes in ~1 s; keep the counter (and its end state N/N) on screen at
    /// least this long so even a tiny re-crawl is noticeable. Only affects when the display *clears*,
    /// never the per-item `step()` updates.
    private let minVisible: TimeInterval = 3.0

    private var startedAt: Date?
    private var runActive = false
    private var generation = 0

    func start(phase: String, total: Int) {
        DispatchQueue.main.async {
            self.generation += 1
            self.phase = phase
            self.total = total
            self.done = 0
            self.active = total > 0
            self.runActive = total > 0
            self.startedAt = Date()
            self.onChange?()
        }
    }

    /// Advances the live counter immediately (no throttling/linger here — that only applies in `stop`).
    func step() {
        DispatchQueue.main.async {
            self.done += 1
            self.onChange?()
        }
    }

    func stop() {
        DispatchQueue.main.async {
            guard self.runActive else {
                // No real run this refresh cycle — just make sure we're at rest.
                if self.active { self.active = false; self.onChange?() }
                return
            }
            self.runActive = false
            if self.done > 0 {
                self.lastRunCount = self.done
                self.lastRunAt = Date()
            }

            let gen = self.generation
            let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? self.minVisible
            let remaining = max(0, self.minVisible - elapsed)
            let deactivate = { [weak self] in
                guard let self, gen == self.generation else { return } // a newer run took over
                self.active = false
                self.onChange?()
            }
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: deactivate)
            } else {
                deactivate()
            }
        }
    }
}
