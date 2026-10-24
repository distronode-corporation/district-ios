import Foundation
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

/// Writes the complication's state where the widget reads it, then asks WidgetKit to reload.
///
/// ⚠️ ONLY WHEN IT CHANGED: WidgetKit budgets reloads, and a snapshot that moved only the
/// call list must not spend one.
struct WidgetComplicationPublisher: ComplicationPublishing {
    func publish(_ state: ComplicationState) {
        let defaults = ComplicationState.defaults
        guard ComplicationState.load(from: defaults) != state else { return }
        state.save(to: defaults)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
