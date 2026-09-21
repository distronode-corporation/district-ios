import SwiftUI

/// The one spinner, so "we are working" looks the same everywhere.
///
/// ⚠️ IT SAYS SOMETHING. A bare `ProgressView` on an otherwise empty screen is
/// indistinguishable from a hung one; a sentence beside it tells the user what is
/// being waited for, which is the difference between patience and a force quit.
///
/// ⚠️ NOT FOR A REFRESH OVER EXISTING CONTENT. Replacing a populated screen with a
/// spinner throws away what the user was reading; a re-read with content on screen
/// belongs in a `refreshable` or an inline indicator. This is the cold-start state.
struct LoadingView: View {
    var message: String?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(spacing: DistrictSpacing.row) {
            ProgressView()
            if let message {
                Text(message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DistrictSpacing.header)
    }
}
