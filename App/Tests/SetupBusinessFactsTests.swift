@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// What step 1 writes back over what other steps stored: the address and time zone step 4
/// changed, the "what you do" question's switch, and the question cap.
@MainActor
final class SetupBusinessFactsTests: SetupStepTestCase {
    /// ⛔ THE SAVED ADDRESS BEATS THE DRAFT: after step 4 changes the city and the time zone, Back
    /// to step 1 opens on them, and saving step 1 again writes neither the draft's city nor the
    /// province's default zone over them.
    func testBackToStepOneAfterStepFourKeepsStepFoursPlaceAndZone() async throws {
        let before = """
        {"address":{"city":"Toronto","region":"ON","country":"CA"},"timezone":"America/Toronto"}
        """
        let after = """
        {"address":{"city":"Kenora","region":"ON","country":"CA"},"timezone":"America/Winnipeg"}
        """
        let states = ["done", "done", "done", "todo", "todo", "todo"]
        let transport = SetupTransport([:])
        let wizard = await wizard(transport, states: states, facts: before)
        XCTAssertEqual(wizard.draft.city, "Toronto", "step 1's draft holds the place it saved")
        transport.add(SetupFixture.patchRoute, SetupFixture.setup(states, facts: after))
        let callers = SetupCallersModel(wizard: wizard)
        callers.address.city = "Kenora"
        callers.timezone = "America/Winnipeg"
        let saved = await callers.save()
        XCTAssertTrue(saved)

        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport))
        XCTAssertEqual(model.city, "Kenora", "step 1 opens on the saved address, not its draft")
        XCTAssertEqual(model.subdivision, "ON")
        await model.save()

        let sent = transport.bodies(SetupFixture.patchRoute).compactMap { $0["businessFacts"] as? [String: Any] }
        XCTAssertEqual(sent.count, 2, "step 4's facts, then step 1's")
        let facts = try XCTUnwrap(sent.last)
        XCTAssertEqual(facts["address"] as? [String: String], ["city": "Kenora", "region": "ON", "country": "CA"])
        XCTAssertEqual(facts["timezone"] as? String, "America/Winnipeg", "the zone chosen in step 4 is kept")
    }

    /// A place changed in step 1 (here only the city) takes the place's own zone again, as on a
    /// first save, and the step says to check it in step 4.
    func testAChangedPlaceTakesItsOwnZoneAgain() async throws {
        let stored = """
        {"address":{"city":"Kenora","region":"ON","country":"CA"},"timezone":"America/Winnipeg"}
        """
        let transport = SetupTransport([:])
        let wizard = await wizard(transport, facts: stored)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup(facts: stored))
        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport))
        model.city = "Ottawa"

        await model.save()

        let facts = try XCTUnwrap(transport.bodies(SetupFixture.patchRoute).first?["businessFacts"] as? [String: Any])
        XCTAssertEqual(facts["timezone"] as? String, "America/Toronto")
    }

    /// ⛔ THE OWNER'S SWITCH IS KEPT: a "what you do" question switched off in step 4 stays off
    /// when step 1 saves it again. A new one starts on (`SetupStepModelTests`).
    func testSavingKeepsWhatYouDoSwitchedOffWhenItWasTurnedOff() async throws {
        let stored = """
        {"faqs":[{"question":"What does the business do?","answer":"Family dentist","enabled":false}]}
        """
        let transport = SetupTransport([:])
        let wizard = await wizard(transport, facts: stored)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup(facts: stored))
        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport))
        model.choose(country: "CA")
        model.subdivision = "ON"
        model.city = "Toronto"
        XCTAssertEqual(model.what, "Family dentist")
        model.what = "Family dentist, evenings too"

        await model.save()

        let facts = try XCTUnwrap(transport.bodies(SetupFixture.patchRoute).first?["businessFacts"] as? [String: Any])
        let faqs = try XCTUnwrap(facts["faqs"] as? [[String: Any]])
        XCTAssertEqual(faqs.count, 1, "the stored question is replaced, not added to")
        XCTAssertEqual(faqs.first?["answer"] as? String, "Family dentist, evenings too")
        XCTAssertEqual(faqs.first?["enabled"] as? Bool, false)
    }

    /// ⛔ NO SILENT DROP AT THE CAP: with 50 stored questions and no "what you do" among them, a
    /// new one is refused with a sentence and nothing is sent.
    func testAtTheQuestionCapANewWhatYouDoIsRefusedNotTruncated() async {
        let transport = SetupTransport([:])
        let wizard = await wizard(transport, facts: Self.faqs(Self.questions(50)))
        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport))
        model.choose(country: "CA")
        model.subdivision = "ON"
        model.city = "Toronto"
        model.what = "Family dentist"

        await model.save()

        XCTAssertTrue(transport.sent(SetupFixture.patchRoute).isEmpty, "no question is cut to make room")
        XCTAssertEqual(
            model.saveError?.message,
            "You already have 50 saved questions, the most allowed. "
                + "Remove one in step 4, or leave what you do empty."
        )
        XCTAssertEqual(wizard.active, .business)
    }

    /// At the cap with a "what you do" question stored, it is replaced and every other one kept.
    func testAtTheQuestionCapAStoredWhatYouDoIsReplaced() async throws {
        let what = "{\"question\":\"What does the business do?\",\"answer\":\"Dentist\",\"enabled\":true}"
        let stored = Self.faqs([what] + Self.questions(49))
        let transport = SetupTransport([:])
        let wizard = await wizard(transport, facts: stored)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup(facts: stored))
        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport))
        model.choose(country: "CA")
        model.subdivision = "ON"
        model.city = "Toronto"
        model.what = "Family dentist"

        await model.save()

        let facts = try XCTUnwrap(transport.bodies(SetupFixture.patchRoute).first?["businessFacts"] as? [String: Any])
        let faqs = try XCTUnwrap(facts["faqs"] as? [[String: Any]])
        XCTAssertEqual(faqs.count, 50)
        XCTAssertEqual(faqs.first?["answer"] as? String, "Family dentist")
        XCTAssertEqual(faqs.last?["question"] as? String, "Question 49?", "every other question is kept")
        XCTAssertNil(model.saveError)
    }

    /// `count` stored questions, none of them "what you do".
    private static func questions(_ count: Int) -> [String] {
        (1 ... count).map { "{\"question\":\"Question \($0)?\",\"answer\":\"Answer \($0).\",\"enabled\":true}" }
    }

    private static func faqs(_ rows: [String]) -> String {
        "{\"faqs\":[\(rows.joined(separator: ","))]}"
    }
}
