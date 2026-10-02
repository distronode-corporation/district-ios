@testable import DistrictModel
import XCTest

/// Reading `districtai://handoff?state=<S>&nonce=<N>` (S33).
final class SchedulingHandoffCallbackTests: XCTestCase {
    private static let state = String(repeating: "s", count: 43)
    private static let nonce = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJ0123-_Z"

    private func url(_ text: String) -> URL {
        URL(string: text)!
    }

    func test_S33_CB_01_aWellFormedCallbackReadsBothValues() {
        let values = SchedulingHandoffCallback
            .values(in: url("districtai://handoff?state=\(Self.state)&nonce=\(Self.nonce)"))
        XCTAssertEqual(values, SchedulingHandoffCallbackValues(state: Self.state, nonce: Self.nonce))
    }

    /// ⚠️ SCHEME AND HOST ARE CASE-FOLDED, query names are not; unknown names are ignored.
    func test_S33_CB_02_caseAndExtraItems() {
        let values = SchedulingHandoffCallback.values(
            in: url("DistrictAI://HANDOFF?v=2&nonce=\(Self.nonce)&state=\(Self.state)")
        )
        XCTAssertEqual(values?.nonce, Self.nonce)
        XCTAssertNil(SchedulingHandoffCallback
            .values(in: url("districtai://handoff?STATE=\(Self.state)&nonce=\(Self.nonce)")))
    }

    /// ⛔ `districtai://auth` IS SIGN-IN AND IS NEVER A HAND-OFF CALLBACK, whatever it
    /// carries; neither is an https page or another scheme.
    func test_S33_CB_03_otherURLsAreNotCallbacks() {
        for text in [
            "districtai://auth?state=\(Self.state)&nonce=\(Self.nonce)",
            "https://handoff/?state=\(Self.state)&nonce=\(Self.nonce)",
            "https://www.distronode.com/dashboard/handoff/start?state=\(Self.state)",
            "otherapp://handoff?state=\(Self.state)&nonce=\(Self.nonce)",
            "districtai:handoff",
        ] {
            XCTAssertFalse(SchedulingHandoffCallback.isCallback(url(text)), text)
            XCTAssertNil(SchedulingHandoffCallback.values(in: url(text)), text)
        }
        XCTAssertTrue(SchedulingHandoffCallback.isCallback(url("districtai://handoff")))
    }

    /// ⛔ A MISSING OR DOUBLED VALUE IS REFUSED rather than guessed at.
    func test_S33_CB_04_missingOrDoubledValuesAreRefused() {
        for text in [
            "districtai://handoff",
            "districtai://handoff?state=\(Self.state)",
            "districtai://handoff?nonce=\(Self.nonce)",
            "districtai://handoff?state=\(Self.state)&state=\(Self.state)&nonce=\(Self.nonce)",
            "districtai://handoff?state=\(Self.state)&nonce=\(Self.nonce)&nonce=\(Self.nonce)",
            "districtai://handoff?state&nonce=\(Self.nonce)",
        ] {
            XCTAssertNil(SchedulingHandoffCallback.values(in: url(text)), text)
        }
    }

    func test_S33_CB_05_malformedValuesAreRefused() {
        let shortNonce = String(Self.nonce.dropLast())
        let badNonce = String(Self.nonce.dropLast()) + "."
        for text in [
            "districtai://handoff?state=short&nonce=\(Self.nonce)",
            "districtai://handoff?state=\(Self.state)&nonce=\(shortNonce)",
            "districtai://handoff?state=\(Self.state)&nonce=\(badNonce)",
            "districtai://handoff?state=\(Self.state)&nonce=",
        ] {
            XCTAssertNil(SchedulingHandoffCallback.values(in: url(text)), text)
        }
    }

    /// The server's state rule: 16 to 256 characters of `[A-Za-z0-9._~-]`.
    func test_S33_CB_06_theStateRule() {
        XCTAssertTrue(SchedulingHandoffCallback.isValidState(String(repeating: "a", count: 16)))
        XCTAssertTrue(SchedulingHandoffCallback.isValidState(String(repeating: "Z", count: 256)))
        XCTAssertTrue(SchedulingHandoffCallback.isValidState("aZ09.-_~aZ09.-_~"))
        XCTAssertFalse(SchedulingHandoffCallback.isValidState(String(repeating: "a", count: 15)))
        XCTAssertFalse(SchedulingHandoffCallback.isValidState(String(repeating: "a", count: 257)))
        XCTAssertFalse(SchedulingHandoffCallback.isValidState("aaaaaaaaaaaaaaa+"))
        XCTAssertFalse(SchedulingHandoffCallback.isValidState("aaaaaaaaaaaaaaa/"))
        XCTAssertFalse(SchedulingHandoffCallback.isValidState("aaaaaaaaaaaaaaaé"))
    }

    /// The server's nonce rule: exactly 43 base64url characters.
    func test_S33_CB_07_theNonceRule() {
        XCTAssertTrue(SchedulingHandoffCallback.isValidNonce(Self.nonce))
        XCTAssertFalse(SchedulingHandoffCallback.isValidNonce(Self.nonce + "A"))
        XCTAssertFalse(SchedulingHandoffCallback.isValidNonce(String(repeating: "~", count: 43)))
        XCTAssertFalse(SchedulingHandoffCallback.isValidNonce(String(repeating: "=", count: 43)))
    }
}
