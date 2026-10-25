import AppIntents
import DistrictData
import DistrictModel
import Foundation

// MARK: - The logic

/// The workspace an intent acts in: the one the app has selected.
struct IntentWorkspace: Equatable {
    let id: String
    let name: String
}

/// What the intents read and write, behind a seam so a test can stand in for the server.
@MainActor
protocol IntentSourcing {
    /// The session first, then the selected workspace; a failure is the sentence to say.
    func workspace() async -> Result<IntentWorkspace, WatchActionFailure>
    func saveAvailability(workspaceId: String, available: Bool) async -> Result<AvailabilityResponse, ApiError>
    func conversations(workspaceId: String) async -> Result<[ConversationSummary], ApiError>
    /// Availability moved: the watch's switch and complication should hear of it.
    func availabilityChanged()
}

/// The watch's "Read my latest message", answered on the phone. See ``WatchBridgeService``.
@MainActor
protocol LatestMessageReading {
    func latestMessage(workspaceId: String) async -> Result<WatchSnapshot.Conversation?, WatchActionFailure>
}

/// "Set my availability" and "Read my latest message" (3.2), for Siri, Shortcuts and the watch.
///
/// ⛔ NO NEW SERVER CALL: availability is ``CallHandlingRepository``'s PATCH, as the Account row
/// and the watch's switch make it, and the latest message is the inbox's conversation list, as
/// the watch snapshot reads it. ⛔ "Read" IS DISPLAY-ONLY: nothing is marked read.
///
/// ⚠️ EVERY ANSWER IS A SENTENCE IN THE PERSON'S LANGUAGE, because Siri says it and Shortcuts
/// shows it; a failure is the same sentence the screens would show.
@MainActor
struct IntentRunner: LatestMessageReading {
    let sources: any IntentSourcing

    func setAvailability(_ available: Bool) async -> String {
        let workspace: IntentWorkspace
        switch await sources.workspace() {
        case let .success(found):
            workspace = found
        case let .failure(failure):
            return failure.sentence
        }
        switch await sources.saveAvailability(workspaceId: workspace.id, available: available) {
        case let .success(response):
            sources.availabilityChanged()
            // ⛔ THE SERVER'S ANSWER, NOT THE ONE ASKED FOR: a viewer and somebody with no member
            // row get a 200 with a reason, and the reason is what is true.
            if response.reason != nil {
                return WatchSnapshotComposer.availability(response, workspaceId: workspace.id).note
                    ?? AvailabilityCopy.reasonUnknown
            }
            return response.availableForCalls
                ? IntentCopy.availabilityOn(workspace.name)
                : IntentCopy.availabilityOff(workspace.name)
        case let .failure(error):
            return FailureText.from(error).message
        }
    }

    /// The sentence for "Read my latest message" on the phone.
    func latestMessageSentence() async -> String {
        let workspace: IntentWorkspace
        switch await sources.workspace() {
        case let .success(found):
            workspace = found
        case let .failure(failure):
            return failure.sentence
        }
        switch await latestMessage(workspaceId: workspace.id) {
        case let .success(conversation?):
            let line = LatestMessageLine(conversation)
            return line.outbound
                ? IntentCopy.latestOutbound(line.name, text: line.text)
                : IntentCopy.latestInbound(line.name, text: line.text)
        case .success(nil):
            return IntentCopy.noMessages
        case let .failure(failure):
            return failure.sentence
        }
    }

    /// The newest conversation in one workspace, as a watch row says it; nil for an empty inbox.
    ///
    /// ⚠️ THE NEWEST BY ITS LAST MESSAGE'S TIME, not by the list's order, so a list sorted any
    /// other way (unread first, say) still answers the newest. A time that cannot be read sorts
    /// last; ties keep the list's order.
    func latestMessage(workspaceId: String) async -> Result<WatchSnapshot.Conversation?, WatchActionFailure> {
        await sources.conversations(workspaceId: workspaceId)
            .map { rows in
                Self.newest(rows).map { WatchSnapshotComposer.conversation($0, workspaceId: workspaceId) }
            }
            .mapError { WatchActionFailure(sentence: FailureText.from($0).message) }
    }

    static func newest(_ rows: [ConversationSummary]) -> ConversationSummary? {
        var best: (row: ConversationSummary, at: Date)?
        for row in rows {
            let at = WireInstant.parse(row.lastMessage.createdAt) ?? .distantPast
            if best == nil || at > (best?.at ?? .distantPast) {
                best = (row, at)
            }
        }
        return best?.row
    }
}

