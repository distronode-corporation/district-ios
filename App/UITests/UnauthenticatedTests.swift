import XCTest

/// The subset that runs with no credential anywhere — on an unsigned CI simulator.
///
/// ⛔ IT PROVES THE APP DOES NOT LET ITSELF IN. Every other class here is handed a
/// session; this one asserts the state a stranger meets, which is the only state CI
/// can ever legitimately reach. ⚠️ It must keep passing when `test:ios:ui` runs with
/// `CODE_SIGNING_ALLOWED=NO` and no `DISTRICT_UITEST_SESSION` in the environment.
final class UnauthenticatedTests: UITestApp {
    /// ⛔ SKIPPED ON A SIGNED-IN APP RATHER THAN FAILED. Against a signed handset these
    /// three cases would fail, because a signed build keeps its session in the keychain
    /// and the app goes straight to the shell:
    /// the premise "a launch with no session" is a property of the UNSIGNED CI
    /// simulator, not of "the device". Failing there would report a bug in the app for
    /// what is really the wrong environment.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(isSignedIn, "this app is signed in; the unauthenticated gate is not reachable here")
    }

    func test_IOS_AUTH_01_signInRootIsPresented() {
        XCTAssertTrue(
            element(A11yID.SignIn.root).waitForExistence(timeout: 30),
            "a launch with no session must land on the sign-in gate"
        )
        screenshot("IOS-AUTH-01-sign-in-root")
    }

    func test_IOS_AUTH_02_signInControlIsOfferedAndHittable() {
        let button = element(A11yID.SignIn.button)
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        XCTAssertTrue(button.isHittable, "the only way forward must be reachable")
    }

    /// ⛔ APP STORE REVIEW GUIDELINE 4.8, ASSERTED RATHER THAN REMEMBERED. The
    /// other door opens the server's login surface, which offers Google and
    /// Microsoft SSO, so Apple requires an equivalent privacy-preserving option
    /// on the same screen. This is the only automated check that the button is
    /// actually ON the sign-in gate: it is Apple's own control behind a
    /// representable, so a unit test can assert the handlers and the nonce but
    /// not that anything was ever rendered.
    ///
    /// ⚠️ `isHittable`, NOT `exists`. A button pushed off the bottom of the card
    /// still exists, and an offered-but-unreachable option is not offered.
    ///
    /// ⛔ AND IT IS NEVER TAPPED. Tapping raises the system's Apple ID sheet,
    /// which a simulator cannot complete and which on a real handset would drive
    /// a real authorisation against a real Apple ID on every run. The end-to-end
    /// proof is a signed device install, by hand.
    func test_IOS_AUTH_04_signInWithAppleIsOffered() {
        let apple = element(A11yID.SignIn.apple)
        XCTAssertTrue(
            apple.waitForExistence(timeout: 30),
            "Guideline 4.8: Sign in with Apple must be offered beside the SSO door"
        )
        XCTAssertTrue(apple.isHittable, "the Apple door exists but cannot be reached")
        screenshot("IOS-AUTH-04-sign-in-with-apple")
    }

    /// ⛔ NOTHING AUTO-TAPS, AND THIS ASSERTS THE ABSENCE. `signIn()` opens an
    /// `ASWebAuthenticationSession` consent sheet; a suite that tapped it would be
    /// driving a real OAuth flow against a real account on every CI run.
    func test_IOS_AUTH_03_noSessionSheetIsRaisedWithoutATap() {
        XCTAssertTrue(element(A11yID.SignIn.root).waitForExistence(timeout: 30))
        // The consent sheet belongs to SafariViewService, out of this app's process.
        XCTAssertFalse(
            app.webViews.firstMatch.waitForExistence(timeout: 3),
            "no web sheet may open unless a person taps for it"
        )
    }

    /// ⚠️ THE FORBIDDEN SET IS ASSERTED, not merely defined, so deleting an entry is
    /// a test failure rather than a silent widening of what a run may touch.
    func test_IOS_SEC_02_destructiveSurfacesAreDeclaredForbidden() {
        for id in [
            A11yID.Contacts.add, A11yID.Account.signOut, A11yID.Account.delete,
            A11yID.Marketplace.release, A11yID.Inbox.send, A11yID.Dialer.call,
        ] {
            XCTAssertTrue(UITestApp.forbiddenSurfaces.contains(id), "\(id) dropped out of the forbidden set")
        }
    }
}
