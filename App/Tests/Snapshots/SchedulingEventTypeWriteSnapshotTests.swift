@testable import DistrictAI
import DistrictData
import SwiftUI
import XCTest

/// The event type's form and its state actions, opened over the recorded event type, in
/// the states a person reaches by using them: blank, refused before sending, refused by
/// the scheduler, and saved.
final class SchedulingEventTypeWriteSnapshotTests: SchedulingWriteSnapshotCase {
    // MARK: - The form

    func testEditorCreateBlank() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingEventTypeEditorSheet(model: SchedulingEventTypeEditorModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                takenSlugs: [Self.slug],
                onSaved: { _ in }
            ))
        }
    }

    /// Save pressed on a blank form: the sentence for the missing name, and no request.
    func testEditorCreateRefusedBeforeSending() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = SchedulingEventTypeEditorModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                onSaved: { _ in }
            )
            return SnapshotPrepared(SchedulingEventTypeEditorSheet(model: model)) { await model.save() }
        }
    }

    func testEditorEditRecorded() async throws {
        let item = try await recordedEventType()
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingEventTypeEditorSheet(model: SchedulingEventTypeEditorModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                editing: item,
                onSaved: { _ in }
            ))
        }
    }

    /// A phone location asks for the number, a field the generated locations do not have.
    func testEditorEditPhoneLocation() async throws {
        let item = try await recordedEventType()
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = SchedulingEventTypeEditorModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                editing: item,
                onSaved: { _ in }
            )
            model.form.location = "phone"
            model.form.locationValue = "+14165551234"
            return SchedulingEventTypeEditorSheet(model: model)
        }
    }

    /// An interval of zero is refused on the press, beside the field values as typed.
    func testEditorEditRefusedBeforeSending() async throws {
        let item = try await recordedEventType()
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = SchedulingEventTypeEditorModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                editing: item,
                onSaved: { _ in }
            )
            model.form.interval = "0"
            return SnapshotPrepared(SchedulingEventTypeEditorSheet(model: model)) { await model.save() }
        }
    }

    /// The scheduler refused the patch: its sentence stays on the open form.
    func testEditorEditRefusedByScheduler() async throws {
        let item = try await recordedEventType()
        try await assertScreen(["op:eventTypes.patch": .refused], devices: [.iPhone]) { container in
            let model = SchedulingEventTypeEditorModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                editing: item,
                onSaved: { _ in }
            )
            model.form.name = "Phone consultation (30 min)"
            return SnapshotPrepared(SchedulingEventTypeEditorSheet(model: model)) { await model.save() }
        }
    }

    // MARK: - The state actions

    func testActionsRecorded() async throws {
        let item = try await recordedEventType()
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingEventTypeActionsSheet(model: SchedulingEventTypeActionsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            ))
        }
    }

    /// Archived, the state the recorded patch answer does not carry: Restore offered.
    func testActionsAfterArchive() async throws {
        let item = try await recordedEventType()
        let archived = #"{"ok":true,"data":{"id":"et-contract-1","slug":"phone-consultation","#
            + #""name":"Phone consultation","duration_minutes":30,"location_type":"livekit","#
            + #""is_active":false,"archived":true}}"#
        try await assertScreen(["op:eventTypes.patch": .json(archived)], devices: [.iPhone]) { container in
            let model = SchedulingEventTypeActionsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            )
            return SnapshotPrepared(SchedulingEventTypeActionsSheet(model: model)) { await model.toggleArchived() }
        }
    }

    func testActionsTestEmailSent() async throws {
        let item = try await recordedEventType()
        try await assertScreen(
            ["op:eventTypes.testEmail": .fixture("district-scheduling-test-email")],
            devices: [.iPhone]
        ) { container in
            let model = SchedulingEventTypeActionsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            )
            return SnapshotPrepared(SchedulingEventTypeActionsSheet(model: model)) {
                await model.sendTestEmail(type: "confirmation")
            }
        }
    }

    /// A refused delete leaves the sheet open with the scheduler's sentence.
    func testActionsDeleteRefused() async throws {
        let item = try await recordedEventType()
        try await assertScreen(["op:eventTypes.delete": .notReady], devices: [.iPhone]) { container in
            let model = SchedulingEventTypeActionsModel(
                admin: container.schedulingAdmin,
                workspaceId: Self.workspace,
                eventType: item,
                onSaved: { _ in }
            )
            return SnapshotPrepared(SchedulingEventTypeActionsSheet(model: model)) { await model.delete() }
        }
    }
}
