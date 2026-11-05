import DistrictData
import DistrictModel
import Foundation
import Observation

/// The assign sheet: who a conversation can be given to, and the write
/// (`POST conversations/assign`, DistrictCore 8.2.0).
///
/// ⛔ NO VIEWER IS OFFERED. The route answers 400 `assignee_is_viewer` for one (Sean,
/// 2026-11-04, the web's rule), so a viewer in the list is a choice that can only fail.
/// The refusal is still handled, because a member's role can change between the read
/// and the tap.
///
/// ⛔ ONLY A ROLE THAT MAY WRITE GETS THIS SHEET. The route admits `agency` and `client`;
/// ``InboxModel/canReply`` is that rule (``WorkspaceRole/allowsMutation(_:)``), and the
/// Inbox draws no Assign control for anyone else.
@MainActor
@Observable
final class ThreadAssignModel {
    enum Members {
        case loading
        case ready([String])
        case failed(FailureText)
    }

    private(set) var members: Members = .loading

    /// ⛔ THE SINGLE-FLIGHT GUARD. Two taps before a re-render would send two writes and
    /// two pushes to the assignee.
    private(set) var saving = false

    /// The refusal of the last write, said in the sheet: `assignee_is_viewer`,
    /// `assignee_not_member` or anything else, through ``FailureText``.
    private(set) var failure: FailureText?

    let threadKey: String

    /// The address the thread is assigned to now, or nil. The sheet ticks it.
    let current: String?

    private let inbox: InboxRepository
    private let workspaces: WorkspaceRepository
    private let workspaceId: String

    init(
        inbox: InboxRepository,
        workspaces: WorkspaceRepository,
        workspaceId: String,
        threadKey: String,
        current: String?
    ) {
        self.inbox = inbox
        self.workspaces = workspaces
        self.workspaceId = workspaceId
        self.threadKey = threadKey
        self.current = current
    }

    /// Read the roster, viewers left out.
    ///
    /// ⚠️ THE CURRENT ASSIGNEE STAYS LISTED even when the roster no longer holds them
    /// (removed since, or the read raced a change), as the web's picker does, so the
    /// tick has a row to sit on.
    func load() async {
        switch await workspaces.members(workspaceId: workspaceId) {
        case let .success(response):
            members = .ready(Self.assignable(response.members, current: current))
        case let .failure(error):
            members = .failed(FailureText.from(error))
        }
    }

    /// Assign the thread, or unassign it with nil. True when the server affirmed it.
    func assign(_ email: String?) async -> Bool {
        guard !saving else { return false }
        saving = true
        failure = nil
        let outcome = await inbox.assign(workspaceId: workspaceId, threadKey: threadKey, assigneeEmail: email)
        saving = false
        switch outcome {
        case .success:
            return true
        case let .failure(error):
            failure = FailureText.from(error)
            return false
        }
    }

    /// The addresses the sheet offers, in the roster's order.
    static func assignable(_ roster: [WorkspaceMember], current: String?) -> [String] {
        var emails = roster
            .filter { $0.role.lowercased() != WorkspaceRole.viewer.rawValue }
            .map(\.email)
        if let current, !emails.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            emails.append(current)
        }
        return emails
    }
}
