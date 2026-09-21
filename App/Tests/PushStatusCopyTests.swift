@testable import DistrictAI
@testable import DistrictModel
import XCTest

/// ⛔ EVERY STATE HERE MUST BE REACHABLE FROM THE UI. An app that discards the
/// register result and reads `lastRegistrationFailure` nowhere can register no device
/// at all and have no surface that says so.
@MainActor
final class PushStatusCopyTests: XCTestCase {
    private func subtitle(
        _ authorization: PushAuthorization,
        _ registration: PushRegistrationStatus = .notAttempted
    ) -> String {
        PushStatusCopy.subtitle(authorization: authorization, registration: registration)
    }

    // MARK: - Authorization decides first

    func testNotAskedSaysSoWithoutBlamingAnything() {
        XCTAssertEqual(subtitle(.notAsked), "Not set up on this device yet.")
    }

    /// ⚠️ THE REMEDY IS iOS SETTINGS AND THE LINE SAYS SO. Nothing in the app can undo
    /// a denial, so a line that only reported it would strand the reader.
    func testDeniedPointsAtIOSSettings() {
        XCTAssertTrue(subtitle(.denied).contains("iOS Settings"))
    }

    func testUnavailableIsDistinctFromDenied() {
        XCTAssertNotEqual(subtitle(.unavailable("boom")), subtitle(.denied))
    }

    /// ⛔ THE DETAIL NEVER REACHES THE SCREEN. `unavailable` carries an error string
    /// for diagnostics; putting it in front of a person would be a raw framework
    /// description in a settings row.
    func testUnavailableDoesNotLeakTheUnderlyingError() {
        XCTAssertFalse(subtitle(.unavailable("CFErrorDomainCFNetwork 4099")).contains("4099"))
    }

    // MARK: - Authorised is the halfway point, not the answer

    func testRegisteredIsTheOnlyReassuringLine() {
        XCTAssertEqual(
            subtitle(.authorized, .registered),
            "Allowed. This device is set up to receive calls and messages."
        )
    }

    /// ⛔ THE STATE EVERY SHIPPED BUILD WAS ACTUALLY IN: permission granted, and still
    /// no notifications. It must not read as success.
    func testAuthorisedButUnregisteredNeverClaimsItIsSetUp() {
        for registration: PushRegistrationStatus in [
            .notAttempted, .apnsRefused, .unreachable, .refused(status: 500),
        ] {
            XCTAssertNotEqual(
                subtitle(.authorized, registration),
                subtitle(.authorized, .registered),
                "\(registration) must not read like a working device"
            )
        }
    }

    func testApnsRefusalIsNamedRatherThanCalledAServerProblem() {
        XCTAssertTrue(subtitle(.authorized, .apnsRefused).contains("Apple"))
    }

    func testUnreachableBlamesTheConnection() {
        XCTAssertTrue(subtitle(.authorized, .unreachable).contains("connection"))
    }

    // MARK: - A refusal's status picks the remedy

    func testExpiredSessionAsksForASignIn() {
        for status in [401, 403] {
            XCTAssertTrue(
                subtitle(.authorized, .refused(status: status)).contains("Sign out and sign in again"),
                "HTTP \(status) is a session problem and has a specific remedy"
            )
        }
    }

    func testRateLimitSaysItWillRetryRatherThanAskingForAnything() {
        XCTAssertTrue(subtitle(.authorized, .refused(status: 429)).contains("retry"))
    }

    /// ⚠️ THE NUMBER SURVIVES ONLY WHERE THERE IS NO SPECIFIC REMEDY, because that is
    /// the case a support conversation needs it for.
    func testAnUnexplainedRefusalCarriesItsStatusCode() {
        XCTAssertTrue(subtitle(.authorized, .refused(status: 503)).contains("503"))
        XCTAssertFalse(subtitle(.authorized, .refused(status: 401)).contains("401"))
    }

    // MARK: - Mapping the repository's answer

    func testASkippedRegisterStillMeansRegistered() {
        XCTAssertEqual(PushRegistrar.status(for: .success(.alreadyRegistered)), .registered)
        XCTAssertEqual(PushRegistrar.status(for: .success(.registered)), .registered)
    }

    /// ⚠️ AN EMPTY TOKEN IS NOT A FAILURE AND NOT A SUCCESS: nothing was ever sent.
    func testNoTokenToRegisterReadsAsNoAttempt() {
        XCTAssertEqual(PushRegistrar.status(for: .success(.noTokenToRegister)), .notAttempted)
    }

    func testHttpFailureKeepsItsStatus() {
        XCTAssertEqual(
            PushRegistrar.status(for: .failure(.http(status: 429, message: nil))),
            .refused(status: 429)
        )
    }

    func testTransportFailureIsUnreachable() {
        XCTAssertEqual(PushRegistrar.status(for: .failure(.transport("offline"))), .unreachable)
    }
}
