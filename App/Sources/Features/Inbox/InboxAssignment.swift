import DistrictModel
import SwiftUI

/// The Inbox's thread assignment controls (DistrictCore 8.2.0): the Assigned to me
/// filter in the toolbar, and the assign sheet a row's swipe action opens.
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

/// The row's Assign swipe action, for a role that may write.
private struct InboxAssignSwipe: ViewModifier {
    let conversation: ConversationSummary
    let model: InboxModel

    func body(content: Content) -> some View {
        if model.canReply {
            content.swipeActions(edge: .leading) {
                Button(InboxCopy.assign, systemImage: "person.crop.circle.badge.plus") {
                    model.beginAssigning(conversation)
                }
                .tint(.accentColor)
            }
        } else {
            content
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

    /// The Assign swipe action, on one Inbox row.
    func inboxAssignSwipe(_ conversation: ConversationSummary, model: InboxModel) -> some View {
        modifier(InboxAssignSwipe(conversation: conversation, model: model))
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
