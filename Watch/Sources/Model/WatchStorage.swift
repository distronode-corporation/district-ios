import Foundation
import WatchKit
import WidgetKit

/// Where the last snapshot is kept between launches.
@MainActor
protocol SnapshotPersisting {
    func load() -> Data?
    func save(_ data: Data)
}

/// Hands the complication its state.
@MainActor
protocol ComplicationPublishing {
    func publish(_ state: ComplicationState)
}

/// The last snapshot, in the App Group's defaults.
///
/// ⚠️ KEPT SO A COLD LAUNCH SHOWS SOMETHING AT ONCE, with its age, rather than "waiting"
/// until the phone answers. A signed-out snapshot overwrites it, which is what clears the
/// last account from the wrist.
struct GroupSnapshotStore: SnapshotPersisting {
    static let key = "watch.snapshot"

    func load() -> Data? {
        ComplicationState.defaults?.data(forKey: Self.key)
    }

    func save(_ data: Data) {
        ComplicationState.defaults?.set(data, forKey: Self.key)
    }
}

/// Writes the complications' state where the widgets read it, then asks WidgetKit to reload.
///
/// ⚠️ ONLY THE KINDS THAT CHANGED: WidgetKit budgets reloads per widget, and a snapshot that
/// moved only the call list must not spend one. See ``ComplicationState/kindsToReload(from:to:)``.
struct WidgetComplicationPublisher: ComplicationPublishing {
    ///
    /// ⚠️ STAMPED HERE, against the state the widget last read, so the Smart Stack learns when
    /// availability switched (``ComplicationState/stamped(after:at:)``).
    func publish(_ state: ComplicationState) {
        let defaults = ComplicationState.defaults
        let old = ComplicationState.load(from: defaults)
        let next = state.stamped(after: old, at: Date())
        let kinds = ComplicationState.kindsToReload(from: old, to: next)
        guard !kinds.isEmpty else { return }
        next.save(to: defaults)
        for kind in kinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}

/// The watch app's background refresh, behind a seam so a test can stand in for the system.
@MainActor
protocol BackgroundRefreshScheduling {
    /// Ask for the next refresh, ``WatchBackgroundRefresh/interval`` from now.
    func scheduleNext()
    /// Whether the unread complication is on any face, so a refresh is worth a phone wake.
    func unreadComplicationIsOnAFace() async -> Bool
}

/// No background refresh: the debug preview screens, and the default in tests.
struct NoBackgroundRefresh: BackgroundRefreshScheduling {
    func scheduleNext() {}

    func unreadComplicationIsOnAFace() async -> Bool {
        false
    }
}

/// `WKApplicationRefreshBackgroundTask`s, delivered to ``WatchAppDelegate``, which
/// ``DistrictAIWatchApp`` installs.
///
/// ⚠️ ONE REQUEST AT A TIME, BY THE SYSTEM'S RULE: scheduling replaces the one pending, so
/// scheduling on every launch and every refresh keeps exactly one. ⚠️ ~15 MINUTES IS A WISH,
/// NOT A PROMISE: watchOS spreads background refreshes over its own budget (about four an
/// hour for an app with a complication on the active face), and a scheduling error has no
/// one to tell.
struct WatchBackgroundRefresh: BackgroundRefreshScheduling {
    static let interval: TimeInterval = 15 * 60

    func scheduleNext() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(Self.interval),
            userInfo: nil
        ) { _ in }
    }

    /// ⚠️ THE COMPLETION FORM: the async `currentConfigurations()` is watchOS 11, the floor 10.
    /// A failed read is "not on a face", which costs only a skipped wake.
    func unreadComplicationIsOnAFace() async -> Bool {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let installed = (try? result.get()) ?? []
                continuation.resume(returning: installed.contains { $0.kind == ComplicationState.unreadWidgetKind })
            }
        }
    }
}
