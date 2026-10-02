import SwiftUI

/// The strip under a paged list: a spinner while a window is in flight, or the
/// append failure with a retry.
///
/// ⛔ IT REPORTS ONLY THE APPEND, so a failed extra page never destroys the rows
/// already on screen. Nothing is drawn once the feed has ended or between windows.
/// See ``PagedFeedState``.
struct PagedFeedFooter: View {
    let appending: Bool
    let appendFailure: FailureText?
    let onRetry: () -> Void

    var body: some View {
        if appending {
            // ⚠️ A spinner is correct HERE, unlike the cold-start case: the footer is
            // a strip below rows the user is already reading, so there is no shape to
            // stand in for and nothing to stop jumping.
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(DistrictSpacing.gutter)
        } else if let appendFailure {
            VStack(spacing: DistrictSpacing.tight) {
                Text("Could not load more")
                    .font(DistrictType.bodySmall)
                Text(appendFailure.message)
                    .font(DistrictType.caption)
                    .multilineTextAlignment(.center)
                // ⚠️ Offered unconditionally here, unlike ``FailureView``, because the
                // only thing this footer can do is ask for the same window again. A
                // failure that cannot be retried still gets its sentence above.
                Button("Try again", action: onRetry)
                    .buttonStyle(.districtSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(DistrictSpacing.gutter)
        }
    }
}
