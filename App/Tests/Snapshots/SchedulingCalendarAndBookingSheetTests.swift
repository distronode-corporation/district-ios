@testable import DistrictAI
import DistrictData
import DistrictModel
import SwiftUI
import XCTest

/// The calendar screen's two editors (which calendars a connection reads and writes, and a
/// CalDAV account connected by password) and the booking list's three (cancel, reassign,
/// reschedule), over the recorded connection, booking, users and slots.
final class SchedulingCalendarAndBookingSheetTests: SchedulingWriteSnapshotCase {
    /// The recorded booking's day, which the recorded slots are on. ⚠️ Fixed so the date
    /// picker draws the same day on every run.
    private static let bookingDay = Date(timeIntervalSince1970: 1_789_390_800) // 2026-09-14T13:00Z

    // MARK: - Calendars on one connection

    func testCalendarPickerRecorded() async throws {
        let connection = try await recordedConnection()
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingCalendarPickerSheet(model: self.picker(container, connection))
        }
    }

    /// ⚠️ AN ACCOUNT WITH NO CALENDARS IS AN ANSWER, NOT A FAILURE.
    func testCalendarPickerEmpty() async throws {
        let connection = try await recordedConnection()
        let none = FixtureTransport.Reply.json(#"{"ok":true,"data":{"calendars":[]}}"#)
        try await assertScreen(["op:calendar.connections.calendars.get": none], devices: [.iPhone]) { container in
            SchedulingCalendarPickerSheet(model: self.picker(container, connection))
        }
    }

    func testCalendarPickerRefused() async throws {
        let connection = try await recordedConnection()
        try await assertScreen(["op:calendar.connections.calendars.get": .refused], devices: [.iPhone]) { container in
            SchedulingCalendarPickerSheet(model: self.picker(container, connection))
        }
    }

    /// The holidays calendar ticked for conflicts and the selection saved.
    func testCalendarPickerSaved() async throws {
        let connection = try await recordedConnection()
        try await assertScreen(
            ["op:calendar.connections.calendars.put": .fixture("district-scheduling-ok")],
            devices: [.iPhone]
        ) { container in
            let model = self.picker(container, connection)
            return SnapshotPrepared(SchedulingCalendarPickerSheet(model: model)) {
                await firstReadLanded { model.rows != nil && !model.busy }
                model.setCheckConflicts("holidays@group.v.calendar.google.test", on: true)
                await model.save()
            }
        }
    }

    // MARK: - CalDAV

    /// iCloud, the default preset: no server address asked for.
    func testCaldavICloud() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingCaldavConnectSheet(model: self.caldav(container))
        }
    }

    /// A custom server asks for its address, and an `http://` one is refused before sending.
    func testCaldavCustomServerRefusedBeforeSending() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.caldav(container)
            model.preset = .custom
            model.serverURL = "http://dav.contract.test"
            return SnapshotPrepared(SchedulingCaldavConnectSheet(model: model)) { await model.connect() }
        }
    }

    func testCaldavPasswordMissing() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.caldav(container)
            model.preset = .fastmail
            model.username = "contract@fastmail.test"
            return SnapshotPrepared(SchedulingCaldavConnectSheet(model: model)) { await model.connect() }
        }
    }

    /// ⛔ THE SERVER REFUSED THE CREDENTIALS: our sentence, since the fork's never travels.
    func testCaldavRefused() async throws {
        try await assertScreen(["op:calendar.caldav.connect": .refused], devices: [.iPhone]) { container in
            let model = self.caldav(container)
            model.username = "contract@icloud.test"
            model.appPassword = "placeholder-app-password"
            return SnapshotPrepared(SchedulingCaldavConnectSheet(model: model)) { await model.connect() }
        }
    }

    /// Connected: the address the server resolved, and the password field emptied.
    func testCaldavConnected() async throws {
        try await assertScreen(
            ["op:calendar.caldav.connect": .fixture("district-scheduling-caldav-connect")],
            devices: [.iPhone]
        ) { container in
            let model = self.caldav(container)
            model.preset = .fastmail
            model.username = "contract"
            model.appPassword = "placeholder-app-password"
            return SnapshotPrepared(SchedulingCaldavConnectSheet(model: model)) { await model.connect() }
        }
    }

    // MARK: - Cancel

    func testCancelBlank() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingBookingCancelSheet(model: self.cancel(container), onClose: {})
        }
    }

    func testCancelReasonTooLong() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.cancel(container)
            model.editReason(String(repeating: "x", count: SchedulingBookingCancelModel.reasonLimit + 1))
            return SnapshotPrepared(SchedulingBookingCancelSheet(model: model, onClose: {})) { await model.submit() }
        }
    }

    func testCancelled() async throws {
        try await assertScreen(
            ["op:bookings.cancel": .fixture("district-scheduling-booking")],
            devices: [.iPhone]
        ) { container in
            let model = self.cancel(container)
            model.editReason("Customer asked to postpone")
            return SnapshotPrepared(SchedulingBookingCancelSheet(model: model, onClose: {})) { await model.submit() }
        }
    }

    func testCancelRefused() async throws {
        try await assertScreen(["op:bookings.cancel": .refused], devices: [.iPhone], locales: [.en]) { container in
            let model = self.cancel(container)
            return SnapshotPrepared(SchedulingBookingCancelSheet(model: model, onClose: {})) { await model.submit() }
        }
    }

    // MARK: - Reassign

    /// The booking's own host left out of the choices, which here leaves nobody.
    func testReassignNobodyElse() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingBookingReassignSheet(model: self.reassign(container), onClose: {})
        }
    }

    func testReassignPicked() async throws {
        try await assertScreen(["op:users.list": Self.usersWithCandidate], devices: [.iPhone]) { container in
            let model = self.reassign(container)
            return SnapshotPrepared(SchedulingBookingReassignSheet(model: model, onClose: {})) {
                await firstReadLanded { !model.candidates.isEmpty }
                model.select("sched-user-new")
            }
        }
    }

    func testReassignDirectoryRefused() async throws {
        try await assertScreen(["op:users.list": .refused], devices: [.iPhone]) { container in
            SchedulingBookingReassignSheet(model: self.reassign(container), onClose: {})
        }
    }

    func testReassignRefused() async throws {
        try await assertScreen(
            ["op:users.list": Self.usersWithCandidate, "op:bookings.reassign": .refused],
            devices: [.iPhone],
            locales: [.en]
        ) { container in
            let model = self.reassign(container)
            return SnapshotPrepared(SchedulingBookingReassignSheet(model: model, onClose: {})) {
                await firstReadLanded { !model.candidates.isEmpty }
                model.select("sched-user-new")
                await model.submit()
            }
        }
    }

    // MARK: - Reschedule

    /// The recorded slots on the booking's day, told in the booking's zone.
    func testRescheduleSlots() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingBookingRescheduleSheet(model: self.reschedule(container), onClose: {})
        }
    }

    func testRescheduleNoSlots() async throws {
        let none = FixtureTransport.Reply.json(#"{"ok":true,"data":{"slots":[]}}"#)
        try await assertScreen(["op:eventTypes.slots": none], devices: [.iPhone]) { container in
            SchedulingBookingRescheduleSheet(model: self.reschedule(container), onClose: {})
        }
    }

    func testRescheduleSlotsRefused() async throws {
        try await assertScreen(["op:eventTypes.slots": .notReady], devices: [.iPhone]) { container in
            SchedulingBookingRescheduleSheet(model: self.reschedule(container), onClose: {})
        }
    }

    /// Save pressed with no time picked: a sentence, and no request.
    func testReschedulePickATime() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.reschedule(container)
            return SnapshotPrepared(SchedulingBookingRescheduleSheet(model: model, onClose: {})) {
                await firstReadLanded {
                    if case .ready = model.slots {
                        return true
                    }
                    return false
                }
                await model.submit()
            }
        }
    }

    // MARK: - Models

    private func picker(
        _ container: AppContainer,
        _ connection: SchedulingCalendarConnection
    ) -> SchedulingCalendarPickerModel {
        SchedulingCalendarPickerModel(
            repository: container.schedulingAdmin,
            workspaceId: Self.workspace,
            connection: connection,
            onChanged: {}
        )
    }

    private func caldav(_ container: AppContainer) -> SchedulingCaldavConnectModel {
        SchedulingCaldavConnectModel(repository: container.schedulingAdmin, workspaceId: Self.workspace, onChanged: {})
    }

    private func cancel(_ container: AppContainer) -> SchedulingBookingCancelModel {
        SchedulingBookingCancelModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            bookingId: Self.bookingId,
            onSaved: { _ in }
        )
    }

    private func reassign(_ container: AppContainer) -> SchedulingBookingReassignModel {
        SchedulingBookingReassignModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            bookingId: Self.bookingId,
            currentHostId: "sched-user-contract",
            onSaved: { _ in }
        )
    }

    private func reschedule(_ container: AppContainer) -> SchedulingBookingRescheduleModel {
        SchedulingBookingRescheduleModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            bookingId: Self.bookingId,
            eventTypeSlug: Self.slug,
            timezone: "America/Toronto",
            startingFrom: Self.bookingDay,
            onSaved: { _ in }
        )
    }
}
