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
                // ⛔ THE SHEET READS TWICE, HOSTS AND THEN THE DIRECTORY, and the directory's add
                // candidates are worked out against the rows as they are when it answers. Removing
                // the rows between the two offered every removed host back under an Add button
                // (run 45909792980, fr-CA), so the step waits for the second read too.
                await firstReadLanded { !model.rows.isEmpty && model.canAddHosts }
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
                // Both reads, as in ``testHostsSaveWithNone()``.
                await firstReadLanded { !model.rows.isEmpty && model.canAddHosts }
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

    private func questions(_ container: AppContainer) -> SchedulingEventTypeQuestionsModel {
        SchedulingEventTypeQuestionsModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            slug: Self.slug,
            onSaved: { _ in }
        )
    }
}
