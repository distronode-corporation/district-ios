import Foundation

/// What the watch-face complication shows: availability for calls, and nothing else.
///
/// ⛔ AVAILABILITY ONLY, PLUS THE WORKSPACE'S NAME WHERE IT FITS. No unread count, by
/// decision: a number on a watch face is read by whoever is beside you, and the question a
/// glance at the wrist answers is "will my phone ring".
///
/// ⛔ WRITTEN BY THE WATCH APP, READ BY THE WIDGET, THROUGH THE APP GROUP. The widget runs in
/// its own process and has no WatchConnectivity session; the watch app writes this after
/// every snapshot and asks WidgetKit to reload. Compiled into both targets.
struct ComplicationState: Codable, Equatable, Sendable {
    static let appGroup = "group.com.distronode.district.watch"
    static let defaultsKey = "complication.state"
    /// ⚠️ ONE `kind`, NAMED ONCE: the widget declares it and the app reloads by it.
    static let widgetKind = "com.distronode.district.complication.availability"

    var signedIn: Bool
    var workspaceName: String?
    /// nil when unknown: no workspace, or the phone could not read it.
    var available: Bool?
    /// `en` or `fr-CA`, the phone's choice.
    var language: String?

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

    func save(to defaults: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.defaultsKey)
    }
}
