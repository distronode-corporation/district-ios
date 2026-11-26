@testable import DistrictAI
import DistrictL10n
import DistrictModel
import SwiftUI
import XCTest

/// One conversation, opened on the recorded contact's thread the way the Inbox opens it
/// (`contact:<id>`), with the reply targets the conversation row carries.
///
/// ⚠️ THE TIMELINE'S ONE IMAGE IS TAKEN OUT. A received attachment is fetched anonymously
/// over `URLSession.shared` from a `.test` host, so the drawing would catch it loading or
/// failed depending on the resolver's timing; ``ThreadAttachmentSnapshotTests`` draws that
/// view over a fetch it controls.
final class ThreadScopeSnapshotTests: ScreenSnapshotTestCase {
    static let workspace = "ws-contract-test"
    static let threadKey = "contact:contact_contract_1"
    static let sms = ReplyTarget(to: "+14165551234", channel: MessageChannel.sms)
    static let email = ReplyTarget(to: "ada@contract.test", channel: MessageChannel.email)
    static let whatsApp = ReplyTarget(to: "+14165551234", channel: MessageChannel.whatsapp)
    static let messenger = ReplyTarget(to: "fb:1234567890", channel: MessageChannel.messenger)

    /// The recorded timeline without its received image, edited further by `edit`.
    static func timeline(_ edit: (inout [String: Any]) -> Void = { _ in }) -> FixtureTransport.Reply {
        .recorded("district-timeline") { json in
            json.editEach("timeline") { $0.removeValue(forKey: "mediaUrls") }
            edit(&json)
        }
    }

    /// What opening a thread reads and writes: the timeline, the mark-read, and no saved draft.
    static func replies(_ extra: [String: FixtureTransport.Reply] = [:]) -> [String: FixtureTransport.Reply] {
        [
            "/api/district/timeline": timeline(),
            "POST /api/district/messages/mark-read": .fixture("district-message-mark-read"),
            "GET /api/district/messages/drafts": .fixture("district-draft-null"),
        ].merging(extra) { $1 }
    }

    private func drawThread(
        _ replies: [String: FixtureTransport.Reply],
        targets: [ReplyTarget],
        role: WorkspaceRole? = .client,
        threadKey: String = ThreadScopeSnapshotTests.threadKey,
        devices: [Device] = [.iPhone],
        locales: [L10nLocale] = [.en, .frCA],
        testName: String = #function
    ) async throws {
        try await assertScreen(replies, devices: devices, locales: locales, testName: testName) { container in
            ThreadView(
                container: container,
                workspaceId: Self.workspace,
                role: role,
                threadKey: threadKey,
                replyTargets: targets,
                title: "Contract Test Caller"
            )
        }
    }

    // MARK: - The thread

    /// Calls and messages interleaved, with the SMS composer (badge, recipient, attach, draft, send).
    func testThreadSmsReply() async throws {
        try await drawThread(Self.replies(), targets: [Self.sms], devices: Device.allCases)
    }

    /// An email reply: the subject box, seeded `Re:` from the thread's last subject, and no attach.
    func testThreadEmailReply() async throws {
        try await drawThread(Self.replies(), targets: [Self.email])
    }

    /// Two reachable channels: the segmented picker, on the server's first choice.
    func testThreadChannelPicker() async throws {
        try await drawThread(Self.replies(), targets: [Self.sms, Self.email])
    }

    /// A viewer reads the thread with no composer at all (and sends no mark-read).
    func testThreadForAViewer() async throws {
        try await drawThread(Self.replies(), targets: [Self.sms], role: .viewer, locales: [.en])
    }

    /// A thread with no history still offers the composer under the empty sentence.
    func testThreadEmpty() async throws {
        try await drawThread(
            Self.replies(["/api/district/timeline": Self.timeline { $0["timeline"] = [Any]() }]),
            targets: [Self.sms]
        )
    }

    /// The server has older rows: the control to read them sits above the first event.
    func testThreadWithOlderMessages() async throws {
        let more = Self.timeline { json in
            json.editObject("pageInfo") { $0["hasMore"] = true }
        }
        try await drawThread(Self.replies(["/api/district/timeline": more]), targets: [Self.sms])
    }

    /// A row with an empty id cannot be placed, so it is dropped and the caption says part of
    /// the conversation could not be shown.
    func testThreadWithAnUnreadableRow() async throws {
        let broken = Self.timeline { json in
            var rows = json["timeline"] as? [[String: Any]] ?? []
            rows.append([
                "id": "",
                "type": "sms",
                "timestamp": "2026-08-15T14:25:00.000Z",
                "direction": "inbound",
                "body": "Unplaceable",
                "status": "received",
            ])
            json["timeline"] = rows
        }
        try await drawThread(Self.replies(["/api/district/timeline": broken]), targets: [Self.sms])
    }

    /// A refused read draws the failure with its retry, not an empty thread.
    func testThreadFailed() async throws {
        try await drawThread(Self.replies(["/api/district/timeline": .refused(500)]), targets: [Self.sms])
    }

    // MARK: - The saved draft

    /// A draft saved on another device comes back into an empty box, with its subject.
    ///
    /// ⚠️ Its image is taken out for the reason the timeline's is: a composer thumbnail is an
    /// `AsyncImage` over the anonymous URL, and nothing here can answer it.
    func testThreadRestoredDraft() async throws {
        let draft: FixtureTransport.Reply = .recorded("district-draft") { json in
            json.editObject("draft") { $0["mediaUrls"] = [Any]() }
        }
        try await drawThread(
            Self.replies(["GET /api/district/messages/drafts": draft]),
            targets: [Self.email]
        )
    }

    /// The draft read failed: said under the channel, with Try again, and the box stays usable.
    func testThreadDraftReadFailed() async throws {
        try await drawThread(
            Self.replies(["GET /api/district/messages/drafts": .refused(500)]),
            targets: [Self.sms]
        )
    }

    // MARK: - WhatsApp and Meta windows

    /// WhatsApp's 24-hour window has closed: free text is replaced by the template button.
    func testThreadWhatsAppWindowClosed() async throws {
        try await drawThread(
            Self.replies(["/api/district/workspace/whatsapp/window": .fixture("district-whatsapp-window-closed")]),
            targets: [Self.whatsApp]
        )
    }

    /// The window is open: the ordinary composer, on WhatsApp.
    func testThreadWhatsAppWindowOpen() async throws {
        try await drawThread(
            Self.replies(["/api/district/workspace/whatsapp/window": .fixture("district-whatsapp-window")]),
            targets: [Self.whatsApp],
            locales: [.en]
        )
    }

    /// Messenger in Meta's human-agent window: the strip says so and the AI draft is withheld.
    func testThreadMessengerHumanAgentWindow() async throws {
        try await drawThread(
            Self.replies(["GET /api/district/messages/send": .fixture("district-meta-window-human-agent")]),
            targets: [Self.messenger]
        )
    }

    /// Messenger with Meta's window closed.
    func testThreadMessengerWindowClosed() async throws {
        try await drawThread(
            Self.replies(["GET /api/district/messages/send": .fixture("district-meta-window-closed")]),
            targets: [Self.messenger]
        )
    }

    /// Messenger with the window open.
    func testThreadMessengerWindowOpen() async throws {
        try await drawThread(
            Self.replies(["GET /api/district/messages/send": .fixture("district-meta-window")]),
            targets: [Self.messenger],
            locales: [.en]
        )
    }
}
