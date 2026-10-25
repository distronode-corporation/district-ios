import Foundation

/// What the watch-face complications show: availability for calls, and the unread count.
///
/// ⛔ TWO COMPLICATIONS, AND THE UNREAD COUNT IS OPT-IN (Sean, 2026-10-24, GitLab #2 note
/// 4083623386, reversing 3.1.0's "no unread count"). A number on a watch face is read by
/// whoever is beside you, so it is never part of the availability complication: it is a
/// second one, ``unreadWidgetKind``, that a person adds to a face on purpose. It shows a
/// count only, never a name or a preview, and the count is `.privacySensitive()`, so a
/// lowered wrist or a locked watch redacts it.
///
/// ⛔ WRITTEN BY THE WATCH APP, READ BY THE WIDGET, THROUGH THE APP GROUP. The widget runs in
/// its own process and has no WatchConnectivity session; the watch app writes this after
/// every snapshot and asks WidgetKit to reload. Compiled into both targets.
struct ComplicationState: Codable, Equatable, Sendable {
    static let appGroup = "group.com.distronode.district.watch"
    static let defaultsKey = "complication.state"
    /// ⚠️ EACH `kind` NAMED ONCE: the widget declares it and the app reloads by it.
    /// ⛔ NEVER RENAMED: a face holds a complication by its kind, and a new string removes it
    /// from every face it was on.
    static let widgetKind = "com.distronode.district.complication.availability"
    /// The opt-in unread complication. See the type.
    static let unreadWidgetKind = "com.distronode.district.complication.unread"

    var signedIn: Bool
    var workspaceName: String?
    /// nil when unknown: no workspace, or the phone could not read it.
    var available: Bool?
    /// `en` or `fr-CA`, the phone's choice.
    var language: String?
    /// The workspace's unread messages; nil when unknown, which is not zero.
    /// ⚠️ AN OPTIONAL `var`, so a state a 3.1.0 watch app wrote (no such key) still decodes
    /// and the memberwise initialiser defaults it to nil for every caller that predates it.
    var unreadCount: Int?
    /// When the watch app saw availability switch, for the Smart Stack (``relevance(forKind:at:)``).
    /// ⚠️ OPTIONAL, LIKE ``unreadCount``, for a state an older watch app wrote. Set only by
    /// ``stamped(after:at:)``, never from a snapshot.
    var availabilityChangedAt: Date?

    /// Nothing heard from the phone yet.
    static let unknown = ComplicationState(signedIn: false, workspaceName: nil, available: nil, language: nil)

    /// The shared defaults suite, or nil when the App Group is not provisioned (a build
    /// signed without the entitlement): the complication then shows its unknown state.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func load(from defaults: UserDefaults?) -> ComplicationState {
        guard let data = defaults?.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(ComplicationState.self, from: data)
        else { return .unknown }
        return state
    }

    /// The complications whose drawing changes between two states, by kind.
    ///
    /// ⚠️ WidgetKit BUDGETS RELOADS PER WIDGET, so a new unread count must not spend the
    /// availability complication's, and a switched availability not the unread one's.
    /// Sign-in and the language are drawn by both.
    static func kindsToReload(from old: ComplicationState, to new: ComplicationState) -> [String] {
        var kinds: [String] = []
        let shared = old.signedIn != new.signedIn || old.language != new.language
        if shared || old.workspaceName != new.workspaceName || old.available != new.available {
            kinds.append(widgetKind)
        }
        if shared || old.unreadCount != new.unreadCount {
            kinds.append(unreadWidgetKind)
        }
        return kinds
    }

    /// This state with ``availabilityChangedAt`` carried over from `old`, or set to `now` when
    /// availability switched between two KNOWN values.
    ///
    /// ⚠️ UNKNOWN TO KNOWN IS NOT A SWITCH: a first snapshot, or one after the phone could not
    /// read it, would otherwise push the complication up the Smart Stack for nothing. ⛔ Signed
    /// out keeps no stamp, as it keeps nothing else of the account.
    func stamped(after old: ComplicationState, at now: Date) -> ComplicationState {
        var next = self
        guard signedIn else {
            next.availabilityChangedAt = nil
            return next
        }
        if let before = old.available, let after = available, before != after {
            next.availabilityChangedAt = now
        } else {
            next.availabilityChangedAt = old.availabilityChangedAt
        }
        return next
    }

    func save(to defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - The Smart Stack

/// How far up the Smart Stack a complication asks to be, and for how long.
///
/// ⚠️ PLAIN VALUES, SO THE WATCH TESTS CAN READ THEM: the widget turns this into a
/// `TimelineEntryRelevance` (watchOS 9 and later; RelevanceKit is newer than the floor of 10).
/// A `duration` of 0 holds until the next entry, which is WidgetKit's own meaning.
struct ComplicationRelevance: Equatable, Sendable {
    let score: Float
    let duration: TimeInterval

    static let none = ComplicationRelevance(score: 0, duration: 0)
}

extension ComplicationState {
    /// How long a switched availability stays worth surfacing.
    static let availabilityChangeWindow: TimeInterval = 30 * 60

    /// The relevance of the complication of `kind` in this state.
    ///
    /// ⛔ HIGHER ONLY WHEN THERE IS SOMETHING TO SEE: unread messages (more of them, higher,
    /// capped at 10), or availability that switched in the last
    /// ``availabilityChangeWindow``. Signed out, unknown or nothing new is ``ComplicationRelevance/none``,
    /// and the stack keeps its own order.
    func relevance(forKind kind: String, at now: Date) -> ComplicationRelevance {
        guard signedIn else { return .none }
        switch kind {
        case Self.unreadWidgetKind:
            guard let count = unreadCount, count > 0 else { return .none }
            return ComplicationRelevance(score: 50 + Float(min(count, 10)) * 5, duration: 0)
        case Self.widgetKind:
            guard available != nil, let changed = availabilityChangedAt else { return .none }
            let elapsed = now.timeIntervalSince(changed)
            guard elapsed >= 0, elapsed < Self.availabilityChangeWindow else { return .none }
            return ComplicationRelevance(score: 100, duration: Self.availabilityChangeWindow - elapsed)
        default:
            return .none
        }
    }
}
