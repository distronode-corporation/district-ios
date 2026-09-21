import DistrictModel
import SwiftUI

/// The owner mid-setup is offered the rest of the setup wizard.
///
/// ⛔ THE COPY NAMES NO DESTINATION, AND THAT IS `StoreCopyTests`, NOT TASTE. Guideline
/// 3.1.1 forbids steering, so no string in `Features/` may name the web, a browser, a
/// dashboard or the site. So the card says
/// what is left to do and what the button does, and the page it opens speaks for itself.
///
/// ⛔ THE BUTTON OPENS AN IN-APP SAFARI SHEET, NEVER `openURL`, FOR THE REASON ``ShellView``
/// RECORDS ON ITS OWN HAND-OFF. `applinks:www.distronode.com` claims `/dashboard/district/*`,
/// so asking the system to open that URL routes it straight back into this app: a relaunch
/// loop with no user input in the cycle. A ``SafariView`` renders the page in-process and
/// consults no associated-domain routing, so it cannot loop. Android reaches the same place
/// with `launchExternally`, which names a browser package explicitly.
///
/// ⚠️ ENGLISH ONLY, like the rest of both native apps, by decision.
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
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
        // ⛔ `.contain`, so the button keeps its own identifier and stays operable.
        .accessibilityElement(children: .contain)
    }

    /// Where the button goes: the District console home on the host this build talks to.
    ///
    /// ⚠️ DERIVED FROM THE CONTAINER'S BASE URL, never a literal, so a staging build hands
    /// off to staging (the rule ``AppContainer/baseURL`` states). The path is
    /// ``AppLinkResolver/pathPrefix``, the prefix the app already claims, so it names the
    /// same page the association file does and cannot drift from it.
    static func destination(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        // ⛔ HTTPS ONLY: `SFSafariViewController` traps on any other scheme.
        guard components.scheme == "https" else { return nil }
        components.path = AppLinkResolver.pathPrefix
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// Every sentence the card says.
///
/// ⚠️ PINNED BY `FinishSetupTests`, and scanned by `StoreCopyTests` with the rest of
/// `Features/`: none of them may name a place to go instead of the app.
enum FinishSetupCopy {
    static let title = "Finish setting up"
    static let body = "A few setup steps for this workspace are still open."
    static let action = "Open setup"
}
