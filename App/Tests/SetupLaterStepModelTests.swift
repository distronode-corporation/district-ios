@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// What steps 4 to 6 send: step 4's sections, step 5's call handling, and step 6's calls.
@MainActor
final class SetupLaterStepModelTests: SetupStepTestCase {
    // MARK: - Step 4

    /// ⛔ HOURS FROM THE WEBSITE ARE A DRAFT: left out of a save, and Continue refuses past them.
    func testWebsiteHoursAreLeftOutOfASaveUntilUsed() async throws {
        let transport = SetupTransport([SetupFixture.lookupRoute: [(200, SetupFixture.lookup)]])
        let wizard = await wizard(transport, states: ["done", "done", "done", "todo", "todo", "todo"])
        transport.add(SetupFixture.patchRoute, SetupFixture.setup())
        let model = SetupCallersModel(wizard: wizard)
        model.websiteUrl = "example.com"

        await model.fillHoursFromWebsite()
        XCTAssertTrue(model.hoursDraftPending)
        XCTAssertEqual(model.hours[.mon]?.intervals, [SetupInterval(open: 540, close: 1020)])
        await model.saveAndContinue()
        XCTAssertEqual(model.saveError, "Use or discard the hours from your website before you continue.")
        XCTAssertTrue(transport.sent(SetupFixture.patchRoute).isEmpty)

        await model.save()
        var facts = try XCTUnwrap(transport.bodies(SetupFixture.patchRoute).last?["businessFacts"] as? [String: Any])
        XCTAssertNil(facts["weeklyHours"], "an unconfirmed draft is not saved")
        XCTAssertTrue(facts["services"] is NSNull, "an empty section is a clear")

        model.useDraftHours()
        await model.save()
        facts = try XCTUnwrap(transport.bodies(SetupFixture.patchRoute).last?["businessFacts"] as? [String: Any])
        XCTAssertNotNil(facts["weeklyHours"] as? [String: Any])
    }

    func testDiscardPutsBackTheStoredHours() async {
        let transport = SetupTransport([SetupFixture.lookupRoute: [(200, SetupFixture.lookup)]])
        let stored = "{\"weeklyHours\":{\"sun\":\"closed\"}}"
        let model = await SetupCallersModel(wizard: wizard(transport, facts: stored))
        model.websiteUrl = "example.com"

        await model.fillHoursFromWebsite()
        model.discardDraftHours()

        XCTAssertFalse(model.hoursDraftPending)
        XCTAssertEqual(model.hours[.sun]?.state, .closed)
        XCTAssertEqual(model.hours[.mon]?.state, .notSet)
    }

    func testAnInvalidEntryIsNeverSent() async {
        let transport = SetupTransport([:])
        let model = await SetupCallersModel(wizard: wizard(transport))
        model.addService()

        let saved = await model.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(model.saveError, "Fix the entries marked in red, then save.")
        XCTAssertTrue(transport.sent(SetupFixture.patchRoute).isEmpty)
    }

    // MARK: - Step 5

    func testCallerProfilesAreOfferedOnlyOnThePlansThatIncludeThem() {
        XCTAssertTrue(SetupCallsModel.profilesOffered(tier: "VoiceStudio"))
        XCTAssertTrue(SetupCallsModel.profilesOffered(tier: "dgi"))
        XCTAssertFalse(SetupCallsModel.profilesOffered(tier: "VoicePro"))
        XCTAssertFalse(SetupCallsModel.profilesOffered(tier: nil))
    }

    /// ⚠️ ONLY WHAT CHANGED IS SENT, and the echo is the new baseline.
    func testContinueSavesAnUnsavedAnsweringChoiceFirst() async throws {
        let transport = SetupTransport([
            SetupFixture.callHandlingRoute: [(200, SetupFixture.callHandling())],
            SetupFixture.configRoute: [(200, SetupFixture.config())],
            SetupFixture.connectionsRoute: [(200, SetupFixture.connections)],
            SetupFixture.callHandlingSaveRoute: [(200, SetupFixture.callHandling("app_first", ring: 20))],
        ])
        let wizard = await wizard(transport, states: ["done", "done", "done", "done", "todo", "todo"])
        transport.add(SetupFixture.patchRoute, SetupFixture.setup(["done", "done", "done", "done", "done", "todo"]))
        let model = SetupCallsModel(
            wizard: wizard,
            workspaces: workspaces(transport),
            callHandling: CallHandlingRepository(client: transport.client)
        )
        await model.load()
        XCTAssertEqual(model.transferNumber, "+14165550199")
        XCTAssertEqual(model.calendarName, "Google Calendar")
        XCTAssertFalse(model.profilesOffered)

        model.mode = "app_first"
        await model.saveAndContinue()

        let body = try XCTUnwrap(transport.bodies(SetupFixture.callHandlingSaveRoute).first)
        XCTAssertEqual(body["callHandling"] as? String, "app_first")
        XCTAssertNil(body["appRingSeconds"], "the ring did not change")
        XCTAssertFalse(model.answeringChanged)
        XCTAssertEqual(wizard.active, .golive)
    }

