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
/// counts.
@MainActor
enum WidgetSnapshotPublisher {
    static var store: any WidgetSnapshotStoring = WidgetSnapshotKeychain()
    static var now: () -> Date = { Date() }
    static var reload: () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotKind.summary) }

    static func selected(workspace name: String) {
        let current = store.read() ?? WidgetSnapshot(updatedAt: now())
        save(current.selecting(workspace: name, at: now()))
    }

    static func unread(_ count: Int) {
        update { $0.unreadMessages = max(0, count) }
    }

    static func callsThisWeek(_ count: Int) {
        update { $0.callsThisWeek = max(0, count) }
    }

    static func signedOut() {
        store.clear()
        reload()
    }

    private static func update(_ change: (inout WidgetSnapshot) -> Void) {
        var snapshot = store.read() ?? WidgetSnapshot(updatedAt: now())
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
}

extension WidgetSnapshot {
    init(updatedAt: Date) {
        self.init(workspaceName: nil, unreadMessages: nil, callsThisWeek: nil, updatedAt: updatedAt)
    }
}
