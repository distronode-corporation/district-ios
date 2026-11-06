import DistrictModel
import SwiftUI

/// The Inbox's thread assignment controls (DistrictCore 8.2.0): the Assigned to me
/// filter in the toolbar, and the assign sheet a row's swipe action or context menu opens.
///
/// ⚠️ A FILE OF ITS OWN BECAUSE `InboxView.swift` SITS AT THE 500-LINE `file_length`
/// CEILING `swiftlint --strict` ENFORCES. The screen attaches this with one modifier and
/// each row with another.
private struct InboxAssignmentLayer: ViewModifier {
    @Bindable var model: InboxModel

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    filterMenu
                }
            }
            .sheet(item: $model.assigning) { assign in
                ThreadAssignSheet(model: assign) {
                    Task { await model.load(refreshing: true) }
                }
                .districtSheetBackground()
            }
    }

    /// ⚠️ THE ICON FILLS WHILE THE FILTER IS ON, so a narrowed list is never mistaken
    /// for an Inbox with nothing else in it.
    private var filterMenu: some View {
        Menu {
            Picker(InboxCopy.filter, selection: $model.assignedToMeOnly) {
                Text(InboxCopy.allConversations).tag(false)
                Text(InboxCopy.assignedToMe).tag(true)
            }
        } label: {
            Label(
                InboxCopy.filter,
                systemImage: model.assignedToMeOnly
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityValue(model.assignedToMeOnly ? InboxCopy.assignedToMe : InboxCopy.allConversations)
        .accessibilityIdentifier(A11yID.Inbox.filter)
    }
}

/// A row's Assign: the leading swipe action, and the same item after the row menu's copies,
/// for a role that may write.
///
/// ⛔ NOT SWIPE-ONLY (xhigh review): a swipe is found by nobody using a pointer, VoiceOver or
/// Full Keyboard Access, so a long press (or a secondary click on iPad) offers Assign too. It
/// is the one row-menu item that is not a copy; ``RowContextAction``'s rule holds for the
/// copies, and this opens the same sheet as the swipe, as the Mac's row menu does.
private struct InboxRowMenu: ViewModifier {
    let conversation: ConversationSummary
    let model: InboxModel

    func body(content: Content) -> some View {
        let copies = RowContextActions.thread(counterpart: conversation.counterpart)
        if model.canReply {
            content
                .contextMenu {
                    RowContextCopyItems(actions: copies)
                    if !copies.isEmpty {
                        Divider()
                    }
                    assignButton
                }
                .swipeActions(edge: .leading) {
                    assignButton
                        .tint(.accentColor)
                }
        } else {
            content.rowContextMenu(copies)
        }
    }

    private var assignButton: some View {
        Button(InboxCopy.assign, systemImage: "person.crop.circle.badge.plus") {
            model.beginAssigning(conversation)
        }
    }
}

extension ThreadAssignModel: Identifiable {
    nonisolated var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}

extension View {
    /// The filter menu and the assign sheet, on the Inbox screen.
    func inboxAssignment(_ model: InboxModel) -> some View {
        modifier(InboxAssignmentLayer(model: model))
    }

    /// One Inbox row's context menu (its copy items, then Assign) and its Assign swipe action.
    func inboxRowMenu(_ conversation: ConversationSummary, model: InboxModel) -> some View {
        modifier(InboxRowMenu(conversation: conversation, model: model))
    }
}

/// The Inbox's empty state, which says which of the two lists is empty.
struct InboxEmptyState: View {
    let assignedToMeOnly: Bool

    var body: some View {
        if assignedToMeOnly {
            EmptyStateView(
                systemImage: "person.crop.circle",
                title: InboxCopy.nothingAssignedTitle,
                message: InboxCopy.nothingAssignedMessage
            )
        } else {
            EmptyStateView(
                systemImage: "tray",
                title: InboxCopy.noConversationsYet,
                message: InboxCopy.textsEmailsCustomersWill
            )
        }
    }
}
