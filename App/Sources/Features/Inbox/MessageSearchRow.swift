import DistrictModel
import SwiftUI

/// One row of the Inbox search results.
///
/// ⛔ NOT A ``ConversationRow``, AND NOT A NARROWER ONE. A hit is one message and a
/// conversation row is a thread: the row above shows a channel set, a delivery
/// status, a draft chip and an unread count, and the search route sends none of
/// those. Reusing it would mean either drawing four empty slots or inventing
/// values, and the second is how a client ends up asserting a delivery it cannot
/// confirm.
///
/// ⛔ NOT A ``DistrictListRow`` EITHER, WHICH IS THE ONE DESIGN-SYSTEM DEPARTURE
/// HERE. That component is title + one-line subtitle + two slots, and this row has
/// three facts to show — who, when, and the text that matched — where the matched
/// text is the whole reason the row exists and must not be truncated to a single
/// line. Putting the instant in the trailing slot would give it `layoutPriority(1)`
/// over the name, and putting the body in the subtitle would cap it at one line.
/// So the row is built here, with the same 56pt floor, gutters and type ramp.
///
/// ⛔ NO TAP HANDLER. Wrapped in a `NavigationLink` by ``InboxView``, for the
/// disclosure affordance, the press highlight and the accessibility button trait.
/// See the ⛔ on ``DistrictListRow``.
struct MessageSearchRow: View {
    let hit: MessageSearchHit

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var display: MessageSearchDisplay {
        MessageSearchDisplay(hit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            header
            subjectLine
            // ⚠️ TWO LINES, NOT ONE. The matched text is what the operator is
            // scanning for, and ``MessagePreview`` has already flattened and capped
            // it, so the row's height is bounded either way.
            Text(display.body)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DistrictSpacing.gutter)
        .padding(.vertical, DistrictSpacing.row)
        .frame(minHeight: 56, alignment: .leading)
    }

    /// ⚠️ THE INSTANT YIELDS TO NOTHING AND THE NAME TRUNCATES, which is the
    /// opposite of ``DistrictListRow``'s default and is deliberate: a half-rendered
    /// date is unreadable while a truncated name still identifies a person.
    private var header: some View {
        // ⚠️ THE TRADE ABOVE INVERTS AT AN ACCESSIBILITY TEXT SIZE. A `fixedSize`
        // instant beside a truncating name is right while the instant is small; at
        // AX5 it claims most of the row and the name truncates to a letter or two,
        // so the pair stacks and each gets the full width instead.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DistrictSpacing.hairline))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight))
        return layout {
            Text(display.title)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: DistrictSpacing.tight)
            }
            Text(display.timestamp)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// ⛔ PRESENT ONLY FOR AN EMAIL THAT HAS ONE, AND IT IS NOT DECORATION. The
    /// route matches `subject` as well as `body`, so a subject-only hit whose body
    /// does not contain the query looks like a false positive without this line.
    @ViewBuilder
    private var subjectLine: some View {
        if let subject = display.subject {
            Text(subject)
                .font(DistrictType.label)
                .foregroundStyle(colors.foreground)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Nothing for an SMS. An empty line would read as a failed load.
    }
}
