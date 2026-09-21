import DistrictModel
import SwiftUI

/// One row of the Inbox list.
///
/// ⛔ EVERY DISPLAY RULE COMES FROM ``ConversationDisplay``, NONE ARE DERIVED HERE.
/// That is the lesson ``CallDisplay`` was extracted for: the other client's row
/// re-derived the wire comparisons inline with its own copies of the constants, and the
/// copies drifted until a failed transfer was invisible in the one list an operator
/// scans to find them.
///
/// ⛔ NO TAP HANDLER. The row is wrapped in a `NavigationLink` by ``InboxView``, which
/// is what gives it the disclosure chevron, the press highlight and the accessibility
/// button trait; see the ⛔ on ``DistrictListRow``.
///
/// ⛔ THE UNREAD COUNT ARRIVES AS A PARAMETER RATHER THAN OFF THE DTO. Opening a thread
/// clears its badge optimistically, and ``ConversationSummary`` cannot be copied from
/// this target (no public initialiser), so ``InboxModel`` keeps the cleared threads as
/// an overlay and answers the count. Reading `conversation.unreadCount` here would draw
/// the badge the tap was supposed to remove.
struct ConversationRow: View {
    let conversation: ConversationSummary
    let unreadCount: Int
    let hasDraft: Bool

    private var display: ConversationDisplay {
        ConversationDisplay(conversation)
    }

    var body: some View {
        DistrictListRow(
            title: display.title,
            subtitle: display.subtitle,
            // ⛔ BOTH SLOTS LABELLED. A trailing closure here is `ambiguous use of
            // 'init'` against the two single-slot initialisers.
            leading: { DistrictAvatar(name: display.avatarName, tone: display.avatarTone) },
            trailing: { badges }
        )
    }

    /// ⚠️ THE UNREAD BADGE KEEPS THE RIGHTMOST POSITION, ported from the Android row's
    /// own note. An operator scanning the list reads the right edge for "needs me", so
    /// anything that displaced it would move the thing they look for.
    private var badges: some View {
        HStack(spacing: DistrictSpacing.hairline) {
            ForEach(display.channelLabels, id: \.self) { label in
                DistrictBadge(text: label, tone: .neutral)
            }
            statusBadge
            draftBadge
            unreadBadge
        }
    }

    /// ⛔ THE OUTBOUND DELIVERY OUTCOME, AND THE REASON THIS ROW HAS A TONE AT ALL. A
    /// reply that failed means the customer never got it, and the send has already been
    /// paid for; rendering that in the same grey as a delivered one is exactly the bug
    /// the call log's status pills were introduced to fix. ``MessageStatusTone`` fails
    /// to neutral for a status this client does not model, so an unknown provider value
    /// asserts nothing.
    @ViewBuilder
    private var statusBadge: some View {
        if let statusLabel = display.statusLabel {
            DistrictBadge(text: statusLabel, tone: display.statusTone)
        }
    }

    /// ⚠️ AUTHOR-SCOPED, so this never appears for a colleague's unfinished thought:
    /// the server keys the row by `authorEmail` and this client never sends one.
    @ViewBuilder
    private var draftBadge: some View {
        if hasDraft {
            DistrictBadge(text: "Draft", tone: .info)
        }
        // Nothing when there is no draft. An empty chip would read as a failed load.
    }

    /// ⚠️ THE ACCENT TONE, NOT SUCCESS. Unread is a state, not a verdict; see the ⚠️ at
    /// the top of ``Tone``.
    ///
    /// ⚠️ AND IT CARRIES ITS OWN ACCESSIBILITY LABEL, because a bare "2" announces a
    /// number with no stated subject. The Android row solves the same problem with a
    /// semantics content description.
    @ViewBuilder
    private var unreadBadge: some View {
        if unreadCount > 0 {
            DistrictBadge(text: "\(unreadCount)", tone: .district)
                .accessibilityLabel("\(unreadCount) unread")
        }
    }
}
