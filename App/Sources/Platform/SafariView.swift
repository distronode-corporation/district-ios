import SafariServices
import SwiftUI

/// `SFSafariViewController` as a SwiftUI sheet.
///
/// ⛔ THE SYSTEM BROWSER, NOT `WKWebView`, AND NOT `openURL`. A `WKWebView` would
/// put this app's process in the middle of somebody's sign-in, which is both the
/// thing App Store review asks about and the thing that makes a password manager
/// refuse to fill; `openURL` would leave the app entirely for a page the operator
/// is expected to come straight back from. A Safari sheet is a browser the user
/// can see the address bar of, dismissed with one tap.
///
/// ⛔ IT SHARES NO COOKIES AND NO CREDENTIAL WITH THIS APP, which is exactly why
/// the scheduler hand-off has to be minted first: see ``SchedulingSSOClient``.
///
/// ⛔ THE URL MUST BE `http` OR `https`. `SFSafariViewController` traps on any
/// other scheme rather than declining, so the scheme is checked where the URL is
/// produced and never here — a view that could only crash is the wrong place for
/// that guard.
///
/// ⚠️ `updateUIViewController` IS DELIBERATELY EMPTY. `SFSafariViewController`
/// takes its URL at construction and has no way to be re-pointed, so a changed
/// `url` must arrive as a NEW controller. Presenting it with `sheet(item:)`,
/// whose identity changes per press, is what makes that happen.
///
/// ⛔ ONE COMPONENT FOR BOTH ENDS OF THE BOUND SCHEDULING HAND-OFF (S33). Leg 1 sets a
/// nonce cookie and leg 3 redeems only where that cookie is, so both legs open here,
/// in two successive controllers sharing this app's Safari-view cookie store.
/// `ASWebAuthenticationSession` uses Safari's own store instead, and mixing the two is
/// a 410 on every bound redeem.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    /// Called once with whether the INITIAL load rendered a page.
    ///
    /// ⚠️ ONLY THE HAND-OFF'S LEG 1 SETS IT. A working leg 1 never renders a page (it
    /// answers a 302 to `districtai://handoff`), so a page that loaded is the 404 or
    /// 400 of a server without leg 1, and the hand-off can fall back at once rather
    /// than at its timeout. What `SFSafariViewController` reports for a redirect to an
    /// app scheme is not documented; it is on the device-proof list.
    var onInitialLoad: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onInitialLoad: onInitialLoad)
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let onInitialLoad: ((Bool) -> Void)?

        init(onInitialLoad: ((Bool) -> Void)?) {
            self.onInitialLoad = onInitialLoad
        }

        func safariViewController(
            _ controller: SFSafariViewController,
            didCompleteInitialLoad didLoadSuccessfully: Bool
        ) {
            onInitialLoad?(didLoadSuccessfully)
        }
    }
}
