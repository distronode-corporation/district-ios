import DistrictModel
import SwiftUI

/// The owner mid-setup is offered the rest of the setup wizard.
///
/// ⛔ THE COPY NAMES NO DESTINATION, AND THAT IS `StoreCopyTests`, NOT TASTE. Guideline
/// 3.1.1 forbids steering, so no string in `Features/` may name the web, a browser, a
/// dashboard or the site. So the card says
/// what is left to do and what the button does, and the page it opens speaks for itself.
///
/// ⛔ THE BUTTON OPENS THE WIZARD IN THE APP (``SetupWizardView``), since 2026-11-08 ("Most in
/// app, buying on web"). Until then it opened the web's console home in a Safari sheet; the
/// pages the wizard still hands to the web open the same way, from inside it
/// (``SetupHandOff``), and never through `openURL`, because `applinks:www.distronode.com`
/// claims `/dashboard/district/*` and the system would route them straight back here.
///
/// ⚠️ ITS THREE SENTENCES ARE IN THE CATALOG (`finish_setup.*`), English and French.
struct FinishSetupCard: View {
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text(FinishSetupCopy.title)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
                .accessibilityAddTraits(.isHeader)
            Text(FinishSetupCopy.body)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Button(FinishSetupCopy.action, action: onOpen)
                .buttonStyle(.districtPrimary)
                .accessibilityIdentifier(A11yID.Overview.finishSetup)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.card)
        .districtCardSurface()
        // ⛔ `.contain`, so the button keeps its own identifier and stays operable.
        .accessibilityElement(children: .contain)
    }
}

/// Every sentence the card says.
///
/// ⚠️ PINNED BY `FinishSetupTests`, and scanned by `StoreCopyTests` with the rest of
/// `Features/`: none of them may name a place to go instead of the app.
enum FinishSetupCopy {}
