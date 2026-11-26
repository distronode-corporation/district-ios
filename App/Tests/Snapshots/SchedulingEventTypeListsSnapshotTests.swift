@testable import DistrictAI
import DistrictData
import SwiftUI
import XCTest

/// The event type's two lists, its hosts and its booking questions, each read by the sheet
/// itself from the recorded answers: loaded, empty, refused, and the one-question editor.
final class SchedulingEventTypeListsSnapshotTests: SchedulingWriteSnapshotCase {
    // MARK: - Hosts

    /// The recorded hosts; every recorded user already hosts or is archived, so there is
    /// no add picker.
    func testHostsRecorded() async throws {
        let item = try await recordedEventType()
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingEventTypeHostsSheet(model: SchedulingEventTypeHostsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            ))
        }
    }

    func testHostsWithSomeoneToAdd() async throws {
        let item = try await recordedEventType()
        try await assertScreen(["op:users.list": Self.usersWithCandidate], devices: [.iPhone]) { container in
            SchedulingEventTypeHostsSheet(model: SchedulingEventTypeHostsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            ))
        }
    }

    /// ⛔ A HOST WHO MAY NOT LIST THE TENANCY GETS THE TABLE, NOT A FAILURE: `users.list` is
    /// admin-only, so its refusal hides the add control and says nothing.
    func testHostsDirectoryRefused() async throws {
        let item = try await recordedEventType()
        try await assertScreen(["op:users.list": .refused], devices: [.iPhone], locales: [.en]) { container in
            SchedulingEventTypeHostsSheet(model: SchedulingEventTypeHostsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            ))
        }
    }

    func testHostsReadFailed() async throws {
        let item = try await recordedEventType()
        try await assertScreen(["op:eventTypes.hosts.get": .notReady], devices: [.iPhone]) { container in
            SchedulingEventTypeHostsSheet(model: SchedulingEventTypeHostsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            ))
        }
    }

    /// Every host removed and Save pressed: refused before sending, with the list empty.
    func testHostsSaveWithNone() async throws {
        let item = try await recordedEventType()
        try await assertScreen(devices: [.iPhone]) { container in
            let model = SchedulingEventTypeHostsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            )
            return SnapshotPrepared(SchedulingEventTypeHostsSheet(model: model)) {
                await firstReadLanded { !model.rows.isEmpty }
                for row in model.rows {
                    model.remove(row.userId)
                }
                await model.save()
            }
        }
    }

    /// A priority that is not a whole number, refused on Save.
    func testHostsPriorityInvalid() async throws {
        let item = try await recordedEventType()
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = SchedulingEventTypeHostsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            )
            return SnapshotPrepared(SchedulingEventTypeHostsSheet(model: model)) {
                await firstReadLanded { !model.rows.isEmpty }
                model.setPriority("2.5", for: "sched-user-rotation")
                await model.save()
            }
        }
    }

    // MARK: - Questions

    func testQuestionsRecorded() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingEventTypeQuestionsSheet(model: self.questions(container))
        }
    }

    func testQuestionsEmpty() async throws {
        try await assertScreen(["op:eventTypes.questions.list": .noItems], devices: [.iPhone]) { container in
            SchedulingEventTypeQuestionsSheet(model: self.questions(container))
        }
    }

    func testQuestionsReadRefused() async throws {
        try await assertScreen(["op:eventTypes.questions.list": .refused], devices: [.iPhone]) { container in
            SchedulingEventTypeQuestionsSheet(model: self.questions(container))
        }
    }

    /// A refused delete: the list stays as it was, with the scheduler's sentence under it.
    func testQuestionsDeleteRefused() async throws {
        try await assertScreen(
            ["op:eventTypes.questions.delete": .refused],
            devices: [.iPhone],
            locales: [.en]
        ) { container in
            let model = self.questions(container)
            return SnapshotPrepared(SchedulingEventTypeQuestionsSheet(model: model)) {
                await firstReadLanded { !model.questions.isEmpty }
                guard let first = model.questions.first else {
                    XCTFail("the recorded questions did not load")
                    return
                }
                model.beginDelete(first)
                await model.delete()
            }
        }
    }

    /// "Add question": a blank text question placed after the recorded two.
    func testQuestionEditorAdd() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.questions(container)
            return SnapshotPrepared(SchedulingQuestionEditor(model: model)) {
                await model.load()
                model.beginAdd()
            }
        }
    }

    /// The recorded `select` question opened for editing, with its three options listed.
    func testQuestionEditorEditSelect() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.questions(container)
            return SnapshotPrepared(SchedulingQuestionEditor(model: model)) {
                await model.load()
                guard let first = model.questions.first else {
                    XCTFail("the recorded questions did not load")
                    return
                }
                model.beginEdit(first)
            }
        }
    }

    /// A `select` with no options, refused on the press before anything is sent.
    func testQuestionEditorSelectWithoutOptions() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.questions(container)
            return SnapshotPrepared(SchedulingQuestionEditor(model: model)) {
                await model.load()
                model.beginAdd()
                model.updateEditing { form in
                    form.label = "Which office?"
                    form.type = "select"
                }
                await model.submit()
            }
        }
    }

    private func questions(_ container: AppContainer) -> SchedulingEventTypeQuestionsModel {
        SchedulingEventTypeQuestionsModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            slug: Self.slug,
            onSaved: { _ in }
        )
    }
}
