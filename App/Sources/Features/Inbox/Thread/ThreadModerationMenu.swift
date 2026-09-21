import DistrictData
import DistrictModel
import SwiftUI

/// The thread screen's Guideline 1.2 controls: flag the conversation, block the
/// caller.
///
/// ⛔ A TOOLBAR MENU RATHER THAN BUTTONS IN THE SCROLL VIEW, AND THE PLACEMENT IS
/// FORCED RATHER THAN CHOSEN. A thread is a timeline with a composer pinned to the
/// bottom; there is no stable place in it for two controls that must be reachable
/// from a conversation of any length, and a reviewer watching a recording has to
/// find them without scrolling. ⚠️ It is also the only surface on this client with a
/// toolbar menu — `ContactsView` and `InboxView` carry single-item toolbars — so the
/// identifiers matter more than usual.
///
/// ⛔ THE BLOCK POPS THIS SCREEN AND THE REPORT DOES NOT. Blocking takes the thread
/// out of the inbox list immediately (Apple asks that the content leave view at
/// once), so staying on a screen the list no longer contains would leave the
/// operator looking at something they cannot get back to. Reporting changes nothing
/// about what is visible and must not move them.
///
/// ⛔ NEITHER CONTROL IS IN `UITestApp.forbiddenSurfaces`, WHICH IS A DECISION. That
/// set guards writes that are irreversible or billed against the live workspace; a
/// block takes the desired STATE, so an unblock puts the row back, and a report is
/// what the recording exists to show. What keeps it safe is the DATA: the harness
/// only ever blocks a fictional `+1 555 01xx` demo contact.
struct ThreadModerationMenu: ToolbarContent {
    /// ⚠️ FALSE FOR A `viewer`, WHO IS OFFERED NO MENU AT ALL. Both the block and the
    /// support-create routes exclude that role server-side. ⛔ For the report half
    /// that is a known gap against Guideline 1.2 rather than a design — see the ⛔ on
    /// ``ReportContentModel``.
    let canModerate: Bool

    /// ⚠️ THE MENU ONLY FLIPS THESE. Everything that follows from a choice — the
    /// confirmation, the sheet, the write, the pop — belongs to
    /// ``ThreadModerationModifier``, because those are `View` modifiers and a
    /// `ToolbarContent` cannot carry one.
    @Binding var reporting: Bool
    @Binding var confirmingBlock: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // ⚠️ THE `if` IS INSIDE THE ITEM, NOT AROUND IT, matching
            // `ContactsView.addContactItem`: a conditional at `ToolbarContent` level
            // leans on `ToolbarContentBuilder` supporting an `if` with no `else`,
            // which only an iOS SDK build can settle. An empty item
            // renders nothing.
            if canModerate {
                menu
            }
        }
    }

    private var menu: some View {
        Menu {
            Button(ReportCopy.reportConversation) { reporting = true }
                .accessibilityIdentifier(A11yID.Inbox.threadReport)
            Button(ContactBlockCopy.block, role: .destructive) { confirmingBlock = true }
                .accessibilityIdentifier(A11yID.Inbox.threadBlock)
        } label: {
            // ⚠️ A WORD, NOT AN SF SYMBOL. `A11yImageTests` requires every symbol in
            // the tree to carry an accessibility decision, and an ellipsis glyph
            // labelled "More" tells a reviewer watching a recording nothing about
            // what is behind it. "Manage" is what the menu does.
            // ⛔ AND THE CONSTRUCTOR'S NAME IS NOT WRITTEN OUT ANYWHERE ABOVE, ON
            // PURPOSE: that gate SCANS THE SOURCE for the literal and counts
            // comments too, so a comment naming it reads as one more symbol with
            // no accessibility treatment — even a comment explaining why a word is
            // used instead.
            Text("Manage")
        }
        .accessibilityIdentifier(A11yID.Inbox.threadMenu)
    }
}

/// Which thread is being moderated, as one value.
///
/// ⛔ A STRUCT RATHER THAN FIVE MORE PARAMETERS, AND THE RULE IS SwiftLint'S.
/// `function_parameter_count` caps a `func` at five and does not count an
/// initialiser's, so the flat version of ``View/threadModeration(_:reporting:confirmingBlock:onBlocked:)``
/// could not be written under `--strict` at all. ⚠️ It is also the honest shape: the
/// five travel together because they all describe ONE conversation, which is the
/// same argument `ContactUpdateFields` and ``ThreadTarget`` make.
struct ThreadModerationContext {
    let container: AppContainer
    let workspaceId: String

    /// `contact:<id>` or `addr:<normalized>`. ⚠️ Carried whole, prefix included: it
    /// is what ``ReportCopy/reference(for:)`` puts on the wire and what
    /// ``BlockSubject`` is derived from.
    let threadKey: String

