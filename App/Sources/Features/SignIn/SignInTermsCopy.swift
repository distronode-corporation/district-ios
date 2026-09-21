import Foundation

/// The terms line shown under the sign-in controls, and the two pages it opens.
///
/// ⛔ IT IS THERE FOR APP STORE REVIEW GUIDELINE 1.2, WHICH REQUIRES THE TERMS TO BE
/// PRESENTED **BEFORE** A USER SIGNS IN — not buried in an Account screen behind the
/// gate. The placement is the requirement rather than a convention: it sits on
/// the one screen a user cannot get past without reading it.
///
/// ⛔ THIS IS NOT A CROSSING OF `SignInView`'s "NO OTHER PATH OUT OF THIS SCREEN"
/// RULE, AND THE DISTINCTION IS THE GUIDELINE RATHER THAN THE URL. That rule is
/// about Guideline 3.1.3(b): an offer to create an account, subscribe or "learn
/// more" is a purchase path, and steering a user to a browser to buy is what earns a
/// rejection. `/terms` and `/privacy` are the legal disclosures Guidelines 1.2 and
/// 5.1.1 REQUIRE, they carry no price, no plan and no sign-up form, and Apple's own
/// metadata fields name the same two URLs. Removing them to satisfy 3.1.3(b) would
/// breach 1.2, which is the trade this comment exists to stop being re-litigated.
///
/// ⛔ THE SENTENCE IS ASSEMBLED FROM THESE FRAGMENTS AND NOWHERE ELSE, BECAUSE THE
/// LINK NAMES ARE ALSO THE PAGE TITLES. `Terms of Service` and `Privacy Policy` are
/// what the pages are called and what the store listing's own fields say; a second
/// copy of either string inside the view would let the button and the page disagree
/// the first time one was reworded. ``sentence`` is the whole line as a reader sees
/// it and is what `SignInTermsCopyTests` pins.
///
/// ⚠️ THE FRAGMENTS CARRY THEIR OWN SPACES rather than relying on an `HStack`'s
/// spacing, so the composed sentence is the literal a test can compare. A layout
/// container's gap is not in the string.
enum SignInTermsCopy {
    static let prefix = "By continuing you agree to the"
    static let termsName = "Terms of Service"
    static let conjunction = " and "
    static let privacyName = "Privacy Policy"
    static let terminator = "."

    /// The whole line, as a reader reads it.
    ///
    /// ⚠️ COMPUTED FROM THE FRAGMENTS, NEVER WRITTEN OUT A SECOND TIME. A literal
    /// here would be a copy that could drift from the controls it describes, which is
    /// the one thing a sentence split across three views is at risk of.
    static var sentence: String {
        "\(prefix) \(termsName)\(conjunction)\(privacyName)\(terminator)"
    }

    /// ⛔ FULL URLS RATHER THAN PATHS ON THE API BASE, for the reason
    /// ``AccountView/accountDeletionURL`` gives: these are legal pages that must
    /// resolve for a reviewer with no session and no app build config, and they are
    /// the URLs declared in the App Store listing's own Privacy Policy and
    /// End User Licence Agreement fields. A build pointed at a staging host still
    /// shows the published terms, which is correct — the terms are the company's,
    /// not the environment's.
    ///
    /// ⚠️ SILENT ON A NIL URL RATHER THAN FORCE-UNWRAPPING, matching
    /// `AccountView.openDeletionPage`. Both literals parse, so the guard at the call
    /// site is unreachable today; a crash on the sign-in screen because somebody
    /// edited a string is not a trade worth making.
    static let termsURL = URL(string: "https://www.distronode.com/terms")
    static let privacyURL = URL(string: "https://www.distronode.com/privacy")
}
