import Foundation
import Observation

/// What the watch is showing.
enum WatchPhase: Equatable {
    /// Nothing heard from the phone yet, and nothing kept from before.
    case waiting
    /// ⛔ THE PHONE SPEAKS ANOTHER VERSION. Nothing it sent is shown.
    case versionMismatch
    case signedOut
    /// Signed in; the snapshot may still have no workspace.
    case ready(WatchSnapshot)
}

/// Where one write stands, for the screen that started it.
enum WatchWriteState: Equatable {
    case sending
    case succeeded(String)
    /// ⛔ THE TITLE SAYS WHAT DID NOT HAPPEN, THE REASON IS THE PHONE'S OWN SENTENCE. A failed
    /// reply must never read as sent.
    case failed(title: String, reason: String)
    /// ⛔ "iPhone not reachable", said before anything is sent.
    case unreachable
}

/// The watch app's one model: the phone's latest snapshot and the writes in flight.
///
/// ⛔ IT MAKES NO REQUEST OF ITS OWN. Everything it shows came from the phone, and every
/// write is a message to the phone answered `{ok}` or `{error}`.
@MainActor
@Observable
final class WatchStore {
    private(set) var phase: WatchPhase = .waiting

    /// Keyed by ``WriteKey``, so the availability switch and a thread's reply each show
    /// their own state.
    private(set) var writes: [String: WatchWriteState] = [:]

    private let link: any PhoneLinking
    private let persistence: any SnapshotPersisting
    private let complication: any ComplicationPublishing

    init(
        link: any PhoneLinking,
        persistence: any SnapshotPersisting,
        complication: any ComplicationPublishing
    ) {
        self.link = link
        self.persistence = persistence
        self.complication = complication
    }

    /// The snapshot on screen, when signed in.
    var snapshot: WatchSnapshot? {
        guard case let .ready(snapshot) = phase else { return nil }
        return snapshot
    }

    /// Show what was kept from last time, then listen, then ask for a fresh picture.
    func start() {
        if let data = persistence.load() {
            apply(WatchSnapshot.read(data: data), persist: false)
        }
        link.activate { [weak self] reading in
            self?.apply(reading)
        }
        refresh()
    }

    /// Ask the phone for a fresh snapshot. Fire and forget: the snapshot arrives as an
    /// application context, and an unreachable phone leaves the stale banner to say so.
    func refresh() {
        guard link.isReachable else { return }
        Task { _ = await link.send(WatchRequest(action: .refresh)) }
    }

    /// An application context from the phone.
    func apply(_ reading: WatchSnapshotReading) {
        apply(reading, persist: true)
    }

    private func apply(_ reading: WatchSnapshotReading, persist: Bool) {
        switch reading {
        case .unreadable:
            // ⚠️ KEEP WHAT IS SHOWN: an unreadable context says nothing about the account.
            return
        case .versionMismatch:
            phase = .versionMismatch
            WatchL10n.phoneLanguage = nil
            complication.publish(.unknown)
        case let .snapshot(snapshot):
            WatchL10n.phoneLanguage = snapshot.language
            phase = snapshot.signedIn ? .ready(snapshot) : .signedOut
            if persist, let data = try? snapshot.encoded() {
                persistence.save(data)
            }
            complication.publish(ComplicationState(snapshot))
            if !snapshot.signedIn {
                // ⛔ NOTHING OF THE LAST ACCOUNT SURVIVES A SIGN-OUT, a pending failure included.
                writes = [:]
            }
        }
    }

    // MARK: - Stale

    /// "Updated 20 min ago" once the snapshot is older than ``WatchSnapshot/staleAfter``,
    /// otherwise nil.
    func staleBanner(at now: Date) -> String? {
        guard let snapshot, snapshot.isStale(at: now) else { return nil }
        return WatchCopy.updated(WatchL10n.relative(snapshot.generatedAt, to: now))
    }

    /// A call's time against the watch's own clock, which keeps moving after the snapshot.
    func relativeTime(of call: WatchSnapshot.Call, at now: Date) -> String {
        guard let occurredAt = call.occurredAt else { return call.relativeTime }
        return WatchL10n.relative(occurredAt, to: now)
    }

    // MARK: - Writes

    func setAvailable(_ available: Bool) async {
        guard let availability = snapshot?.availability, availability.canToggle else { return }
        await perform(
            .setAvailability(workspaceId: availability.workspaceId, available: available),
            key: WriteKey.availability,
            succeeded: nil,
            failureTitle: WatchCopy.availabilityFailed
        )
    }

    func reply(_ text: String, to conversation: WatchSnapshot.Conversation) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, conversation.canReply else { return }
        await perform(
            .reply(workspaceId: conversation.workspaceId, threadKey: conversation.id, text: trimmed),
            key: WriteKey.reply(conversation.id),
            succeeded: WatchCopy.replySent,
            failureTitle: WatchCopy.replyNotSent
        )
    }

    func markRead(_ conversation: WatchSnapshot.Conversation) async {
        await perform(
            .markRead(workspaceId: conversation.workspaceId, threadKey: conversation.id),
            key: WriteKey.markRead(conversation.id),
            succeeded: WatchCopy.markedRead,
            failureTitle: WatchCopy.markReadFailed
        )
    }

    func dismissWrite(_ key: String) {
        writes[key] = nil
    }

    #if DEBUG
        /// The debug preview screens only (``WatchPreviewSeam``). Compiled out of Release.
        func preview(_ reading: WatchSnapshotReading, writes: [String: WatchWriteState] = [:]) {
            apply(reading, persist: false)
            self.writes = writes
        }
    #endif

    /// ⛔ ONE REQUEST PER TAP. A second tap while the first is on its way is dropped: a
    /// reply sent twice is two messages to a customer.
    private func perform(_ action: WatchAction, key: String, succeeded: String?, failureTitle: String) async {
        guard writes[key] != .sending else { return }
        guard link.isReachable else {
            writes[key] = .unreachable
            return
        }
        writes[key] = .sending
        switch await link.send(WatchRequest(action: action)) {
        case let .reply(reply) where reply.ok:
            writes[key] = succeeded.map(WatchWriteState.succeeded)
        case let .reply(reply):
            writes[key] = .failed(title: failureTitle, reason: reply.error ?? WatchCopy.iphoneDidNotAnswer)
        case .unreachable:
            writes[key] = .unreachable
        case .noAnswer:
            writes[key] = .failed(title: failureTitle, reason: WatchCopy.iphoneDidNotAnswer)
        }
    }
}

/// The keys of ``WatchStore/writes``.
enum WriteKey {
    static let availability = "availability"

    static func reply(_ threadKey: String) -> String {
        "reply:\(threadKey)"
    }

    static func markRead(_ threadKey: String) -> String {
        "mark-read:\(threadKey)"
    }
}

extension ComplicationState {
    init(_ snapshot: WatchSnapshot) {
        self.init(
            signedIn: snapshot.signedIn,
            workspaceName: snapshot.workspace?.name,
            available: snapshot.availability?.available,
            language: snapshot.language
        )
    }
}
