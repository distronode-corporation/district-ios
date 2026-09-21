import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// The setup wizard's half of the contract gate: `GET /api/district/setup`.
///
/// ⚠️ ONE FIXTURE, AND THE OTHER BRANCHES OF ``DistrictSetupResponse/needsWebSetup`` ARE
/// DERIVED FROM ITS TEXT HERE, exactly as Android's `SetupContractFixtureTest` does. A
/// pre-wizard workspace (null progress) and a finished one (completedAt set) are the same
/// body with one value changed, so deriving them keeps them honest.
final class SetupContractTests: XCTestCase {
    private func fixtureText() throws -> String {
        try XCTUnwrap(String(data: ContractFixtures.read("district-setup.json"), encoding: .utf8))
    }

    private func decode(_ text: String) throws -> DistrictSetupResponse {
        try JSONDecoder().decode(DistrictSetupResponse.self, from: Data(text.utf8))
    }

    func testTheSetupReadDecodesWithEveryKeyModelled() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-setup.json",
            as: DistrictSetupResponse.self
        )

        XCTAssertEqual(response.region, "ca")
        XCTAssertEqual(response.tier, "VoicePro")
        XCTAssertEqual(response.includedNumbers, 3)
        XCTAssertEqual(response.numbersHeld, 1)
        XCTAssertNil(response.businessFacts, "a fresh ca workspace has no business facts yet")

        let progress = try XCTUnwrap(response.setupProgress, "the fixture is a workspace IN the wizard")
        XCTAssertEqual(progress.steps?.business, "done")
        XCTAssertEqual(progress.steps?.number, "done")
        XCTAssertEqual(progress.steps?.receptionist, "todo")
        XCTAssertEqual(progress.steps?.callers, "todo")
        XCTAssertEqual(progress.steps?.calls, "todo")
        XCTAssertEqual(progress.steps?.golive, "todo")
        XCTAssertEqual(progress.paidAt, "2026-09-23T15:04:05.000Z")
        // ⛔ ABSENT, NOT NULL, ON THE WIRE. The server omits `completedAt` until setup
        // finishes, and the Optional is what makes "absent" read as "not finished".
        XCTAssertNil(progress.completedAt)
        XCTAssertNil(progress.firstRealCallAt)
        XCTAssertNil(progress.testCallConsent)
        XCTAssertNil(progress.forwardingCheck)
    }

    func testAnOwnerMidWizardIsOfferedTheRest() throws {
        XCTAssertTrue(try decode(fixtureText()).needsWebSetup)
    }

    func testAWorkspaceFromBeforeTheWizardIsNeverOfferedIt() throws {
        let text = try fixtureText()
        let pattern = try NSRegularExpression(pattern: #""setupProgress": \{[\s\S]*?\n  \},"#)
        let preWizard = pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: #""setupProgress": null,"#
        )

        let response = try decode(preWizard)

        XCTAssertNil(response.setupProgress, "the derivation must actually null the progress")
        XCTAssertFalse(response.needsWebSetup)
    }

    func testAFinishedWizardIsNotOfferedAgain() throws {
        let paid = #""paidAt": "2026-09-23T15:04:05.000Z""#
        let text = try fixtureText()
        XCTAssertTrue(text.contains(paid), "the derivation depends on this exact line")
        let finished = text.replacingOccurrences(
            of: paid,
            with: paid + ",\n    \"completedAt\": \"2026-09-24T09:00:00.000Z\""
        )

        let response = try decode(finished)

        XCTAssertEqual(response.setupProgress?.completedAt, "2026-09-24T09:00:00.000Z")
        XCTAssertFalse(response.needsWebSetup)
    }

    /// ⛔ THE OPAQUE FIELDS ROUND-TRIP WHATEVER ARRIVES, so a reshaped facts payload or a
    /// consent record the app never reads cannot fail the one decode the card depends on.
    func testTheOpaqueFieldsCarryAnyShape() throws {
        let body = #"""
        {"setupProgress":{"testCallConsent":{"at":"x","wording":"y"},"forwardingCheck":{"state":"ok"}},
        "businessFacts":{"hours":[{"day":"mon","open":"09:00"}],"note":null}}
        """#

        let response = try decode(body)

        XCTAssertEqual(response.businessFacts?["hours"]?.arrayValue?.count, 1)
        XCTAssertEqual(response.setupProgress?.testCallConsent?["wording"]?.stringValue, "y")
        XCTAssertEqual(response.setupProgress?.forwardingCheck?["state"]?.stringValue, "ok")
        XCTAssertTrue(response.needsWebSetup)
    }
}
