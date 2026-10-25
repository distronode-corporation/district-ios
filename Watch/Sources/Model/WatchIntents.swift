import AppIntents
import Foundation

/// "Set my availability" and "Read my latest message" on the watch (3.2).
///
/// ⛔ THE WATCH STILL MAKES NO REQUEST OF ITS OWN. Availability is the switch's own write
/// (``WatchStore/setAvailable(_:)``), and the latest message is asked of the phone
/// (``WatchAction/latestMessage(workspaceId:)``), which reads its inbox. ⛔ Display-only:
/// nothing is marked read.
///
/// ⚠️ AN INTENT CAN LAUNCH THE APP COLD, before WatchConnectivity has said the phone is in
/// reach, so a request waits a moment for it (``reachabilityWait``) rather than answering
/// "iPhone not reachable" for a phone that is on the table.
@MainActor
final class WatchIntentRunner {
    private let store: WatchStore
    private let link: any PhoneLinking
    private let reachabilityWait: Duration

    init(store: WatchStore, link: any PhoneLinking, reachabilityWait: Duration = .seconds(2)) {
        self.store = store
        self.link = link
        self.reachabilityWait = reachabilityWait
    }

    func setAvailability(_ available: Bool) async -> String {
        guard let snapshot = store.snapshot else { return WatchCopy.openIphone }
        guard let workspace = snapshot.workspace else { return WatchCopy.noWorkspace }
        guard let availability = snapshot.availability else { return WatchCopy.availabilityUnreadable }
        // ⛔ A REASON IS SAID, NOT WRITTEN AGAINST: the server would refuse it.
        guard availability.canToggle else { return availability.note ?? WatchCopy.availabilityUnreadable }
        await waitForPhone()
        await store.setAvailable(available)
        switch store.writes[WriteKey.availability] {
        case nil, .succeeded:
            return available ? WatchCopy.intentAvailabilityOn(workspace.name) : WatchCopy
                .intentAvailabilityOff(workspace.name)
        case let .failed(_, reason):
            return reason
        case .unreachable:
            return WatchCopy.iphoneNotReachable
        case .sending:
            // ⚠️ THE SWITCH'S OWN WRITE IS STILL ON ITS WAY, so this one was not sent.
            return WatchCopy.sending
        }
    }

    func latestMessage() async -> String {
        guard let snapshot = store.snapshot else { return WatchCopy.openIphone }
        guard let workspace = snapshot.workspace else { return WatchCopy.noWorkspace }
        await waitForPhone()
        guard link.isReachable else { return WatchCopy.iphoneNotReachable }
        switch await link.send(WatchRequest(action: .latestMessage(workspaceId: workspace.id))) {
        case let .reply(reply) where reply.ok:
            guard let conversation = reply.latestMessage else { return WatchCopy.intentNoMessages }
            let line = LatestMessageLine(conversation)
            return line.outbound
                ? WatchCopy.intentLatestOutbound(line.name, text: line.text)
                : WatchCopy.intentLatestInbound(line.name, text: line.text)
        case let .reply(reply):
            // ⚠️ AN OLDER PHONE ANSWERS "update both apps", which is the right thing to say.
            return reply.error ?? WatchCopy.iphoneDidNotAnswer
        case .unreachable:
            return WatchCopy.iphoneNotReachable
        case .noAnswer:
            return WatchCopy.iphoneDidNotAnswer
        }
    }

    private func waitForPhone() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: reachabilityWait)
        while !link.isReachable, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Where an intent and a long-look notification find the app's one store.
///
/// ⛔ A PROCESS-WIDE SLOT, FILLED IN ``DistrictAIWatchApp``'s `init`, which runs on every launch,
/// including the background one an intent causes and the one a notification interface needs.
/// The system builds intents and notification controllers itself, so nothing can be handed to
/// them. It holds the app's store and runner; it builds nothing.
@MainActor
enum WatchProcess {
    static var intents: WatchIntentRunner?
    static var store: WatchStore?
}

// MARK: - The intents

/// "Set my availability" on the watch. The same title and phrases as the iPhone's.
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
        let sentence = await WatchProcess.intents?.setAvailability(available) ?? WatchCopy.openIphone
        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }
}

/// "Read my latest message" on the watch. ⛔ Marks nothing read.
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
        let sentence = await WatchProcess.intents?.latestMessage() ?? WatchCopy.openIphone
        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }
}

/// The phrases Siri listens for on the watch. ⚠️ Localised by `AppShortcuts.strings`, whose
/// keys are these phrases exactly as written here (`l10n/appshortcuts.toml`).
struct DistrictWatchShortcuts: AppShortcutsProvider {
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
