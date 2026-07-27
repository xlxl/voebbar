import AppKit

/// Modal dialogs (confirm / result). Renewal writes to the live library account and a misclick in
/// the status menu used to submit every loan at once, so every renewal path goes through
/// `confirm` first. Anchored as a sheet when a window is given (the overview), otherwise a free
/// modal — the status menu has no window to attach to.
enum Alerts {
    /// Asks for confirmation. `confirmTitle` is the default button (Return), "Abbrechen" is the
    /// cancel button (Escape). Returns true only if the user picked the confirm button.
    @MainActor
    static func confirm(title: String, message: String, confirmTitle: String, window: NSWindow? = nil) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        let cancel = alert.addButton(withTitle: "Abbrechen")
        cancel.keyEquivalent = "\u{1b}"
        return await run(alert, window: window) == .alertFirstButtonReturn
    }

    /// Shows a result / error message with a single OK button.
    @MainActor
    static func info(title: String, message: String, window: NSWindow? = nil) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        _ = await run(alert, window: window)
    }

    @MainActor
    private static func run(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        // Accessory app: without activating, the modal can end up behind other apps' windows.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
