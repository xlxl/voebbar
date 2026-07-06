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

    /// Called on the main thread whenever the progress changes.
    var onChange: (() -> Void)?

    func start(phase: String, total: Int) {
        DispatchQueue.main.async {
            self.phase = phase
            self.total = total
            self.done = 0
            self.active = total > 0
            self.onChange?()
        }
    }

    func step() {
        DispatchQueue.main.async {
            self.done += 1
            self.onChange?()
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.active = false
            self.onChange?()
        }
    }
}
