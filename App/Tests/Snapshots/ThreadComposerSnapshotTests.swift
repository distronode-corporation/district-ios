@testable import DistrictAI
import DistrictL10n
import DistrictModel
import SwiftUI
import XCTest

/// The composer, the WhatsApp template sheet and the assign sheet, each over a model the test
/// builds from the drawing's own container and drives the way the screen's buttons would.
///
/// ⚠️ THE SCREEN OWNS ITS MODEL AS PRIVATE STATE, so a state reached only by a tap (a generated
/// draft, a refused send, a refused assignment) is drawn here over a model the test holds.
/// The box's typed text is the model's own (``ThreadModel/composerText``), so it is drawn too.
final class ThreadComposerSnapshotTests: ScreenSnapshotTestCase {
    private typealias Fixtures = ThreadScopeSnapshotTests

    private static func threadModel(_ container: AppContainer, _ targets: [ReplyTarget]) -> ThreadModel {
        ThreadModel(
            container: container,
            workspaceId: Fixtures.workspace,
            role: .client,
            threadKey: Fixtures.threadKey,
            replyTargets: targets
        )
    }

    /// Writes a typed box can arm: the debounced autosave.
    private static let autosave: [String: FixtureTransport.Reply] = [
        "PUT /api/district/messages/drafts": .fixture("district-draft-put"),
    ]

    // MARK: - Composer

    /// Draft reply answered: the generated text is in the box, ready to edit or send.
    func testComposerGeneratedDraft() async throws {
        var extra = Self.autosave
        extra["POST /api/district/messages/draft"] = .fixture("district-ai-draft")
        let replies = Fixtures.replies(extra)
        try await assertScreen(replies, devices: [.iPhone]) { container in
            ScopeComposerHost(
                model: Self.threadModel(container, [Fixtures.sms]),
                drive: { model in await model.open() },
                afterBar: { model in await model.generateDraft() }
            )
        }
    }

    /// Draft reply refused (the per-workspace cap): the reason sits above the box with Dismiss.
    func testComposerDraftRefused() async throws {
        let replies = Fixtures.replies([
            "POST /api/district/messages/draft": .refused(429, "Too many drafts. Try again in a minute."),
        ])
        try await assertScreen(replies, devices: [.iPhone], locales: [.en]) { container in
            ScopeComposerHost(model: Self.threadModel(container, [Fixtures.sms])) { model in
                await model.open()
                await model.generateDraft()
            }
        }
    }

    /// A send the carrier refused: the text stays in the box, the reason above it, nothing resent.
    func testComposerSendRefused() async throws {
        var extra = Self.autosave
        extra["POST /api/district/messages/send"] = .refused(502, "The carrier did not accept the message.")
        let replies = Fixtures.replies(extra)
        try await assertScreen(replies, devices: [.iPhone]) { container in
            ScopeComposerHost(model: Self.threadModel(container, [Fixtures.sms])) { model in
                await model.open()
                model.composerTextChanged("Thursday at 2pm works.")
                await model.send()
            }
        }
    }

    /// An email reply whose subject was cleared: the subject box is empty and Send is refused.
    func testComposerEmailWithoutSubject() async throws {
        try await assertScreen(Fixtures.replies(Self.autosave), devices: [.iPhone], locales: [.en]) { container in
            ScopeComposerHost(model: Self.threadModel(container, [Fixtures.email])) { model in
                await model.open()
                model.subjectChanged("")
                model.composerTextChanged("Friday is fine.")
            }
        }
    }

    // MARK: - WhatsApp templates

    private static let closedWindow: [String: FixtureTransport.Reply] = [
        "/api/district/workspace/whatsapp/window": .fixture("district-whatsapp-window-closed"),
    ]

    /// The approved template for this sender; the pending one is not offered.
    func testWhatsAppTemplatesListed() async throws {
        try await drawTemplates(Fixtures.replies(Self.closedWindow))
    }

    /// No approved template: the sheet says so rather than drawing an empty list.
    func testWhatsAppTemplatesNone() async throws {
        var extra = Self.closedWindow
        extra["/api/district/workspace/whatsapp/templates"] = .recorded("district-whatsapp-templates") { json in
            json["templates"] = [Any]()
        }
        try await drawTemplates(Fixtures.replies(extra))
    }

    /// The template read failed: the sheet's own sentence with a retry.
    func testWhatsAppTemplatesFailed() async throws {
        var extra = Self.closedWindow
        extra["/api/district/workspace/whatsapp/templates"] = .refused(500)
        try await drawTemplates(Fixtures.replies(extra), locales: [.en])
    }

