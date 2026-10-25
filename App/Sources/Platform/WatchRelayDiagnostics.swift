import Foundation
import StoreKit

/// The watch relay's timing log, for the W0 device spike: how long a woken phone takes to
/// answer the watch, and how long a held socket lives before the system stops it.
///
/// ⛔ OFF UNLESS A TESTER TURNS IT ON, AND ONLY A TESTER CAN. The switch is on a hidden screen
/// (seven taps on the version line on Account) that exists only in a Debug or a TestFlight
/// build (``isAvailable()``); an App Store build never shows it. We have no watch in-house, so
/// the people running the spike are external TestFlight testers, and they send the log back
/// with the share sheet.
///
/// ⛔ TIMINGS ONLY, NEVER CONTENT. No transcript text, no number, no name: an entry is an event,
/// the tail of a call id, the app's state and durations. A tester may forward the export
/// anywhere.
///
/// ⚠️ KEPT IN A FILE, NOT ONLY IN MEMORY: the interesting runs end with the system killing the
/// app, and a log that died with it would hold nothing.
@MainActor
final class WatchRelayDiagnostics {
    /// The process's one log. ⚠️ A process-wide value like ``NotificationActionInbox/process``:
    /// the relay records from a background launch with no scene, and the screen reads it later.
    static let shared = WatchRelayDiagnostics()

    /// The defaults keys. ⚠️ Per device, and also settable as launch arguments in Debug
    /// (`-diagnostics.watchRelay YES`), like ``LiveKitCallEngine/diagnosticsKey``.
    static let recordingKey = "diagnostics.watchRelay"
    static let forceSocketKey = "diagnostics.watchRelaySocket"

    /// The most entries kept. Older ones are dropped from memory; the file is cut on export.
    static let entryLimit = 2000

    enum Event: String, Codable, Sendable {
        /// A request from the watch reached this process.
        case request
        /// Its answer went back; the detail carries how long it took.
        case reply
        /// The watch's own measure of the previous round trip.
        case watchRoundTrip
        /// A relay session started or ended, and why.
        case sessionStarted
        case sessionEnded
        /// A held socket opened, or was found closed (its lifetime in the detail).
        case socketOpened
        case socketDropped
        /// The system took the background time back.
        case backgroundExpired
        case failure
    }

    struct Entry: Codable, Equatable, Sendable {
        let at: Date
        let event: Event
        let detail: String
    }

    private let defaults: UserDefaults
    private let fileURL: URL?
    private(set) var entries: [Entry] = []

    /// When this process started, near enough: the first read of this log is when
    /// `AppContainer.watchBridge` builds its relay, at launch. A request seconds after it is a
    /// cold wake.
    let processStartedAt = Date()

    init(defaults: UserDefaults = .standard, fileURL: URL? = WatchRelayDiagnostics.defaultFileURL) {
        self.defaults = defaults
        self.fileURL = fileURL
        entries = Self.load(fileURL)
    }

    /// Whether timings are being recorded.
    var recording: Bool {
        get { defaults.bool(forKey: Self.recordingKey) }
        set { defaults.set(newValue, forKey: Self.recordingKey) }
    }

    /// The spike's switch: hold the socket while keepalives arrive, instead of the default
    /// snapshot per keepalive. See ``WatchLiveRelay/Mode``.
    var forceSocket: Bool {
        get { defaults.bool(forKey: Self.forceSocketKey) }
        set { defaults.set(newValue, forKey: Self.forceSocketKey) }
    }

    /// Record one event, when recording.
    func record(_ event: Event, _ detail: String = "", at date: Date = Date()) {
        guard recording else { return }
        let entry = Entry(at: date, event: event, detail: detail)
        entries.append(entry)
        if entries.count > Self.entryLimit {
            entries.removeFirst(entries.count - Self.entryLimit)
        }
        append(entry)
    }

    func clear() {
        entries = []
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// The log as plain text, for the share sheet: a header, then one line per entry.
    func export(header: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = entries.map { "\(formatter.string(from: $0.at)) \($0.event.rawValue) \($0.detail)" }
        return (header + [""] + lines).joined(separator: "\n") + "\n"
    }

    /// "5 s" since the process started, for a request's detail.
    func processAge(at date: Date) -> String {
        Self.seconds(date.timeIntervalSince(processStartedAt))
    }

    nonisolated static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.3fs", interval)
    }

    /// The last characters of an id: enough to tell two calls apart in one log, no more.
    nonisolated static func tail(_ id: String) -> String {
        String(id.suffix(6))
    }

    // MARK: - Who may see it

    /// ⛔ A DEBUG BUILD OR A TESTFLIGHT ONE, NEVER THE APP STORE'S. TestFlight builds run in
    /// the sandbox environment, which `AppTransaction` reports; an App Store build says
    /// `production`, and a failure to read it counts as production.
    static func isAvailable() async -> Bool {
        #if DEBUG
            return true
        #else
            guard let transaction = try? await AppTransaction.shared else { return false }
            switch transaction {
            case let .verified(value), let .unverified(value, _):
                return value.environment == .sandbox || value.environment == .xcode
            }
        #endif
    }

    // MARK: - The file

    nonisolated static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("watch-relay-diagnostics.jsonl")
    }

    private func append(_ entry: Entry) {
        guard let fileURL, var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: fileURL, options: .atomic)
        }
    }

    private static func load(_ fileURL: URL?) -> [Entry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        let entries = data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        return Array(entries.suffix(entryLimit))
    }
}
