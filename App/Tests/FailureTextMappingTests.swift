@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import XCTest

/// Every refusal the client can meet, mapped to the sentence and the one offer a failure screen
/// shows: which statuses may be retried, which send the person to sign in, and when the server's
/// own sentence wins over the app's.
final class FailureTextMappingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10nRuntime.locale = .en
    }

    private func mapped(_ status: Int, _ message: String? = nil, code: String? = nil) -> FailureText {
        FailureText.from(ApiError.http(status: status, message: message, code: code))
    }

    /// ⛔ A 401 IS A SIGN-IN, NEVER A RETRY, and the server's text does not replace the app's.
    func testUnauthorisedOffersSignIn() {
        let failure = mapped(401, "jwt expired")
        XCTAssertEqual(failure.message, SessionCopy.sessionHasEndedPlease)
        XCTAssertEqual(failure.action, .signIn)
    }

    /// The statuses a second press cannot change: no offer, the server's sentence when it sent one.
    func testRefusalsThatCannotBeRetried() {
        let cases: [(Int, String)] = [
            (402, SessionCopy.workspaceSSubscriptionNot),
            (403, SessionCopy.doNotHavePermission),
            (404, SessionCopy.noLongerAvailable),
            (410, SessionCopy.noLongerAvailable),
        ]
        for (status, fallback) in cases {
            XCTAssertEqual(mapped(status).message, fallback, "\(status) without a sentence")
            XCTAssertEqual(mapped(status).action, .none, "\(status)")
            XCTAssertEqual(mapped(status, "The server's own words.").message, "The server's own words.", "\(status)")
        }
    }

    /// ⚠️ A 5XX IS THE SERVICE'S FAULT: the app's sentence, never the server's internals, and a retry.
    func testServerFaultsAreRetriedInTheAppsWords() {
        for status in [500, 502, 503, 599] {
            let failure = mapped(status, "TypeError: cannot read property 'id' of undefined")
            XCTAssertEqual(failure.message, SessionCopy.somethingWentWrongOur, "\(status)")
            XCTAssertEqual(failure.action, .retry, "\(status)")
        }
    }

    /// Any other status is retryable, with the server's sentence when there is one.
    func testOtherStatusesAreRetried() {
        XCTAssertEqual(mapped(409).message, SessionCopy.requestCouldNotCompleted)
        XCTAssertEqual(mapped(429, "Slow down.").message, "Slow down.")
        XCTAssertEqual(mapped(400).action, .retry)
        XCTAssertEqual(mapped(0).action, .retry, "a status nothing names still offers a retry")
    }

    /// ⛔ OFFLINE KEEPS THE SESSION: a retry, and nothing that implies signing in again.
    func testATransportFailureIsOffline() {
        let failure = FailureText.from(ApiError.transport("The Internet connection appears to be offline."))
        XCTAssertEqual(failure.message, SessionCopy.appearOfflineCheckConnection)
        XCTAssertEqual(failure.action, .retry)
    }

    /// ⛔ A SHAPE THIS BUILD CANNOT READ IS NOT CONNECTIVITY: no retry, which could never fix it.
    func testADecodingFailureIsTheAppsVersion() {
        let failure = FailureText.from(ApiError.decoding("keyNotFound"))
        XCTAssertEqual(failure.message, SessionCopy.versionAppCouldNot)
        XCTAssertEqual(failure.action, .none)
    }

    /// In French, a code the catalog knows reads the catalog's sentence rather than the server's English.
    func testFrenchReadsTheCatalogsSentenceForAKnownCode() {
        L10nRuntime.locale = .frCA
        defer { L10nRuntime.locale = .en }
        let failure = mapped(429, "Too many requests.", code: "rate_limited")
        XCTAssertEqual(failure.message, ApiErrorText.sentence(for: "rate_limited"))
        XCTAssertNotEqual(failure.message, "Too many requests.")
    }

    // MARK: - The workspace list

    func testUnreachableRegionsAreNamedInCapitals() {
        let failure = FailureText.from(WorkspaceListError.regionsDegraded(message: nil, regions: ["eu", "apac"]))
        XCTAssertEqual(failure.message, SessionCopy.degradedNamedRegions("EU, APAC"))
        XCTAssertEqual(failure.action, .retry)
    }

    func testUnreachableRegionsWithNoneNamedSayEveryRegion() {
        let failure = FailureText.from(WorkspaceListError.regionsDegraded(message: "ignored", regions: []))
        XCTAssertEqual(failure.message, SessionCopy.degradedEveryRegion)
    }

    func testAnyOtherListFailureIsTheApiMapping() {
        let failure = FailureText.from(WorkspaceListError.api(.http(status: 401, message: nil)))
        XCTAssertEqual(failure.action, .signIn)
    }
}
