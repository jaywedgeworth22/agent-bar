import XCTest
@testable import QuotaCore

/// A token pasted out of a shell export or a JSON file arrives quoted, and a
/// quoted bearer is rejected as unauthorized with nothing on screen to say why.
final class TokenHygieneTests: XCTestCase {
    func testMatchedQuotesAreStrippedAfterWhitespace() {
        XCTAssertEqual(sanitizedToken("  \"abc123\"  "), "abc123")
        XCTAssertEqual(sanitizedToken("'abc123'"), "abc123")
        XCTAssertEqual(sanitizedToken("\n\tabc123\n"), "abc123")
        XCTAssertEqual(sanitizedToken("\"'abc123'\""), "abc123")
        XCTAssertEqual(sanitizedToken("\" abc123 \""), "abc123")
    }

    func testUnbalancedOrInteriorQuotesAreLeftAlone() {
        // An unbalanced quote could be part of the credential, so it stays.
        XCTAssertEqual(sanitizedToken("\"abc123"), "\"abc123")
        XCTAssertEqual(sanitizedToken("abc123\""), "abc123\"")
        XCTAssertEqual(sanitizedToken("ab\"c123"), "ab\"c123")
        XCTAssertEqual(sanitizedToken("'abc123\""), "'abc123\"")
        XCTAssertEqual(sanitizedToken(""), "")
        XCTAssertEqual(sanitizedToken("\""), "\"")
    }

    func testAQuotedTokenIsAcceptedAndAnEmptyOneIsStillRejected() async throws {
        let endpoint = URL(string: "https://example.com/api/quota-windows")!
        // A quoted token used to be sent verbatim; now it builds a client.
        _ = try QuotaClient(endpoint: endpoint, token: "\"abc123\"")
        // A token that is only quotes is empty once cleaned, and stays invalid.
        XCTAssertThrowsError(try QuotaClient(endpoint: endpoint, token: "\"\"")) { error in
            XCTAssertEqual(error as? QuotaClientError, .invalidToken)
        }
    }

    func testUnauthorizedCopyNamesTheCredentialToCheck() {
        XCTAssertEqual(QuotaClientError.unauthorized.errorDescription,
                       "Unauthorized (HTTP 401)." + sentenceGap + "Check your Read Token.")
        XCTAssertEqual(QuotaPublisherError.unauthorized.errorDescription,
                       "Unauthorized (HTTP 401)." + sentenceGap + "Check your Ingest Token.")
        XCTAssertEqual(sentenceGap, "\u{00A0} ")
    }
}
