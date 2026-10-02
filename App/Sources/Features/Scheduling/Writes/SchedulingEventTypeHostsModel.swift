import DistrictData
import DistrictModel
import Foundation
import Observation

/// One row of the hosts table while it is being edited.
///
/// ⚠️ `priority` IS A `String` FOR ``SchedulingEventTypeForm``'S REASON: 0 is a
/// legal value, so a field bound to an `Int` cannot tell "cleared it to retype"
/// from "meant zero".
struct SchedulingHostRow: Identifiable, Equatable {
    /// ⛔ THE SCHEDULER'S USER ID, WHICH IS NOT A DISTRICT MEMBER ID. The join
    /// lives inside the fork; nothing here resolves against a workspace directory.
    let userId: String
    let name: String
    let email: String
    var role: String
    var priority: String

    var id: String {
        userId
    }
}

/// Who can be booked on an event type, and how the next booking is routed to
/// them.
///
/// ⛔ THE SAVE IS TWO OPS IN A FIXED ORDER, HOSTS FIRST, AND THE ORDER IS THE
/// WEB'S. `eventTypes.hosts.put` REPLACES the list and the schema refuses an empty
/// array; `eventTypes.patch` then carries `routing_mode` and `rr_strategy`, which
/// are columns on the event type rather than on a host. Patching first would leave
/// a `round_robin` event type pointing at a host list that had not arrived, which
/// is a bookable state nobody chose.
///
/// ⛔ THE REFUSAL FOR AN EMPTY LIST IS ON THE SAVE, NOT ON THE REMOVE, AND THAT IS
/// DELIBERATE RATHER THAN LAX. Swapping the only host for a different one means
/// passing through zero rows; a Remove button that refused the last row would make
/// that ordinary edit impossible, and the schema's `.min(1)` is enforced at the
/// wire either way.
///
/// ⚠️ THERE IS NO DRAG ORDERING, ON EITHER CLIENT. The table renders in
/// `eventTypes.hosts.get` order and `priority` is the only ordering signal the
/// fork reads — and it reads it only under `rr_strategy == "priority"`.
@MainActor
@Observable
final class SchedulingEventTypeHostsModel {
    private(set) var rows: [SchedulingHostRow] = []
    private(set) var loadState: SchedulingWriteState = .idle
    private(set) var state: SchedulingWriteState = .idle
    private(set) var validation: String?
    /// Scheduler users not already hosting, for the add picker.
    ///
    /// ⚠️ EMPTY ALSO MEANS "we could not read the directory", and the two are
    /// separated by ``canAddHosts``: `users.list` is admin-only at the fork, so an
    /// ordinary host sees the table and cannot be offered an add control at all.
    private(set) var candidates: [SchedulingUser] = []
    private(set) var canAddHosts = false

    var routingMode: String
    var rotationStrategy: String

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let slug: String
    private let onSaved: ([SchedulingHost]) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        eventType: SchedulingEventType,
        onSaved: @escaping ([SchedulingHost]) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        slug = eventType.slug
        self.onSaved = onSaved
        routingMode = eventType.routingMode ?? "fixed"
        rotationStrategy = eventType.rrStrategy ?? "even"
    }

    /// ⚠️ THE ROTATION PICKER IS DRAWN ONLY FOR `round_robin`, because it decides
    /// nothing on the other two modes and the fork stores it regardless.
    var showsRotationStrategy: Bool {
        routingMode == "round_robin"
    }

    var isEmpty: Bool {
        rows.isEmpty
    }

    func load() async {
        loadState = .working
        do {
            let hosts = try await admin.eventTypeHosts(workspaceId: workspaceId, slug: slug)
            rows = hosts.map {
                SchedulingHostRow(
                    userId: $0.userId,
                    name: $0.name,
                    email: $0.email,
                    role: $0.role,
                    priority: String($0.priority)
                )
            }
            loadState = .idle
        } catch {
            loadState = .failed(SchedulingFailureCopy.text(forAny: error))
            return
        }
        await loadCandidates()
    }

    /// ⛔ A REFUSED DIRECTORY READ IS NOT A FAILED SCREEN. `users.list` is
    /// admin-only; a host who may edit this table and may not list the tenancy gets
    /// the table, with no add control and no error.
    private func loadCandidates() async {
        do {
            let users = try await admin.schedulerUsers(workspaceId: workspaceId)
            let assigned = Set(rows.map(\.userId))
            candidates = users.filter { !assigned.contains($0.id) && !$0.archived }
            canAddHosts = true
        } catch {
            candidates = []
            canAddHosts = false
        }
    }

    func add(_ user: SchedulingUser) {
        guard !rows.contains(where: { $0.userId == user.id }) else { return }
        rows.append(
            SchedulingHostRow(
                userId: user.id,
                name: user.name,
                email: user.email,
                role: "required",
                priority: "0"
            )
        )
        candidates.removeAll { $0.id == user.id }
    }

    func remove(_ userId: String) {
        rows.removeAll { $0.userId == userId }
    }

    func setRole(_ role: String, for userId: String) {
        guard let index = rows.firstIndex(where: { $0.userId == userId }) else { return }
        rows[index].role = role
    }

    func setPriority(_ priority: String, for userId: String) {
        guard let index = rows.firstIndex(where: { $0.userId == userId }) else { return }
        rows[index].priority = priority
    }

    func dismissNotice() {
        validation = nil
        state = .idle
    }

    func save() async {
        guard !state.isWorking else { return }
        if rows.isEmpty {
            validation = SchedulingWriteCopy.hostsNeedOne
            return
        }
        var assignments: [SchedulingHostAssignment] = []
        for row in rows {
            guard let priority = SchedulingEventTypeForm.whole(row.priority, atLeast: 0) else {
                validation = SchedulingWriteCopy.hostPriorityInvalid
                return
            }
            assignments.append(
                SchedulingHostAssignment(userId: row.userId, role: row.role, priority: priority)
            )
        }
        validation = nil
        state = .working
        await put(assignments)
    }

    /// ⚠️ THE SECOND OP RUNS ONLY IF THE FIRST LANDED, and a failure in the second
    /// leaves the hosts saved. That is reported honestly rather than rolled back:
    /// there is no transaction across two ops, and re-sending the host list to undo
    /// a routing change would be a second guess at what the operator wanted.
    private func put(_ assignments: [SchedulingHostAssignment]) async {
        do {
            let hosts = try await admin.putEventTypeHosts(
                workspaceId: workspaceId,
                slug: slug,
                hosts: assignments
            )
            var changes = SchedulingEventTypeChanges()
            changes.routingMode = routingMode
            changes.rrStrategy = rotationStrategy
            _ = try await admin.patchEventType(workspaceId: workspaceId, slug: slug, changes: changes)
            state = .done(SchedulingWriteCopy.hostsSaved)
            onSaved(hosts)
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }
}