    /// ⛔ A FAILED READ IS NOT A FORM OF DEFAULTS.
    func testAFailedCallHandlingReadIsARetry() async {
        let transport = SetupTransport([
            SetupFixture.callHandlingRoute: [(500, "{\"error\":\"Boom\"}")],
            SetupFixture.configRoute: [(200, SetupFixture.config())],
        ])
        let model = await SetupCallsModel(
            wizard: wizard(transport),
            workspaces: workspaces(transport),
            callHandling: CallHandlingRepository(client: transport.client)
        )

        await model.load()

        guard case .failed = model.phase else { return XCTFail("got \(model.phase)") }
    }

    // MARK: - Step 6

    private func goLive(_ transport: SetupTransport, numbersHeld: Int = 1) async -> SetupGoLiveModel {
        await SetupGoLiveModel(
            wizard: wizard(transport, numbersHeld: numbersHeld),
            workspaces: workspaces(transport),
            callHandling: CallHandlingRepository(client: transport.client),
            pollInterval: .milliseconds(1),
            pollLimit: 5
        )
    }

    func testATestCallNeedsAValidNumberAndSendsOnlyThePhone() async throws {
        let transport = SetupTransport([
            SetupFixture.testCallRoute: [(200, "{\"success\":true,\"callId\":\"CA1\"}")],
        ])
        let model = await goLive(transport)

        model.mobile = "call me"
        await model.callMe()
        XCTAssertTrue(model.mobileError)
        XCTAssertTrue(transport.sent(SetupFixture.testCallRoute).isEmpty)

        model.mobile = "(416) 555-0123"
        await model.callMe()
        let body = try XCTUnwrap(transport.bodies(SetupFixture.testCallRoute).first)
        XCTAssertEqual(Set(body.keys), ["workspaceId", "phone"], "the service records its own consent wording")
        XCTAssertEqual(body["phone"] as? String, "+14165550123")
        XCTAssertEqual(model.callStatus, .calling)
    }

    /// ⛔ A TEST CALL IS A REAL CALL: two taps place one.
    func testTwoTapsPlaceOneTestCall() async {
        let transport = SetupTransport([
            SetupFixture.testCallRoute: [(200, "{\"success\":true,\"callId\":\"CA1\"}")],
        ])
        let model = await goLive(transport)
        model.mobile = "+14165550123"
        transport.delay = .milliseconds(200)

        async let first: Void = model.callMe()
        async let second: Void = model.callMe()
        _ = await (first, second)

        XCTAssertEqual(transport.sent(SetupFixture.testCallRoute).count, 1)
    }

    func testWithoutANumberThereIsNoTestCall() async {
        let transport = SetupTransport([:])
        let model = await goLive(transport, numbersHeld: 0)
        model.mobile = "+14165550123"

        await model.callMe()

        XCTAssertFalse(model.hasNumber)
        XCTAssertTrue(transport.sent(SetupFixture.testCallRoute).isEmpty)
    }

    func testAForwardingCheckIsPolledUntilItPasses() async throws {
        let transport = SetupTransport([
            SetupFixture.forwardingStartRoute: [(202, SetupFixture.forwarding("pending", attemptsLeft: 3))],
            SetupFixture.forwardingRoute: [
                (200, SetupFixture.forwarding("pending", attemptsLeft: 3)),
                (200, SetupFixture.forwarding("passed", attemptsLeft: 3)),
            ],
        ])
        let model = await goLive(transport)
        model.businessLine = "416 555 0123"
        model.mode = .unanswered

        await model.startCheck()

        let body = try XCTUnwrap(transport.bodies(SetupFixture.forwardingStartRoute).first)
        XCTAssertEqual(body["businessLine"] as? String, "+14165550123")
        XCTAssertEqual(body["mode"] as? String, "unanswered")
        XCTAssertEqual(model.checkSentence, "Forwarding works. The call arrived on your District number.")
        XCTAssertEqual(model.attemptsSentence, "3 checks left today.")
        XCTAssertEqual(transport.sent(SetupFixture.forwardingRoute).count, 2)
    }

    /// ⚠️ THE POLL ENDS AT ITS LIMIT, never on a loop that runs forever.
    func testAPendingCheckStopsBeingPolledAtTheLimit() async {
        let transport = SetupTransport([
            SetupFixture.forwardingStartRoute: [(202, SetupFixture.forwarding("pending", attemptsLeft: 1))],
            SetupFixture.forwardingRoute: [(200, SetupFixture.forwarding("pending", attemptsLeft: 1))],
        ])
        let model = await goLive(transport)
        model.businessLine = "+14165550123"

        await model.startCheck()

        XCTAssertEqual(transport.sent(SetupFixture.forwardingRoute).count, 5)
        XCTAssertEqual(model.checkSentence, "Checking. This takes up to a minute.")
        XCTAssertEqual(model.attemptsSentence, "1 check left today.")
    }

    func testAFailedCheckSaysWhichFailure() async {
        let transport = SetupTransport([
            SetupFixture.forwardingStartRoute: [(202, SetupFixture.forwarding("failed", failure: "dial_failed"))],
        ])
        let model = await goLive(transport)
        model.businessLine = "+14165550123"

        await model.startCheck()

        XCTAssertEqual(model.checkSentence, "We could not place the check call. Try again in a few minutes.")
    }
}
