import XCTest
@testable import Bell

// Gmail: everything testable without a Google account. The network calls
// themselves can only be checked by signing in on a device.

final class GmailOAuthTests: XCTestCase {

    private let clientID = "1234-abcdef.apps.googleusercontent.com"

    func testRedirectSchemeIsTheReversedClientID() {
        XCTAssertEqual(GmailOAuth.redirectScheme(for: clientID), "com.googleusercontent.apps.1234-abcdef")
        XCTAssertEqual(GmailOAuth.redirectURI(for: clientID), "com.googleusercontent.apps.1234-abcdef:/oauth2redirect")
        XCTAssertNil(GmailOAuth.redirectScheme(for: "not-a-client-id"), "A web client ID won't work on iOS")
    }

    /// The test vector from RFC 7636, appendix B.
    func testPKCEChallengeMatchesTheRFC() {
        XCTAssertEqual(GmailOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifiersAreURLSafeAndUnique() {
        let a = GmailOAuth.makeVerifier(), b = GmailOAuth.makeVerifier()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertGreaterThanOrEqual(a.count, 43, "RFC 7636 minimum")
    }

    func testAuthorizationURLAsksForReadOnlyOfflineAccess() throws {
        let url = try XCTUnwrap(GmailOAuth.authorizationURL(clientID: clientID, verifier: "v", state: "s"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["scope"], "https://www.googleapis.com/auth/gmail.readonly")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["access_type"], "offline", "Without it there's no refresh token")
        XCTAssertEqual(items["state"], "s")
        XCTAssertEqual(items["response_type"], "code")
    }

    func testTokenResponseAndRefreshTokenCarriedForward() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let first = try GmailOAuth.tokens(from: Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3599}"#.utf8), now: now)
        XCTAssertEqual(first, .init(accessToken: "a1", refreshToken: "r1", expiresAt: now.addingTimeInterval(3599)))

        let refreshed = try GmailOAuth.tokens(from: Data(#"{"access_token":"a2","expires_in":3599}"#.utf8),
                                              now: now, keepingRefresh: "r1")
        XCTAssertEqual(refreshed.refreshToken, "r1", "Google omits it on refresh; losing it means signing in hourly")
    }

    /// Testing-mode apps lose their refresh token after 7 days. That must
    /// read as "sign in again", not as a generic failure.
    func testExpiredGrantIsItsOwnError() {
        XCTAssertThrowsError(try GmailOAuth.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8))) {
            XCTAssertEqual($0 as? GmailError, .signInExpired)
        }
        XCTAssertThrowsError(try GmailOAuth.tokens(from: Data(#"{"error":"invalid_client","error_description":"bad"}"#.utf8))) {
            XCTAssertEqual($0 as? GmailError, .google("bad"))
        }
    }
}

final class GmailParsingTests: XCTestCase {

    private func b64(_ s: String) -> String { GmailOAuth.base64URL(Data(s.utf8)) }

    func testPlainTextIsFoundInsideNestedMultipart() throws {
        let json = """
        {"id":"m1","internalDate":"1730000000000","payload":{"mimeType":"multipart/mixed",
         "headers":[{"name":"Subject","value":"ECE 302 midterm moved"},{"name":"From","value":"Prof <p@purdue.edu>"}],
         "parts":[{"mimeType":"multipart/alternative","parts":[
           {"mimeType":"text/html","body":{"data":"\(b64("<p>HTML</p>"))"}},
           {"mimeType":"text/plain","body":{"data":"\(b64("Now Nov 12 at 7pm in MSEE 180."))"}}]}]}}
        """
        let message = try XCTUnwrap(GmailParsing.message(from: Data(json.utf8)))
        XCTAssertEqual(message.subject, "ECE 302 midterm moved")
        XCTAssertEqual(message.body, "Now Nov 12 at 7pm in MSEE 180.")
        XCTAssertEqual(message.received, Date(timeIntervalSince1970: 1_730_000_000))
        XCTAssertTrue(message.captureText.hasPrefix("ECE 302 midterm moved\n\nNow Nov 12"))
    }

    func testHTMLOnlyMailIsStripped() {
        let html = "<style>p{}</style><p>Interview&nbsp;on <b>Friday</b> at 2pm</p><br>Room &amp; floor"
        XCTAssertEqual(GmailParsing.stripHTML(html), "Interview on Friday at 2pm\nRoom & floor")
    }

    func testBase64URLWithoutPadding() {
        XCTAssertEqual(GmailParsing.decodeBase64URL(b64("Exam?>>")), "Exam?>>")
    }

    func testSeenMessagesAreNotReadTwiceAndTheMemoryIsCapped() {
        let first = GmailParsing.unseen(["a", "b"], seen: [])
        XCTAssertEqual(first.new, ["a", "b"])
        let second = GmailParsing.unseen(["b", "c"], seen: first.remembered)
        XCTAssertEqual(second.new, ["c"])
        XCTAssertEqual(GmailParsing.unseen(["x"], seen: (0 ..< 600).map(String.init), cap: 500).remembered.count, 500)
    }

    func testServerSideQueryKeepsDownloadsToLikelyMail() {
        let q = GmailParsing.query(newerThanDays: 3)
        XCTAssertTrue(q.hasPrefix("newer_than:3d"))
        XCTAssertTrue(q.contains("-category:promotions"))
        XCTAssertTrue(q.contains("midterm") && q.contains("interview"))
    }

    func testCaptureTextIsCapped() {
        let long = MailMessage(id: "x", subject: "S", from: "", received: nil, body: String(repeating: "a", count: 9000))
        XCTAssertLessThanOrEqual(long.captureText.count, 2400)
    }
}

/// The point of building on the inbox: an email is treated exactly like a
/// share-sheet capture, AI Override included.
@MainActor
final class EmailThroughInboxTests: XCTestCase {

    func testAnExamEmailIsAddedAutomaticallyAndLabelledAsEmail() async throws {
        let store = BellStore(inMemory: true)
        let processor = InboxProcessor()
        processor.usesModel = false
        let mail = MailMessage(id: "m", subject: "Midterm 2 reminder", from: "prof",
                               received: nil, body: "The midterm is on March 4, 2027 at 7:00 PM in MSEE 180.")
        await processor.process(text: mail.captureText, source: .email, store: store,
                                now: Date(timeIntervalSince1970: 1_790_000_000))

        let entry = try XCTUnwrap(store.inbox.first)
        XCTAssertEqual(entry.source, .email)
        XCTAssertTrue(entry.wasAutoAccepted)
        XCTAssertTrue(try XCTUnwrap(store.timetable.tasks.first).isAutomatic)
    }
}
