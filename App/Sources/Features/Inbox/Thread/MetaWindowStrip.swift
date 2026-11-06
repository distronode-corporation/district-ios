import SwiftUI

/// What the composer says about Meta's reply window on a Messenger or Instagram reply: the
/// human agent badge, or the closed-window warning (Send is disabled under it). Nothing for
/// an open window or an unknown one, as on the website.
///
/// ⚠️ A WRAPPING WARNING STRIP, NOT A ``DistrictBadge``, FOR THE CLOSED SENTENCE: a badge
/// holds one line at its own width and a sentence this long would overflow the composer.
struct MetaWindowStrip: View {
    let model: ThreadModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        if model.metaHumanAgent {
            DistrictBadge(text: InboxCopy.metaHumanAgent, tone: .info)
        } else if model.metaWindowClosed {
            HStack(alignment: .top, spacing: DistrictSpacing.tight) {
                // ⚠️ DECORATION: the sentence beside it says what is wrong.
                Image(systemName: "exclamationmark.triangle")
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.warning)
                    .accessibilityHidden(true)
                Text(InboxCopy.metaWindowClosed)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.foreground)
                    // ⚠️ ITS WHOLE HEIGHT (screenshots): the composer squeezed it to one
                    // truncated line, as it did the channel note.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DistrictSpacing.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tone.warning.fill(colors), in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        }
    }
}
