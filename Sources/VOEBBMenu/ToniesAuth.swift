import Foundation
import CryptoKit

/// OAuth2 (Keycloak, Authorization-Code + PKCE) client for my.tonies.com.
///
/// The user logs in **once** in an embedded web view (see `ToniesLoginWindowController`); we only
/// ever see the returned authorization code, never the password. We exchange it for tokens and keep
/// the long-lived **refresh token** in voebbar's own Keychain. Every enrichment run then trades the
/// refresh token for a short-lived access token (5 min) — no further login while the refresh token
/// stays valid (~180 days). Refresh tokens rotate on each use, so we re-store after every refresh.
enum ToniesAuth {
    static let clientID = "my-tonies"
    static let redirectURI = "https://my.tonies.com/login"
    private static let authBase = "https://login.tonies.com/auth/realms/tonies/protocol/openid-connect"
    private static let keychainAccount = "tonies_refresh_token"

    // MARK: - Connection state

    static var isConnected: Bool { KeychainHelper.load(for: keychainAccount) != nil }

    static func disconnect() { KeychainHelper.delete(for: keychainAccount) }

    // MARK: - PKCE

    /// A single login attempt's PKCE material. Keep the verifier alive until the code is exchanged.
    struct PKCE {
        let verifier: String
        let challenge: String
        let state: String
    }

    static func makePKCE() -> PKCE {
        let verifier = base64URL(randomBytes(64))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge, state: base64URL(randomBytes(16)))
    }

    /// The Keycloak authorize URL to load in the login web view. `response_mode=fragment` matches
    /// what my.tonies.com uses (the code comes back in the URL fragment).
    static func authorizeURL(pkce: PKCE) -> URL {
        var comps = URLComponents(string: "\(authBase)/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "response_mode", value: "fragment"),
            .init(name: "scope", value: "openid"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state),
        ]
        return comps.url!
    }

    /// Extracts the `code` from a redirect back to `redirect_uri`. Keycloak returns it in the
    /// fragment (`#...code=...`) here, but we also accept a query for robustness. Returns nil for
    /// any other URL so the web view keeps navigating (login page, consent, etc.).
    /// The returned `state` must match the one we sent (CSRF guard) — a mismatch yields nil.
    static func authorizationCode(from url: URL, expectedState: String) -> String? {
        guard url.absoluteString.hasPrefix(redirectURI) else { return nil }
        for part in [url.fragment, url.query] {
            guard let part else { continue }
            var comps = URLComponents()
            comps.percentEncodedQuery = part
            guard let items = comps.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { continue }
            if let state = items.first(where: { $0.name == "state" })?.value, state != expectedState {
                return nil   // someone else's redirect — never exchange a foreign code
            }
            return code
        }
        return nil
    }

    // MARK: - Token exchange / refresh

    /// Exchanges the authorization code for tokens and persists the refresh token. Throws on failure.
    static func exchange(code: String, verifier: String) async throws {
        let form = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        let token = try await postToken(form)
        KeychainHelper.save(password: token.refreshToken, for: keychainAccount)
    }

    /// Trades the stored refresh token for a fresh access token, rotating and re-storing the
    /// refresh token. Returns nil if refreshing isn't possible right now. The stored token is
    /// cleared ONLY when the server rejects it (invalid_grant → expired/revoked) — a transient
    /// failure (offline, 5xx) keeps it, so being offline never forces a re-login.
    /// Never throws, so an enrichment run degrades gracefully.
    static func freshAccessToken() async -> String? {
        guard let refresh = KeychainHelper.load(for: keychainAccount) else { return nil }
        let form = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refresh,
        ]
        do {
            let token = try await postToken(form)
            KeychainHelper.save(password: token.refreshToken, for: keychainAccount)
            return token.accessToken
        } catch TokenError.invalidGrant {
            // The token itself is dead: drop it so the UI shows "not connected" instead of
            // retrying a dead token forever.
            KeychainHelper.delete(for: keychainAccount)
            return nil
        } catch {
            return nil   // transient (network/server) — keep the token, skip this run
        }
    }

    private struct Token { let accessToken: String; let refreshToken: String }

    /// How a token request failed: `invalidGrant` = the server rejected the grant/token itself
    /// (HTTP 400/401), everything else (network, 5xx, unparsable body) is `transient`.
    enum TokenError: Error { case invalidGrant, transient }

    private static func postToken(_ form: [String: String]) async throws -> Token {
        var req = URLRequest(url: URL(string: "\(authBase)/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            throw TokenError.transient
        }
        guard let http = response as? HTTPURLResponse else { throw TokenError.transient }
        guard http.statusCode == 200 else {
            throw (http.statusCode == 400 || http.statusCode == 401) ? TokenError.invalidGrant : TokenError.transient
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw TokenError.transient
        }
        return Token(accessToken: access, refreshToken: refresh)
    }

    // MARK: - Helpers

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
