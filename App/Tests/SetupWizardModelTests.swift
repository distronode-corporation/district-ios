@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The wizard's shell over a real ``SetupWizardRepository`` and a canned transport: where it
/// opens, what it refuses, the one step write, and the single flight around it.
@MainActor
final class SetupWizardModelTests: XCTestCase {
    private func loaded(_ transport: SetupTransport) async -> SetupWizardModel {
        let model = SetupWizardModel.test(transport)
        await model.load()
        return model
    }

    // MARK: - Opening

    func testItResumesOnTheFirstStepStillToDo() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup(["done", "done", "todo", "todo", "todo", "todo"]))],
        ])
        let model = await loaded(transport)

        guard case .ready = model.phase else { return XCTFail("expected ready, got \(model.phase)") }
        XCTAssertEqual(model.active, .receptionist)
        XCTAssertEqual(transport.sent(SetupFixture.setupRoute).first?.url.query, "workspaceId=ws_1")
    }

    /// ⛔ A MEMBER'S 403 IS EXPLAINED, NOT AN ERROR WITH A RETRY.
    func testANonOwnerIsToldWhyRatherThanShownAnError() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(403, "{\"error\":\"Only the owner.\",\"code\":\"workspace_owner_only\"}")],
        ])
        let model = await loaded(transport)

        guard case .refused(.notOwner) = model.phase else { return XCTFail("got \(model.phase)") }
    }

    func testAPreWizardWorkspaceIsNotOfferedTheWizardEitherWay() async {
        let refused = await loaded(SetupTransport([
            SetupFixture.setupRoute: [(409, "{\"error\":\"No.\",\"code\":\"setup_not_available\"}")],
        ]))
        guard case .refused(.notAvailable) = refused.phase else { return XCTFail("409: \(refused.phase)") }

        let nullProgress = await loaded(SetupTransport([
            SetupFixture.setupRoute: [(200, "{\"setupProgress\":null,\"businessFacts\":null,\"region\":\"us\"}")],
        ]))
        guard case .refused(.notAvailable) = nullProgress.phase else { return XCTFail("null: \(nullProgress.phase)") }
    }

    func testAServerFailureIsAFailureNotARefusal() async {
        let model = await loaded(SetupTransport([SetupFixture.setupRoute: [(500, "{\"error\":\"Boom\"}")]]))
        guard case .failed = model.phase else { return XCTFail("got \(model.phase)") }
    }

    func testAFinishedWizardSaysSo() async {
        let model = await loaded(SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup(Array(repeating: "done", count: 6), completed: true))],
        ]))
        guard case .finished = model.phase else { return XCTFail("got \(model.phase)") }
    }

    // MARK: - The step write

    func testCompletingAStepWritesItsStateAloneAndMovesOn() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup())],
            SetupFixture.patchRoute: [(200, SetupFixture.setup(["done", "todo", "todo", "todo", "todo", "todo"]))],
        ])
        let model = await loaded(transport)

        let landed = await model.complete(.business, as: .done)

        XCTAssertTrue(landed)
        XCTAssertEqual(model.active, .number)
        let body = transport.bodies(SetupFixture.patchRoute).first
        XCTAssertEqual(body?["workspaceId"] as? String, "ws_1")
        XCTAssertEqual(
            (body?["setupProgress"] as? [String: Any])?["steps"] as? [String: String],
            ["business": "done"],
            "only the one step's state, never the paid stamp or the consent record"
        )
        XCTAssertNil(body?["businessFacts"])
    }

    func testSkipMarksTheStepSkipped() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup(["done", "todo", "todo", "todo", "todo", "todo"]))],
            SetupFixture.patchRoute: [(200, SetupFixture.setup(["done", "skipped", "todo", "todo", "todo", "todo"]))],
        ])
        let model = await loaded(transport)

        await model.skip()

        XCTAssertEqual(model.active, .receptionist)
        XCTAssertEqual(
            (transport.bodies(SetupFixture.patchRoute).first?["setupProgress"] as? [String: Any])?["steps"]
                as? [String: String],
            ["number": "skipped"]
        )
    }

    /// ⛔ A REFUSED WRITE KEEPS THE STEP ON SCREEN, WITH THE SERVICE'S SENTENCE.
    func testARefusedWriteStaysOnTheStepAndSaysWhy() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup())],
            SetupFixture.patchRoute: [(400, "{\"error\":\"Invalid step state.\"}")],
        ])
        let model = await loaded(transport)

        let landed = await model.complete(.business, as: .done)

        XCTAssertFalse(landed)
        XCTAssertEqual(model.active, .business)
        XCTAssertEqual(model.stepError?.message, "Invalid step state.")
    }

    /// ⛔ ONE STEP WRITE AT A TIME: two taps before the first answer send one PATCH.
    func testTwoTapsBeforeTheAnswerSendOneWrite() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup())],
            SetupFixture.patchRoute: [(200, SetupFixture.setup(["skipped", "todo", "todo", "todo", "todo", "todo"]))],
        ])
        let model = await loaded(transport)
        transport.delay = .milliseconds(200)

        async let first = model.complete(.business, as: .skipped)
        async let second = model.complete(.business, as: .skipped)
        let results = await [first, second]

        XCTAssertEqual(results.sorted { !$0 && $1 }, [false, true])
        XCTAssertEqual(transport.sent(SetupFixture.patchRoute).count, 1)
        XCTAssertFalse(model.isCompleting)
    }

    func testTheLastStepFinishesTheWizardAndDropsTheDraft() async {
        let store = SetupDraftStore(defaults: SetupDefaults.fresh())
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup(["done", "done", "done", "done", "done", "todo"]))],
            SetupFixture.patchRoute: [(200, SetupFixture.setup(Array(repeating: "done", count: 6), completed: true))],
        ])
        let model = SetupWizardModel(
            repository: SetupWizardRepository(client: transport.client),
            workspaceId: "ws_1",
            workspaceName: "Northside Dental",
            store: store
        )
        await model.load()
        model.updateDraft(SetupBusinessDraft(
            businessName: "N",
            country: "CA",
            subdivision: "ON",
            city: "T",
            language: .en
        ))
        XCTAssertNotNil(store.load(workspaceId: "ws_1"))

        await model.complete(.golive, as: .done)

        guard case .finished = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertNil(store.load(workspaceId: "ws_1"))
    }

    /// ⚠️ PAST THE LAST STEP WITH ONE STILL OPEN (reached by Back), the open one.
    func testFinishingTheLastStepWithOneStillOpenGoesToIt() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup(["done", "todo", "done", "done", "done", "todo"]))],
            SetupFixture.patchRoute: [(200, SetupFixture.setup(["done", "todo", "done", "done", "done", "done"]))],
        ])
        let model = await loaded(transport)

        await model.complete(.golive, as: .done)

        XCTAssertEqual(model.active, .number)
    }

    func testBackGoesToTheStepBeforeAndStopsAtTheFirst() async {
        let model = await loaded(SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup(["done", "todo", "todo", "todo", "todo", "todo"]))],
        ]))
        model.back()
        XCTAssertEqual(model.active, .business)
        model.back()
        XCTAssertEqual(model.active, .business)
    }

    // MARK: - After a page on the web

    /// A number bought on the web's page marks `number` done there; the wizard moves on by itself.
    func testANumberBoughtOnThePageMovesTheWizardOn() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [
                (200, SetupFixture.setup(["done", "todo", "todo", "todo", "todo", "todo"], numbersHeld: 0)),
                (200, SetupFixture.setup(["done", "done", "todo", "todo", "todo", "todo"], numbersHeld: 1)),
            ],
        ])
        let model = await loaded(transport)
        XCTAssertEqual(model.active, .number)

        await model.refreshAfterHandOff()

        XCTAssertEqual(model.active, .receptionist)
        XCTAssertEqual(model.data?.numbersHeld, 1)
    }

    /// ⛔ A STEP ALREADY DONE (reached by Back) STAYS when a page closes, with what was typed.
    func testAPageClosedOverAStepAlreadyDoneKeepsIt() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup(["done", "done", "todo", "todo", "todo", "todo"]))],
        ])
        let model = await loaded(transport)
        model.back()
        model.back()
        XCTAssertEqual(model.active, .business)

        await model.refreshAfterHandOff()

        XCTAssertEqual(model.active, .business)
    }

    func testAPageClosedWithNothingDoneKeepsTheStep() async {
        let transport = SetupTransport([
            SetupFixture.setupRoute: [(200, SetupFixture.setup(["done", "todo", "todo", "todo", "todo", "todo"]))],
        ])
        let model = await loaded(transport)

        await model.refreshAfterHandOff()

        XCTAssertEqual(model.active, .number)
        XCTAssertEqual(transport.sent(SetupFixture.setupRoute).count, 2)
    }
}
