import DistrictModel
import SwiftUI

/// One row of the call log.
///
/// ⛔ EVERY DISPLAY RULE COMES FROM ``CallDisplay``, NONE ARE DERIVED HERE. The other
/// client's row re-derived them from the raw DTO with its own copies of the wire
/// constants and had already drifted from both the overview and the detail screen,
/// most damagingly by rendering only the `success` transfer badge, which made a
/// FAILED transfer invisible in the one list an operator scans to find them.
///
/// ⛔ NO TAP HANDLER. The row is wrapped in a `NavigationLink` by ``CallLogView``,
/// which is what gives it the disclosure chevron, the press highlight and the
/// accessibility button trait; see the ⛔ on ``DistrictListRow``.
struct CallRow: View {
    let call: CallSummary

    private var display: CallDisplay {
        CallDisplay(call)
    }

    var body: some View {
        DistrictListRow(
            title: display.callerLabel,
            // ⚠️ NOT ``CallDisplay/subtitle``. The list row carries a direction GLYPH
            // where the detail screen spells the word; see the ⛔ on
            // ``CallDisplay/rowSubtitle``.
            subtitle: display.rowSubtitle,
            // ⛔ BOTH SLOTS LABELLED. A trailing closure here is `ambiguous use of
            // 'init'` against the two single-slot initialisers.
            leading: { DistrictAvatar(name: display.displayName ?? "", tone: display.avatarTone) },
            trailing: { badges }
        )
        // ⛔ THE ROW IS ONE ACCESSIBILITY ELEMENT WITH A WRITTEN LABEL, BECAUSE THE
        // SUBTITLE IS NOW A GLYPH. Left alone, VoiceOver reads the arrow literally
        // ("up arrow") or drops it, so the direction would be sighted-only, which is
        // exactly the trade a glyph must not make. The label restores the WORD and
        // reads the row in visual order.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// What VoiceOver says for this row, in the order the eye takes it: who, which
    /// way, when and how long, then the pills.
    ///
    /// ⚠️ IT REBUILDS THE COPY RATHER THAN READING THE GLYPH. Every string here comes
    /// from ``CallDisplay`` so the spoken row and the drawn row cannot disagree, and
    /// ``CallDisplay/directionLabel`` is the same word the detail screen prints.
    private var accessibilityLabel: String {
        var parts = [display.callerLabel, display.directionLabel, display.timeAndDuration]
        if let transferLabel = display.transferLabel {
            parts.append(transferLabel)
        }
        parts.append(display.statusLabel)
        return parts.joined(separator: ", ")
    }

    /// ⛔ TWO PILLS STACK, THEY DO NOT SIT SIDE BY SIDE, AND THAT IS A WIDTH DECISION
    /// RATHER THAN A STYLE ONE. Side by side, the trailing slot's width is the SUM of
    /// the two pills (~185pt for "Transfer failed" plus "completed"); stacked, it is
    /// the WIDER of the two (~115pt). ``DistrictListRow`` sizes the trailing slot
    /// first, so those 70pt come straight off the text column, which is what was
    /// eating the time and the duration out of the subtitle.
    ///
    /// ⚠️ IT COSTS ABOUT 10pt OF ROW HEIGHT on the rows that stack, so a transfer row
    /// is slightly taller than its neighbours. Accepted: those are the rows an operator
    /// is scanning for, and losing the call's time is a worse price than losing the
    /// rhythm.
    ///
    /// ⚠️ ONE BRANCH, NOT TWO STACKED CONDITIONALS. `transferStatus` is a single value,
    /// so ``CallDisplay/transferLabel`` answers at most one badge and the stack is
    /// exactly two pills whenever it appears.
    ///
    /// ⛔ THE TRANSFER BADGE IS THE ONE THAT WAS MISSING ON ANDROID. A transfer that
    /// failed means the caller did not reach the human they were being handed to,
    /// which is the single most actionable thing in this list, and the log was the
    /// only screen that would not say so. Danger-toned so it is findable by colour
    /// while scrolling rather than only by reading.
    @ViewBuilder
    private var badges: some View {
        if let transferLabel = display.transferLabel {
            VStack(alignment: .trailing, spacing: DistrictSpacing.hairline) {
                DistrictBadge(text: transferLabel, tone: display.transferTone)
                statusBadge
            }
        } else {
            statusBadge
        }
    }

    private var statusBadge: some View {
        DistrictBadge(text: display.statusLabel, tone: display.statusTone)
    }
}
