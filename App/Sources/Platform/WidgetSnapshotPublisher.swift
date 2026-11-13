import Foundation
import WidgetKit

/// Keeps the Home Screen widget's snapshot (``WidgetSnapshot``) in step with what the app
/// has just read, and asks WidgetKit to redraw.
///
/// ⛔ ONLY FROM READS THE APP ALREADY DOES. The unread count comes from the same place the
/// app icon's badge does (``UnreadBadge``), the week's calls from Overview, and the name
/// from the selected workspace. Nothing here makes a request.
///
/// ⛔ SIGN-OUT CLEARS IT, so a signed-out phone's Home Screen shows no workspace and no
/// counts. Every sign-out path calls ``signedOut()``.
///
/// ⛔ A READ THAT ANSWERS LATE NEVER PUTS BACK WHAT A SIGN-OUT OR A SWITCH TOOK AWAY (cubic,
/// #112). Only the workspace list starts a snapshot, and it passes the ``session`` it began
/// in, which every sign-out advances. A count lands only on the snapshot that names the
/// workspace it was read for, so one read for another workspace, or before a sign-out
/// cleared the snapshot, is dropped.
@MainActor
enum WidgetSnapshotPublisher {
    static var store: any WidgetSnapshotStoring = WidgetSnapshotKeychain()
    static var now: () -> Date = { Date() }
    static var reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotKind.summary) }

    /// Advanced by every sign-out. A workspace-list read captures it BEFORE it awaits.
    private(set) static var session = 0

    /// ⚠️ A SIGN-OUT WHOSE DELETE FAILED. It is retried before anything else is written, and
    /// no count lands while it stands (the snapshot still names the account that left). A
    /// relaunch signed out retries it too: ``SessionModel/refreshPhase()`` signs out again.
    private static var clearPending = false

    /// The selected workspace, from a workspace-list read that began in `session`.
    static func selected(workspaceId: String, name: String, session began: Int) {
        guard began == session, settled() else { return }
        let current = store.read() ?? WidgetSnapshot(updatedAt: now())
        save(current.selecting(workspaceId: workspaceId, name: name, at: now()))
    }

    /// A complete list with no workspace to select (none, or all lapsed): nothing to show.
    /// ⚠️ NOT a degraded answer, which is "we could not look": the caller keeps the last one.
    static func noWorkspace(session began: Int) {
        guard began == session else { return }
        clear()
    }

    static func unread(_ count: Int, workspaceId: String) {
        update(workspaceId) { $0.unreadMessages = max(0, count) }
    }

    static func callsThisWeek(_ count: Int, workspaceId: String) {
        update(workspaceId) {
            $0.callsThisWeek = max(0, count)
            $0.callsReadAt = now()
        }
    }

    static func signedOut() {
        session += 1
        clear()
    }

    private static func update(_ workspaceId: String, _ change: (inout WidgetSnapshot) -> Void) {
        guard settled(), var snapshot = store.read(), snapshot.workspaceId == workspaceId else { return }
        change(&snapshot)
        snapshot.updatedAt = now()
        save(snapshot)
    }

    private static func save(_ snapshot: WidgetSnapshot) {
        guard snapshot != store.read() else { return }
        // ⚠️ A FAILED WRITE COSTS ONLY THE WIDGET'S FRESHNESS; the next read retries.
        try? store.write(snapshot)
        reload()
    }

    private static func clear() {
        do {
            try store.clear()
            clearPending = false
        } catch {
            clearPending = true
        }
        reload()
    }

    /// True once no failed sign-out delete is outstanding, retrying it first.
    private static func settled() -> Bool {
        guard clearPending else { return true }
        clear()
        return !clearPending
    }
}
