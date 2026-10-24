import DistrictAuthCore
import DistrictData
import DistrictModel
import Foundation

/// The watch's picture, read from the container's repositories.
///
/// ⛔ THE CONTAINER'S OWN REPOSITORIES AND COORDINATOR, NEVER NEW ONES: one
/// ``TokenRefreshCoordinator`` per process (see the ⛔ on ``AppContainer``). `unowned`
/// because the container owns the service that owns this, and outlives both.
///
/// ⛔ THE WORKSPACE IS RESOLVED BY ``WorkspaceSessionModel``, NOT RE-DERIVED. The
/// precedence (this device's choice, the account default, the server's first) is the
/// rule a second copy would get wrong; ``AvailabilityModel`` makes the same call.
@MainActor
final class ContainerWatchSnapshotSource: WatchSnapshotSourcing {
    private unowned let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    func snapshot(at now: Date) async -> WatchSnapshot? {
        let language = WatchBridgeLanguage.current
        switch await container.coordinator.accessToken() {
        case .available:
            break
        case .reauthRequired:
            return .signedOut(at: now, language: language)
        case .retryLater:
            return nil
        }
        let workspaces = WorkspaceSessionModel(container: container)
        await workspaces.load()
        guard let entry = workspaces.selectedEntry else {
            return WatchSnapshotComposer.noWorkspace(at: now, language: language)
        }
        let id = entry.id
        let callHandling = container.callHandling
        let inbox = container.inbox
        let pager = container.calls.pager(workspaceId: id)
        // ⚠️ FOUR INDEPENDENT READS, IN PARALLEL, AND EACH FAILS ON ITS OWN: a call log that
        // could not be read must not blank an inbox that answered.
        async let availability = callHandling.availability(workspaceId: id)
        async let unread = inbox.unreadCount(workspaceId: id)
        async let conversations = inbox.conversations(workspaceId: id)
        async let calls = pager.loadNext(limit: WatchSnapshot.listLimit)
        return await WatchSnapshotComposer.compose(
            WatchSnapshotComposer.Reads(
                workspaceId: id,
                workspaceName: entry.name,
                availability: availability,
                unread: unread,
                conversations: conversations.map(\.conversations),
                calls: calls.map(\.items)
            ),
            at: now,
            language: language
        )
    }
}

/// Wire rows to display-ready watch rows. Pure, so the tests can feed it.
///
/// ⛔ EVERY STRING GOES THROUGH THE PHONE SCREENS' OWN MAPPERS (``CallDisplay``,
/// ``ConversationDisplay``, ``AvailabilityCopy``), so the watch says what the phone says
/// about the same call, and in the same language.
@MainActor
enum WatchSnapshotComposer {
    struct Reads {
        let workspaceId: String
        let workspaceName: String
        let availability: Result<AvailabilityResponse, ApiError>
        let unread: Result<UnreadCountResponse, ApiError>
        let conversations: Result<[ConversationSummary], ApiError>
        let calls: Result<[CallSummary], ApiError>
    }

    /// The longest preview line the watch is sent. A wrist shows two lines of it at most.
    nonisolated static let previewLimit = 100

    static func noWorkspace(at now: Date, language: String) -> WatchSnapshot {
        WatchSnapshot(
            protocolVersion: WatchSnapshot.currentProtocolVersion,
            generatedAt: now,
            language: language,
            signedIn: true,
            workspace: nil,
            availability: nil,
            unreadCount: nil,
            calls: nil,
            conversations: nil
        )
    }

    static func compose(_ reads: Reads, at now: Date, language: String) -> WatchSnapshot {
        WatchSnapshot(
            protocolVersion: WatchSnapshot.currentProtocolVersion,
            generatedAt: now,
            language: language,
            signedIn: true,
            workspace: .init(id: reads.workspaceId, name: reads.workspaceName),
            availability: try? reads.availability.map { availability($0, workspaceId: reads.workspaceId) }.get(),
            unreadCount: try? reads.unread.map(\.count).get(),
            calls: try? reads.calls.map { rows in
                rows.prefix(WatchSnapshot.listLimit).map { call($0, now: now, language: language) }
            }.get(),
            conversations: try? reads.conversations.map { rows in
                rows.prefix(WatchSnapshot.listLimit).map { conversation($0, workspaceId: reads.workspaceId) }
            }.get()
        )
    }

    static func availability(_ response: AvailabilityResponse, workspaceId: String) -> WatchSnapshot.Availability {
        WatchSnapshot.Availability(
            workspaceId: workspaceId,
            available: response.availableForCalls,
            canToggle: response.reason == nil,
            note: response.reason.map { reason in
                switch reason {
                case AvailabilityReason.role: AvailabilityCopy.reasonRole
                case AvailabilityReason.noMemberRow: AvailabilityCopy.reasonNoMemberRow
                default: AvailabilityCopy.reasonUnknown
                }
            }
        )
    }

    static func call(_ row: CallSummary, now: Date, language: String) -> WatchSnapshot.Call {
        let display = CallDisplay(row)
        let occurredAt = WireInstant.parse(row.createdAt)
        var outcome = display.statusLabel
        if let transfer = display.transferLabel {
            outcome += " · \(transfer)"
        }
        return WatchSnapshot.Call(
            id: row.id,
            caller: display.displayName.map(WatchMasking.caller) ?? display.callerLabel,
            direction: display.directionLabel,
            time: display.time,
            relativeTime: occurredAt.map { relative($0, to: now, language: language) } ?? display.time,
            occurredAt: occurredAt,
            outcome: outcome,
            duration: display.durationLabel
        )
    }

    static func conversation(_ row: ConversationSummary, workspaceId: String) -> WatchSnapshot.Conversation {
        let display = ConversationDisplay(row)
        return WatchSnapshot.Conversation(
            id: row.threadKey,
            workspaceId: workspaceId,
            title: WatchMasking.caller(display.title),
            preview: shortened(display.subtitle),
            unread: row.unreadCount > 0,
            canReply: row.replyTarget != nil
        )
    }

    /// "5 min ago", in the phone's language.
    static func relative(_ date: Date, to now: Date, language: String) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: language == "fr-CA" ? "fr_CA" : "en_CA")
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// ⚠️ IN `Character`s, LIKE THE PHONE'S OWN PREVIEW, so an emoji is never cut in half.
    private static func shortened(_ line: String) -> String {
        guard line.count > previewLimit else { return line }
        return String(line.prefix(previewLimit)) + "…"
    }
}

/// What a wrist shows of a phone number.
///
/// ⛔ A WATCH FACE IS READ BY WHOEVER IS BESIDE YOU, so a caller known only by number shows
/// the last four digits, which is enough to recognise a number you expect and no more. A
/// contact's name is shown as it is: the person chose to save it.
enum WatchMasking {
    static func caller(_ label: String) -> String {
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        guard label.unicodeScalars.allSatisfy(allowed.contains) else { return label }
        let digits = label.filter(\.isNumber)
        guard digits.count > 4 else { return label }
        return "••• \(digits.suffix(4))"
    }
}
