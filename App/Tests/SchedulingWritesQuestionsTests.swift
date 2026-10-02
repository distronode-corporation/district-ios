@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The booking form's questions: add, edit, move, delete.
@MainActor
final class SchedulingWritesQuestionsTests: XCTestCase {
    /// ⚠️ A NEW QUESTION OPENS AT THE END OF THE LIST. A literal 0 would insert it
    /// at the top, which is not what "Add question" means.
    func testAddingSendsTheQuestionAtTheEndOfTheList() async {
        let transport = SettingsTransport([Self.list, Self.created, Self.list])
        let model = Self.questions(transport)
        await model.load()
        model.beginAdd()
        model.updateEditing { $0.label = "What would you like to talk about?" }
        await model.submit()

        let create = SchedulingWritesFixtures.calls(transport)[1]
        XCTAssertEqual(create.op, "eventTypes.questions.create")
        XCTAssertEqual(create.params["slug"] as? String, "phone-consultation")
        XCTAssertEqual(create.params["position"] as? Int, 1)
        XCTAssertEqual(create.params["required"] as? Bool, false)
        XCTAssertEqual(model.state.notice, "Question added")
    }

    /// ⛔ `options` IS SENT ONLY FOR A `select`, which is the web's rule. The
    /// catalog would accept an empty array on a `text` and the two clients would
    /// then answer the same edit differently.
    func testOptionsTravelOnlyWithASelect() async {
        let transport = SettingsTransport([Self.list, Self.created, Self.list])
        let model = Self.questions(transport)
        await model.load()
        model.beginAdd()
        model.updateEditing { $0.label = "Topic" }
        await model.submit()

        XCTAssertNil(SchedulingWritesFixtures.calls(transport)[1].params["options"])
    }

    func testASelectCarriesItsOptions() async {
        let transport = SettingsTransport([Self.list, Self.created, Self.list])
        let model = Self.questions(transport)
        await model.load()
        model.beginAdd()
        model.updateEditing {
            $0.label = "Topic"
            $0.type = "select"
        }
        model.addOption("Sales")
        model.addOption("Support")
        await model.submit()

        let options = SchedulingWritesFixtures.calls(transport)[1].params["options"] as? [String]
        XCTAssertEqual(options, ["Sales", "Support"])
    }

    /// ⚠️ A DUPLICATE OPTION IS IGNORED IN SILENCE. It is a no-op, not an error.
    func testADuplicateOptionIsNotAddedTwiceAndIsNotAnError() async {
        let transport = SettingsTransport([Self.list])
        let model = Self.questions(transport)
        await model.load()
        model.beginAdd()
        model.addOption("Sales")
        model.addOption("Sales")
        model.addOption("   ")

        XCTAssertEqual(model.editing?.options, ["Sales"])
        XCTAssertNil(model.validation)
    }

    func testASelectWithNoOptionsIsRefusedWithoutSendingAnything() async {
        let transport = SettingsTransport([Self.list])
        let model = Self.questions(transport)
        await model.load()
        model.beginAdd()
        model.updateEditing {
            $0.label = "Topic"
            $0.type = "select"
        }
        await model.submit()

        XCTAssertEqual(model.validation, "A Select question needs at least one option.")
        XCTAssertEqual(SchedulingWritesFixtures.calls(transport).count, 1)
    }

    func testAQuestionWithNoLabelIsRefused() async {
        let transport = SettingsTransport([Self.list])
        let model = Self.questions(transport)
        await model.load()
        model.beginAdd()
        await model.submit()

        XCTAssertEqual(model.validation, "Give the question a label.")
    }

    /// ⛔ TWO PATH KEYS, AND BOTH STAY IN THE BODY: the event type's `slug` and the
    /// question's own `id`.
    func testEditingSendsBothPathKeys() async {
        let transport = SettingsTransport([Self.list, Self.created, Self.list])
        let model = Self.questions(transport)
        await model.load()
        model.beginEdit(model.questions[0])
        model.updateEditing { $0.label = "Renamed" }
        await model.submit()

        let patch = SchedulingWritesFixtures.calls(transport)[1]
        XCTAssertEqual(patch.op, "eventTypes.questions.patch")
        XCTAssertEqual(patch.params["slug"] as? String, "phone-consultation")
        XCTAssertEqual(patch.params["id"] as? String, "q_1")
        XCTAssertEqual(patch.params["label"] as? String, "Renamed")
    }

    func testDeletingAddressesTheQuestionAndRereads() async {
        let transport = SettingsTransport([Self.list, SchedulingWritesFixtures.noContent, Self.empty])
        let model = Self.questions(transport)
        await model.load()
        model.beginDelete(model.questions[0])
        await model.delete()

        let calls = SchedulingWritesFixtures.calls(transport)
        XCTAssertEqual(calls[1].op, "eventTypes.questions.delete")
        XCTAssertEqual(calls[1].params["id"] as? String, "q_1")
        XCTAssertEqual(model.state.notice, "Question deleted")
        XCTAssertTrue(model.questions.isEmpty)
    }

    /// ⛔ A FAILED RE-READ IS NOT A FAILED WRITE. The question WAS deleted; telling
    /// somebody otherwise is what makes them do it twice.
    func testAWriteThatLandedIsNotReportedAsFailedWhenTheRereadIs() async {
        let transport = SettingsTransport([
            Self.list,
            SchedulingWritesFixtures.noContent,
            SchedulingWritesFixtures.failure("unavailable"),
        ])
        let model = Self.questions(transport)
        await model.load()
        model.beginDelete(model.questions[0])
        await model.delete()

        XCTAssertNil(model.state.failure)
        XCTAssertEqual(model.state.notice, "Question deleted")
        XCTAssertNotNil(model.loadState.failure)
    }

    /// ⚠️ THE LIST IS SORTED BY `position`, which is the only ordering either
    /// client applies.
    func testTheListIsSortedByPosition() async {
        let transport = SettingsTransport([Self.unsorted])
        let model = Self.questions(transport)
        await model.load()

        XCTAssertEqual(model.questions.map(\.id), ["q_1", "q_2"])
    }

    // MARK: - Fixtures

    private static let list = SchedulingWritesFixtures.items(
        """
        {"id":"q_1","event_type_id":"et_1","label":"Topic","type":"text","options":null,\
        "required":false,"position":0}
        """
    )

    private static let unsorted = SchedulingWritesFixtures.items(
        """
        {"id":"q_2","event_type_id":"et_1","label":"Second","type":"text","options":null,\
        "required":false,"position":4},\
        {"id":"q_1","event_type_id":"et_1","label":"First","type":"text","options":null,\
        "required":false,"position":1}
        """
    )

    private static let empty = SchedulingWritesFixtures.ok(#"{"items":[]}"#)

    private static let created = SchedulingWritesFixtures.ok(
        """
        {"id":"q_9","event_type_id":"et_1","label":"Topic","type":"text","options":null,\
        "required":false,"position":1}
        """
    )

    private static func questions(_ transport: SettingsTransport) -> SchedulingEventTypeQuestionsModel {
        SchedulingEventTypeQuestionsModel(
            admin: SchedulingWritesFixtures.repository(transport),
            workspaceId: "ws_1",
            slug: "phone-consultation",
            onSaved: { _ in }
        )
    }
}