/// The container's repositories and session, for ``IntentRunner``.
///
/// ⛔ THE CONTAINER'S OWN, like ``ContainerWatchSnapshotSource``: one coordinator per process,
/// and the workspace ``WorkspaceSessionModel`` resolves, never re-derived.
@MainActor
final class ContainerIntentSources: IntentSourcing {
    private unowned let container: AppContainer

    init(container: AppContainer) {
        self.container = container
    }

    func workspace() async -> Result<IntentWorkspace, WatchActionFailure> {
        switch await container.coordinator.accessToken() {
        case .available:
            break
        case let .reauthRequired(reason):
            let text = SessionModel.text(for: reason)
            return .failure(WatchActionFailure(sentence: text.isEmpty ? SessionCopy.sessionHasEndedPlease : text))
        case let .retryLater(reason):
            return .failure(WatchActionFailure(sentence: SessionModel.text(for: reason)))
        }
        let workspaces = WorkspaceSessionModel(container: container)
        await workspaces.load()
        if let entry = workspaces.selectedEntry {
            return .success(IntentWorkspace(id: entry.id, name: entry.name))
        }
        switch workspaces.state {
        case let .failed(failure):
            return .failure(WatchActionFailure(sentence: failure.message))
        case let .degraded(sentence):
            return .failure(WatchActionFailure(sentence: sentence))
        default:
            return .failure(WatchActionFailure(sentence: IntentCopy.noWorkspace))
        }
    }

    func saveAvailability(workspaceId: String, available: Bool) async -> Result<AvailabilityResponse, ApiError> {
        await container.callHandling.saveAvailability(workspaceId: workspaceId, availableForCalls: available)
    }

    func conversations(workspaceId: String) async -> Result<[ConversationSummary], ApiError> {
        await container.inbox.conversations(workspaceId: workspaceId).map(\.conversations)
    }

    func availabilityChanged() {
        container.watchBridge.setNeedsSnapshot()
    }
}

/// Where an intent finds the app's one ``IntentRunner``.
///
/// ⛔ A PROCESS-WIDE SLOT, FILLED IN `DistrictApp.init`, for the reason ``NotificationActionInbox``
/// is one: Siri runs an intent in a background launch with no scene, and `init` is what runs on
/// every launch. It holds the container's runner and builds nothing.
@MainActor
enum AppIntentHost {
    static var runner: IntentRunner?
}

// MARK: - The intents

/// "Set my availability": whether calls in the selected workspace ring this person.
struct SetAvailabilityIntent: AppIntent {
    static let title = LocalizedStringResource("Set my availability", table: "AppIntents")
    static let description = IntentDescription(
        LocalizedStringResource("Turn calls to you on or off in your current workspace.", table: "AppIntents")
    )

    @Parameter(
        title: LocalizedStringResource("Available for calls", table: "AppIntents"),
        requestValueDialog: IntentDialog(LocalizedStringResource("Should calls ring you?", table: "AppIntents"))
    )
    var available: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sentence = await AppIntentHost.runner?.setAvailability(available) ?? IntentCopy.noWorkspace
        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }
}

/// "Read my latest message": the newest conversation, said and shown. ⛔ Marks nothing read.
struct ReadLatestMessageIntent: AppIntent {
    static let title = LocalizedStringResource("Read my latest message", table: "AppIntents")
    static let description = IntentDescription(
        LocalizedStringResource(
            "Shows the newest conversation in your inbox. Nothing is marked read.",
            table: "AppIntents"
        )
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sentence = await AppIntentHost.runner?.latestMessageSentence() ?? IntentCopy.noWorkspace
        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }
}

/// The phrases Siri listens for. ⚠️ Localised by `AppShortcuts.strings` (`l10n/appshortcuts.toml`),
/// whose keys are these phrases exactly as written here.
struct DistrictShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetAvailabilityIntent(),
            phrases: [
                "Set my availability in \(.applicationName)",
                "Change my availability in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Availability", table: "AppIntents"),
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: ReadLatestMessageIntent(),
            phrases: [
                "Read my latest message in \(.applicationName)",
                "What is my latest \(.applicationName) message",
            ],
            shortTitle: LocalizedStringResource("Latest message", table: "AppIntents"),
            systemImageName: "message.fill"
        )
    }
}