    private func drawTemplates(
        _ replies: [String: FixtureTransport.Reply],
        locales: [L10nLocale] = [.en, .frCA],
        testName: String = #function
    ) async throws {
        try await assertScreen(replies, devices: [.iPhone], locales: locales, testName: testName) { container in
            let model = Self.threadModel(container, [Fixtures.whatsApp])
            // ⚠️ THE WINDOW IS READ FIRST, as the composer reads it before the button is offered;
            // the sheet's own load returns at once while the window is still unknown.
            return WhatsAppTemplateSheet(model: model)
                .task {
                    await model.load()
                    await model.refreshWhatsAppWindow()
                    await model.loadWhatsAppTemplates()
                }
        }
    }

    // MARK: - Assign

    private static let assignKey = Fixtures.threadKey

    private static func assignModel(_ container: AppContainer, current: String? = nil) -> ThreadAssignModel {
        ThreadAssignModel(
            inbox: container.inbox,
            workspaces: container.workspaces,
            workspaceId: Fixtures.workspace,
            threadKey: assignKey,
            current: current
        )
    }

    /// Unassigned: the roster without its viewer, the check on Unassigned.
    func testAssignSheetUnassigned() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            ThreadAssignSheet(model: Self.assignModel(container), onAssigned: {})
        }
    }

    /// The list's re-read says who holds the thread, and that member carries the check.
    func testAssignSheetAssigned() async throws {
        let held: FixtureTransport.Reply = .recorded("district-conversations") { json in
            json.editEach("conversations") { row in
                if row["threadKey"] as? String == Self.assignKey {
                    row["assigneeEmail"] = "operator@contract.test"
                }
            }
        }
        try await assertScreen(["/api/district/conversations": held], devices: [.iPhone], locales: [.en]) { container in
            ThreadAssignSheet(model: Self.assignModel(container), onAssigned: {})
        }
    }

    /// The holder has left the roster: kept as a row (checked) so the sheet does not claim nobody has it.
    func testAssignSheetHolderNotOnTheRoster() async throws {
        let held: FixtureTransport.Reply = .recorded("district-conversations") { json in
            json.editEach("conversations") { row in
                if row["threadKey"] as? String == Self.assignKey {
                    row["assigneeEmail"] = "former@contract.test"
                }
            }
        }
        try await assertScreen(["/api/district/conversations": held], devices: [.iPhone], locales: [.en]) { container in
            ThreadAssignSheet(model: Self.assignModel(container), onAssigned: {})
        }
    }

    /// The roster read failed: the failure with its retry.
    func testAssignSheetRosterFailed() async throws {
        try await assertScreen(["/api/district/workspace/members": .refused(500)], devices: [.iPhone]) { container in
            ThreadAssignSheet(model: Self.assignModel(container), onAssigned: {})
        }
    }

    /// The service refused the assignee (a viewer, from a roster that changed since it was read):
    /// its sentence above the list, and the sheet stays open.
    func testAssignSheetRefused() async throws {
        let replies: [String: FixtureTransport.Reply] = [
            "POST /api/district/conversations/assign": FixtureTransport.Reply(
                status: 400,
                body: FixtureTransport.fixtureData("district-conversation-assign-viewer")
            ),
        ]
        try await assertScreen(replies, devices: [.iPhone]) { container in
            let model = Self.assignModel(container)
            return ThreadAssignSheet(model: model, onAssigned: {})
                .task {
                    await model.load()
                    _ = await model.assign("auditor@contract.test")
                }
        }
    }
}

/// The composer alone, under the space the thread would fill, for a model a test drives.
///
/// ⛔ `afterBar` RUNS ONCE THE BAR HAS BEEN DRAWN EMPTY, for a step that fills the box. A
/// two-line reply in a box first laid out with that text already in it has two stable heights,
/// one device pixel apart (about 1 drawing in 10 locally, and CI runs 45910050299 and
/// 45937295086, #163). The same box laid out empty and then filled grew to one height in 80
/// of 80 local drawings. On a slow runner the draft could land before the bar's first layout,
/// so the step waits for it instead of racing it.
struct ScopeComposerHost: View {
    let model: ThreadModel
    let drive: @MainActor @Sendable (ThreadModel) async -> Void
    var afterBar: (@MainActor @Sendable (ThreadModel) async -> Void)?

    @State private var barShown = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let content = model.current {
                ComposerBar(model: model, content: content)
                    .onAppear { barShown = true }
            }
        }
        .task {
            await drive(model)
            guard let afterBar else { return }
            await firstReadLanded { barShown }
            // Two frames, so the empty box is laid out, not only inserted.
            try? await Task.sleep(for: .milliseconds(50))
            await afterBar(model)
        }
    }
}
