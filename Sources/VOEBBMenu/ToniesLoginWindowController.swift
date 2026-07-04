import AppKit
import WebKit

/// One-time my.tonies.com login in an embedded web view. The user types their password into the
/// **real** tonies login page (loaded from login.tonies.com); we only watch for the redirect back to
/// `redirect_uri` and pull the OAuth authorization code out of it — our code never sees the password.
///
/// A non-persistent data store means every login starts fresh (no lingering tonies cookies) and the
/// only thing we keep is the refresh token in the Keychain (via `ToniesAuth`).
final class ToniesLoginWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = ToniesLoginWindowController()
    private override init() {}

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pkce: ToniesAuth.PKCE?
    private var onFinish: ((Bool) -> Void)?
    private var didExchange = false

    /// Presents the login window. `completion(true)` fires once tokens are stored; `completion(false)`
    /// if the user closes the window first.
    func present(completion: @escaping (Bool) -> Void) {
        onFinish = completion
        didExchange = false
        let pkce = ToniesAuth.makePKCE()
        self.pkce = pkce

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: config)
        web.navigationDelegate = self
        webView = web

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Bei tonies anmelden"
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 380, height: 480)
        win.contentView = web
        window = win

        web.load(URLRequest(url: ToniesAuth.authorizeURL(pkce: pkce)))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              let verifier = pkce?.verifier,
              let code = ToniesAuth.authorizationCode(from: url) else {
            decisionHandler(.allow)
            return
        }

        // Redirect back to our redirect_uri carrying the code: stop here (don't let the tonies SPA
        // load and consume the single-use code) and exchange it ourselves with our PKCE verifier.
        decisionHandler(.cancel)
        didExchange = true
        Task {
            let ok = (try? await ToniesAuth.exchange(code: code, verifier: verifier)) != nil
            await MainActor.run { self.finish(success: ok) }
        }
    }

    // MARK: - Finish / cleanup

    private func finish(success: Bool) {
        let completion = onFinish
        onFinish = nil
        window?.delegate = nil
        window?.close()
        window = nil
        webView = nil
        pkce = nil
        if !success && didExchange {
            let alert = NSAlert()
            alert.messageText = "Anmeldung fehlgeschlagen"
            alert.informativeText = "Die Verbindung zu tonies konnte nicht hergestellt werden. Bitte erneut versuchen."
            alert.runModal()
        }
        completion?(success)
    }

    func windowWillClose(_ notification: Notification) {
        // User closed the window before finishing.
        guard !didExchange else { return }
        let completion = onFinish
        onFinish = nil
        window = nil
        webView = nil
        pkce = nil
        completion?(false)
    }
}
