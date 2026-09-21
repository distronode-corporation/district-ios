import SwiftUI

/// The note under an Inbox list that says the list is not the whole answer.
///
/// ⚠️ ITS OWN TYPE FOR `file_length`, AND IT IS ONE LOOK FOR TWO SENTENCES. The
/// conversation list and the search results each end on one (a scan window reached, a
/// search capped), and ``InboxView``'s file sits at the ceiling `swiftlint --strict`
/// reports as an error. Why each sentence is shown stays beside its call site there.
struct InboxListCaption: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(DistrictSpacing.section)
    }
}
