import SwiftUI

/// A failure, with the one thing the user can do about it.
///
/// ⛔ A DIFFERENT COMPONENT FROM ``EmptyStateView``, AND THE TWO MUST NEVER BE
/// SUBSTITUTED FOR EACH OTHER. "We could not look" and "there is nothing" read to a
/// paying customer as account loss when confused; that is the mistake the web made
/// with `workspace/list`'s 503 and the reason ``FailureText`` exists at all.
///
/// ⛔ THE ACTION COMES FROM THE MAPPING, NOT FROM THE CALL SITE. ``FailureText``
/// already decided whether retrying is honest and whether the session is gone; a
/// screen that passed its own button here could offer "try again" on a contract
/// mismatch, which produces the identical failure and reads as a broken app.
///
/// ⚠️ The two handlers are optional so a surface with nowhere to send a sign-in (a
/// sheet, a widget-sized card) simply renders the sentence. A `FailureText` asking
/// for an action nobody supplied shows no button rather than a dead one.
struct FailureView: View {
    let failure: FailureText
    var onRetry: (() -> Void)?
    var onSignIn: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ THE GLYPH GROWS WITH THE TEXT BESIDE IT. A fixed 28pt symbol above a
    /// sentence that has doubled reads as a decoration the layout forgot, and at AX5
    /// it is the smallest thing on screen.
    @ScaledMetric(relativeTo: .title2) private var glyphSize: CGFloat = 28

    var body: some View {
        VStack(spacing: DistrictSpacing.row) {
            // ⚠️ DECORATION. The failure's own message is directly below and says
            // what happened; the glyph only tones it.
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(tone.ink(colors))
                .accessibilityHidden(true)
            Text(failure.message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .multilineTextAlignment(.center)
            action
        }
        .frame(maxWidth: .infinity)
        .padding(DistrictSpacing.header)
    }

    @ViewBuilder
    private var action: some View {
        switch failure.action {
        case .retry:
            if let onRetry {
                Button("Try again", action: onRetry)
                    .buttonStyle(.districtSecondary)
            }
        case .signIn:
            // ⛔ A DISTINCT OFFER FROM "try again", DELIBERATELY. Retrying re-sends a
            // credential that is gone; the only way forward is a new session.
            if let onSignIn {
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.districtPrimary)
            }
        case .none:
            EmptyView()
        }
    }

    /// ⚠️ A sign-out is not an error state. It gets the neutral session glyph rather
    /// than a warning triangle, because nothing went wrong: a token expired.
    private var symbol: String {
        switch failure.action {
        case .signIn: "person.crop.circle.badge.exclamationmark"
        case .retry, .none: "exclamationmark.triangle"
        }
    }

    private var tone: Tone {
        switch failure.action {
        case .signIn: .district
        case .retry: .warning
        case .none: .danger
        }
    }
}
