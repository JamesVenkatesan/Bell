import AuthenticationServices
import CryptoKit
import Foundation

// Reading Gmail, the one part of Bell that needs something registered with
// someone else.
//
// Everything else in Bell runs without API keys. This can't: Google only
// lets an app read mail through OAuth, with a client ID registered in a
// Google Cloud project. It's kept apart on purpose: off unless set up, the
// client ID typed in by the user rather than compiled in, tokens in the
// Keychain, and messages going through the same inbox pipeline as anything
// shared by hand. If this file were deleted, nothing else would notice.
//
// No Google SDK: an iOS OAuth client with PKCE has no secret, and the whole
// protocol is two HTTPS calls, so a dependency would add more than it saves.

// MARK: - Protocol pieces (pure)

enum GmailOAuth {

    static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// "1234-abc.apps.googleusercontent.com" becomes the redirect scheme
    /// "com.googleusercontent.apps.1234-abc". Google requires exactly this
    /// for iOS clients; it's how a sign-in finds its way back to the app.
    static func redirectScheme(for clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let id = clientID.dropLast(suffix.count)
        guard !id.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(id)"
    }

    static func redirectURI(for clientID: String) -> String? {
        redirectScheme(for: clientID).map { "\($0):/oauth2redirect" }
    }

    /// RFC 7636: the challenge is base64url(SHA256(verifier)).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(clientID: String, verifier: String, state: String) -> URL? {
        guard let redirect = redirectURI(for: clientID) else { return nil }
        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // Without these two Google returns no refresh token, and the
            // user would have to sign in again every hour.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return components?.url
    }

    struct Tokens: Codable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date

        var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }
    }

    /// Google's token response. The refresh token is absent on refreshes,
    /// so the previous one is carried forward rather than lost.
    static func tokens(from data: Data, now: Date = .now, keepingRefresh previous: String? = nil) throws -> Tokens {
        struct Response: Decodable {
            var access_token: String?
            var refresh_token: String?
            var expires_in: Double?
            var error: String?
            var error_description: String?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let error = response.error {
            // invalid_grant on refresh is the 7-day testing-mode expiry: the
            // only fix is signing in again, so it gets its own case.
            throw error == "invalid_grant" ? GmailError.signInExpired : GmailError.google(response.error_description ?? error)
        }
        guard let access = response.access_token else { throw GmailError.google("No access token in response") }
        return Tokens(accessToken: access,
                      refreshToken: response.refresh_token ?? previous,
                      expiresAt: now.addingTimeInterval(response.expires_in ?? 3600))
    }

    static func form(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

enum GmailError: LocalizedError, Equatable {
    case notConfigured
    case badClientID
    case signInExpired
    case cancelled
    case google(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Gmail isn't set up yet."
        case .badClientID: "That doesn't look like an iOS client ID. It should end in .apps.googleusercontent.com."
        case .signInExpired: "Google ended the sign-in. In testing mode this happens every 7 days; sign in again to continue."
        case .cancelled: "Sign-in was cancelled."
        case .google(let message): "Google said: \(message)"
        }
    }
}

// MARK: - Messages (pure)

/// One email, reduced to what the inbox reader needs.
struct MailMessage: Equatable {
    var id: String
    var subject: String
    var from: String
    var received: Date?
    var body: String

    /// What goes through the inbox pipeline: subject first (it's usually the
    /// summary), then the body, capped so one long newsletter can't drown
    /// the model's small context.
    var captureText: String {
        "\(subject)\n\n\(body)".prefix(2400).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum GmailParsing {

    /// Only mail that might hold a date worth knowing. The Gmail search does
    /// the filtering server-side, so Bell never downloads the rest.
    static func query(newerThanDays days: Int) -> String {
        let words = ["exam", "midterm", "final", "quiz", "deadline", "due", "interview",
                     "meeting", "\"office hours\"", "mandatory", "assignment", "rescheduled", "cancelled"]
        return "newer_than:\(days)d -category:promotions -category:social -in:chats (\(words.joined(separator: " OR ")))"
    }

    static func messageIDs(from data: Data) -> [String] {
        struct List: Decodable { struct Ref: Decodable { var id: String }; var messages: [Ref]? }
        return ((try? JSONDecoder().decode(List.self, from: data))?.messages ?? []).map(\.id)
    }

    struct Part: Decodable {
        struct Header: Decodable { var name: String; var value: String }
        struct Body: Decodable { var data: String? }
        var mimeType: String?
        var headers: [Header]?
        var body: Body?
        var parts: [Part]?
    }

    static func message(from data: Data) -> MailMessage? {
        struct Message: Decodable { var id: String; var internalDate: String?; var payload: Part? }
        guard let message = try? JSONDecoder().decode(Message.self, from: data), let payload = message.payload
        else { return nil }

        let headers = payload.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        let received = message.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        return MailMessage(id: message.id, subject: header("Subject"), from: header("From"),
                           received: received, body: bodyText(payload))
    }

    /// Plain text when the message has it; otherwise the HTML with its tags
    /// stripped. Depth-first, because multipart/alternative nests.
    static func bodyText(_ part: Part) -> String {
        if let plain = first(part, mime: "text/plain") { return plain }
        if let html = first(part, mime: "text/html") { return stripHTML(html) }
        return ""
    }

    private static func first(_ part: Part, mime: String) -> String? {
        if part.mimeType == mime, let data = part.body?.data, let text = decodeBase64URL(data) { return text }
        for child in part.parts ?? [] {
            if let found = first(child, mime: mime) { return found }
        }
        return nil
    }

    static func decodeBase64URL(_ string: String) -> String? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>|</tr>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        // Tags become spaces and block ends become newlines, so runs of both
        // pile up; one space between words and one newline between blocks
        // is all the date reader needs.
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n[\s]*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which IDs are new, and the remembered set to save. Capped, oldest
    /// first out, so it can't grow without bound over a term.
    static func unseen(_ ids: [String], seen: [String], cap: Int = 500) -> (new: [String], remembered: [String]) {
        let known = Set(seen)
        let new = ids.filter { !known.contains($0) }
        return (new, Array((seen + new).suffix(cap)))
    }
}

// MARK: - Account

/// Sign-in, tokens and fetching. Everything with a side effect lives here.
@MainActor
@Observable
final class GmailAccount: NSObject {

    private(set) var isSignedIn = Keychain.read(account: GmailAccount.tokensKey) != nil
    private(set) var address: String? = Preferences.store?.string(forKey: "gmail.address")
    private(set) var lastChecked: Date? = Preferences.store?.object(forKey: "gmail.checked") as? Date
    private(set) var lastError: String?
    private(set) var isWorking = false

    static let tokensKey = "gmail.tokens"

    /// The OAuth client this build signs in with.
    ///
    /// Not a secret: an iOS client has none, which is why the flow uses PKCE.
    /// The value ships in the binary of every OAuth iOS app and is trivially
    /// extractable, so storing it in defaults rather than the Keychain costs
    /// nothing. The tokens it produces are a different matter and do go to the
    /// Keychain.
    ///
    /// Pre-filled so a fresh install signs in without a setup detour. Anything
    /// entered in Settings overrides it, which is what makes the app usable by
    /// someone with their own Google project.
    static let defaultClientID =
        "723548621629-f12dbsudmu5khbd3ua1ivsufihcl21jo.apps.googleusercontent.com"

    static var clientID: String? {
        get {
            let stored = Preferences.store?.string(forKey: "gmail.clientID")
            if let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty { return stored }
            return defaultClientID
        }
        set { Preferences.store?.set(newValue, forKey: "gmail.clientID") }
    }

    private var tokens: GmailOAuth.Tokens? {
        get {
            Keychain.read(account: Self.tokensKey)
                .flatMap { try? JSONDecoder().decode(GmailOAuth.Tokens.self, from: Data($0.utf8)) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                Keychain.write(String(decoding: data, as: UTF8.self), account: Self.tokensKey)
            } else {
                Keychain.delete(account: Self.tokensKey)
            }
            isSignedIn = newValue != nil
        }
    }

    // MARK: Sign in

    func signIn() async {
        lastError = nil
        do {
            guard let clientID = Self.clientID, !clientID.isEmpty else { throw GmailError.notConfigured }
            guard let scheme = GmailOAuth.redirectScheme(for: clientID),
                  let redirect = GmailOAuth.redirectURI(for: clientID) else { throw GmailError.badClientID }

            let verifier = GmailOAuth.makeVerifier()
            let state = UUID().uuidString
            guard let url = GmailOAuth.authorizationURL(clientID: clientID, verifier: verifier, state: state)
            else { throw GmailError.badClientID }

            let callback = try await authenticate(url: url, scheme: scheme)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            // The state must come back unchanged, or this isn't our sign-in.
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value
            else { throw GmailError.google(items.first { $0.name == "error" }?.value ?? "No code returned") }

            tokens = try await exchange([
                "client_id": clientID, "code": code, "code_verifier": verifier,
                "grant_type": "authorization_code", "redirect_uri": redirect,
            ], keepingRefresh: nil)
            await loadAddress()
        } catch {
            lastError = (error as? GmailError)?.errorDescription ?? error.localizedDescription
        }
    }

    func signOut() async {
        if let token = tokens?.refreshToken ?? tokens?.accessToken {
            var request = URLRequest(url: GmailOAuth.revokeEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = GmailOAuth.form(["token": token])
            _ = try? await URLSession.shared.data(for: request)
        }
        tokens = nil
        address = nil
        Preferences.store?.removeObject(forKey: "gmail.address")
        Preferences.store?.removeObject(forKey: "gmail.seen")
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: GmailError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GmailError.cancelled)
                }
            }
            session.presentationContextProvider = self
            // Shares Safari's Google sign-in, so the user usually just picks
            // an account rather than typing a password.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchange(_ fields: [String: String], keepingRefresh previous: String?) async throws -> GmailOAuth.Tokens {
        var request = URLRequest(url: GmailOAuth.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GmailOAuth.form(fields)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try GmailOAuth.tokens(from: data, keepingRefresh: previous)
    }

    private func validAccessToken() async throws -> String {
        guard var current = tokens else { throw GmailError.notConfigured }
        if current.isExpired {
            guard let clientID = Self.clientID, let refresh = current.refreshToken else { throw GmailError.signInExpired }
            do {
                current = try await exchange(["client_id": clientID, "refresh_token": refresh,
                                              "grant_type": "refresh_token"], keepingRefresh: refresh)
                tokens = current
            } catch GmailError.signInExpired {
                tokens = nil
                throw GmailError.signInExpired
            }
        }
        return current.accessToken
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 { throw GmailError.signInExpired }
        return data
    }

    private func loadAddress() async {
        struct Profile: Decodable { var emailAddress: String }
        if let data = try? await get("profile"), let profile = try? JSONDecoder().decode(Profile.self, from: data) {
            address = profile.emailAddress
            Preferences.store?.set(profile.emailAddress, forKey: "gmail.address")
        }
    }

    // MARK: Checking mail

    /// Fetches recent mail that might hold a date and hands each new message
    /// to the inbox processor, exactly as a share-sheet capture would be.
    /// Returns how many messages were read.
    @discardableResult
    func check(into processor: InboxProcessor, store: BellStore, force: Bool = false) async -> Int {
        guard isSignedIn, !isWorking else { return 0 }
        // Every fifteen minutes at most: mail about an exam next week isn't
        // more useful a minute sooner, and each check is a network round trip.
        if !force, let lastChecked, Date.now.timeIntervalSince(lastChecked) < 15 * 60 { return 0 }

        isWorking = true
        defer { isWorking = false }
        do {
            let list = try await get("messages", query: [
                .init(name: "q", value: GmailParsing.query(newerThanDays: 3)),
                .init(name: "maxResults", value: "25"),
            ])
            let seen = Preferences.store?.stringArray(forKey: "gmail.seen") ?? []
            let (new, remembered) = GmailParsing.unseen(GmailParsing.messageIDs(from: list), seen: seen)

            for id in new {
                let data = try await get("messages/\(id)", query: [.init(name: "format", value: "full")])
                guard let message = GmailParsing.message(from: data) else { continue }
                await processor.process(text: message.captureText, source: .email, store: store)
            }
            Preferences.store?.set(remembered, forKey: "gmail.seen")
            lastChecked = .now
            Preferences.store?.set(lastChecked, forKey: "gmail.checked")
            lastError = nil
            return new.count
        } catch {
            lastError = (error as? GmailError)?.errorDescription ?? error.localizedDescription
            return 0
        }
    }
}

extension GmailAccount: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            // Sign-in is only started from a visible screen, so a scene exists.
            return ASPresentationAnchor(windowScene: scenes[0])
        }
    }
}