    /// The counterpart's resolved name, for the report sheet's heading only.
    let title: String?

    /// ⚠️ FALSE FOR A `viewer`. See the ⚠️ on ``ThreadModerationMenu/canModerate``.
    let canModerate: Bool
}

/// The menu, its confirmation and the sheet, as one modifier on the thread screen.
///
/// ⛔ A VIEW MODIFIER RATHER THAN PART OF THE `ToolbarContent`, BECAUSE A
/// `ToolbarContent` CANNOT CARRY ONE. `.confirmationDialog` and `.sheet` are `View`
/// modifiers and a toolbar item's content is not the view they would attach to — a
/// dialog presented from inside a toolbar item disappears with the item on some
/// layouts. All three are attached to the screen instead.
///
/// ⛔ THE BLOCK SUBJECT IS DERIVED FROM THE THREAD KEY AND THE FALLBACK IS THE POINT.
/// A `contact:` key gives an exact id; an `addr:` key gives only an address, and a
/// thread whose counterpart never resolved to a `Contact` row is exactly the one a
/// reviewer is most likely to open. The server upserts the row for a raw number,
/// which is why ``BlockSubject/phoneNumber(_:)`` exists at all.
/// ⚠️ AN `addr:` KEY HOLDING AN EMAIL IS SENT AS A `phoneNumber` AND THE SERVER WILL
/// REFUSE IT. That is honest: there is no "block by email address" on the route, so
/// the alternative is hiding the control on email-only threads, which would leave
/// them with no block mechanism at all. The server's own sentence reaches the screen.
struct ThreadModerationModifier: ViewModifier {
    let context: ThreadModerationContext

    @Binding var reporting: Bool
    @Binding var confirmingBlock: Bool

    /// ⚠️ CALLED ONLY AFTER THE SERVER CONFIRMED THE BLOCK. The caller pops; see the
    /// ⛔ on ``ThreadModerationMenu``.
    let onBlocked: () -> Void

    func body(content: Content) -> some View {
        content
            .toolbar {
                ThreadModerationMenu(
                    canModerate: context.canModerate,
                    reporting: $reporting,
                    confirmingBlock: $confirmingBlock
                )
            }
            .confirmationDialog(
                ContactBlockCopy.blockPrompt,
                isPresented: $confirmingBlock,
                titleVisibility: .visible
            ) {
                Button(ContactBlockCopy.confirmBlock, role: .destructive) { block() }
                Button(ContactBlockCopy.cancel, role: .cancel) {}
            }
            .sheet(isPresented: $reporting) {
                ReportSheet(
                    container: context.container,
                    workspaceId: context.workspaceId,
                    target: .conversation(threadKey: context.threadKey, name: context.title)
                )
            }
    }

    private func block() {
        guard let subject = Self.subject(threadKey: context.threadKey) else { return }
        let store = context.container.blockedContacts
        let workspaceId = context.workspaceId
        Task {
            let ok = await store.setBlocked(workspaceId: workspaceId, subject: subject, blocked: true)
            guard ok else { return }
            onBlocked()
        }
    }

    /// Who to block, from the thread's own key.
    ///
    /// ⛔ IT REUSES ``ThreadTarget/selector(threadKey:)``'s VOCABULARY RATHER THAN
    /// RE-PARSING THE PREFIXES. A second parser here would be a second opinion about
    /// what `contact:` means, and the drafts route 400s anything outside those two
    /// forms — so a third form is a malformed destination rather than a caller to
    /// block.
    static func subject(threadKey: String) -> BlockSubject? {
        switch ThreadTarget.selector(threadKey: threadKey) {
        case let .contact(id):
            .contact(id)
        case let .address(address):
            .phoneNumber(address)
        case nil:
            nil
        }
    }
}

extension View {
    /// Attach the thread screen's moderation menu, its confirmation and the report
    /// sheet.
    ///
    /// ⚠️ FOUR PARAMETERS, WHICH IS WHY ``ThreadModerationContext`` EXISTS. The flat
    /// spelling is eight, and SwiftLint's `function_parameter_count` caps a `func` at
    /// five while not counting an initialiser's — so under `--strict` the grouped
    /// form is the only one that compiles the gate. Same rule `ContactUpdateFields`
    /// was created under.
    func threadModeration(
        _ context: ThreadModerationContext,
        reporting: Binding<Bool>,
        confirmingBlock: Binding<Bool>,
        onBlocked: @escaping () -> Void
    ) -> some View {
        modifier(ThreadModerationModifier(
            context: context,
            reporting: reporting,
            confirmingBlock: confirmingBlock,
            onBlocked: onBlocked
        ))
    }
}
