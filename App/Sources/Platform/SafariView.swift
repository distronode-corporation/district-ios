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
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
