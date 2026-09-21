import SwiftUI

/// What a screen shows when it has nothing, and it is NOT an error.
///
/// ⛔ THE ANDROID CLIENT HAD NO SUCH COMPONENT, WHICH IS WHY AN EMPTY SCREEN READ AS
/// A BROKEN ONE. An empty list rendered as a blank expanse, indistinguishable from a
/// failed load, and a user cannot tell "you have no contacts yet" from "this did not
/// work" by looking at nothing. Every list in this app can reach that state on day
/// one of a new workspace, which is the first thing a new customer sees. Pair it
/// with ``FailureView``: an absence and a failure are different answers and must
/// never share a screen state.
///
/// ⚠️ Takes an optional action so the empty state can be WHERE the first item is
/// created, rather than a dead end describing a button somewhere else.
///
/// ⛔ THAT ACTION MAY NEVER BE A PURCHASE PATH. App Store Review Guideline 3.1.3(b)
/// forbids it and billing is read-only in this app: a lapsed workspace gets a
/// sentence naming the website and stops there.
struct EmptyStateView<Action: View>: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let action: Action

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action()
    }

    /// ⚠️ THE GLYPH GROWS WITH THE TEXT BESIDE IT. A fixed 32pt symbol above a
    /// sentence that has doubled reads as a decoration the layout forgot, and at AX5
    /// it is the smallest thing on screen.
    @ScaledMetric(relativeTo: .title) private var glyphSize: CGFloat = 32

    var body: some View {
        VStack(spacing: DistrictSpacing.tight) {
            // ⚠️ DECORATION, AND SAID SO. The symbol restates the title underneath
            // it — an envelope over "No messages" — so announcing it would make
            // VoiceOver read the same fact twice, the first time as a symbol name.
            Image(systemName: systemImage)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(colors.mutedForeground)
                .padding(.bottom, DistrictSpacing.hairline)
                .accessibilityHidden(true)
            Text(title)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
                .multilineTextAlignment(.center)
            Text(message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .multilineTextAlignment(.center)
            action
                .padding(.top, DistrictSpacing.section - DistrictSpacing.tight)
        }
        .frame(maxWidth: .infinity)
        .padding(DistrictSpacing.header)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// A placeholder block for content that is still loading.
///
/// ⚠️ STATIC, NOT SHIMMERING, ON PURPOSE. An infinite animation is the one thing on
/// screen that never settles; it also defeats screenshot tests and ignores the
/// reduce-motion preference the web honours with a full kill switch. A calm block
/// says "shape known, content pending" without any of that.
struct SkeletonBlock: View {
    var height: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: DistrictRadius.badge)
            .fill(colors.muted)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}
