import XCTest

/// The system surfaces the browser leg crosses: the password the script types, and the
/// system's offer to save that password once the login form is sent.
///
/// ⚠️ IN ITS OWN FILE SO `SmokeUITests.swift` STAYS UNDER SwiftLint's `file_length` (500),
/// an error under `--strict`. Nothing here reads the class's private state; each helper is
/// handed the process and the elements it works on.
extension SmokeUITests {
    /// The bundle id that hosts system alerts and, on some iOS versions, the save-password offer.
    static let springboardBundle = "com.apple.springboard"

    /// The button that turns down the offer to save a password, in the sheet's own words.
    static let notNow = "Not Now"

    /// The step title `scripts/smoke-simulator.sh` watches the live log for. ⛔ KEEP IN STEP with
    /// `PASSWORD_MARKER` there: the two are linked by this string alone.
    static let passwordMarker = "SMOKE-TYPE-PASSWORD-NOW"

    /// Hand the focused password field to the script, which types the password into it.
    ///
    /// ⛔ NEVER `typeText`, AND THIS PROCESS NEVER HOLDS THE PASSWORD. `typeText` records an
    /// activity titled `Type '<text>' into "Password"`, in the run log, the console log and the
    /// result bundle, for a secure field as much as any other, which is how the QA fixture's
    /// password was written into an iMac run. A per-key tap is no better: each is logged by the
    /// key's label, one character at a time.
    ///
    /// ⛔ AND NOT A PASTE. The sign-in page runs in `SafariViewService`, whose paste never
    /// reads what `simctl pbcopy` writes: the Paste command appeared and was tapped and the
    /// field stayed empty (iPhone 17 Pro and iPad Pro 13, PR #91 smoke).
    ///
    /// So this logs one step named `passwordMarker` and returns. The script sees that step in
    /// xcodebuild's live output and types the password, then Return, into the simulator as
    /// keystrokes from System Events (Sean, GitLab #2 note 4096242351), which XCTest does not
    /// see. Return sends the form; `awaitConsent(_:in:loginButton:)` reads the outcome from
    /// the page.
    func awaitScriptedPassword() {
        XCTContext.runActivity(named: Self.passwordMarker) { _ in }
    }

    /// Turn down the system's offer to save the password just sent, if it is on screen.
    /// Returns whether it was.
    ///
    /// ⛔ ON A FRESH SIMULATOR iOS OFFERS TO SAVE THE PASSWORD AFTER "Enter platform", AND
    /// THE SHEET COVERS THE PAGE: the consent button never surfaces and the run times out at
    /// "the consent screen never appeared". The sheet belongs to the system, not the app,
    /// and depending on the iOS version it is drawn by `SafariViewService` (the browser
    /// process) or by SpringBoard, so both are asked. ⚠️ A CHECK, NOT A WAIT: the callers
    /// poll it beside the element they are waiting for, so a run without the sheet pays one
    /// query per poll and never a timeout.
    /// ⚠️ `addUIInterruptionMonitor` IS NOT USED: its handler runs only when the next
    /// interaction is with the app under test, and the next one here is with the browser.
    @discardableResult
    func dismissSavePasswordOffer(over browser: XCUIApplication) -> Bool {
        // ⚠️ A STRAY TAP CAN PRESS CONSENT. When the system dismisses the sheet first, the tap
        // below lands on the page under it, which can be the consent button (iPhone 17 Pro,
        // PR #91 smoke). So consent is pressed through `pressIfPresent(_:)` and the waits accept
        // a page already past consent; a stray press is then harmless.
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardBundle)
        for host in [browser, springboard] where host.state != .notRunning {
            // ⚠️ A SNAPSHOT AND A COORDINATE TAP, NEVER `exists` THEN `tap()`. The sheet can
            // slide away between the two, and `tap()` on an element that has gone fails the test
            // ("no matches found for ... Not Now", iPhone 17 Pro, PR #91 smoke). `snapshot()`
            // throws instead of failing, and a tap at a point cannot fail; a sheet that went away
            // by itself is the outcome this wanted anyway.
            guard let sheet = try? host.buttons[Self.notNow].snapshot() else { continue }
            host.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: sheet.frame.midX, dy: sheet.frame.midY))
                .tap()
            return true
        }
        return false
    }

    /// Tap a field until it holds keyboard focus, failing by name if it never does.
    ///
    /// ⚠️ ONE TAP IS NOT FOCUS ON A SLOW SIMULATOR. On an iPad Pro 13 the tap on "Work Email"
    /// landed before the page took input, and the next `typeText` failed with "Neither element
    /// nor any descendant has keyboard focus" (PR #91 smoke). ⛔ AND THE PASSWORD FIELD MUST HOLD
    /// FOCUS before the script is asked to type: its keystrokes go to whatever has it.
    func focus(_ field: XCUIElement, named name: String) {
        for _ in 0..<4 {
            field.tap()
            let deadline = Date().addingTimeInterval(4)
            repeat {
                if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true {
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            } while Date() < deadline
        }
        XCTFail("the \(name) field never took keyboard focus")
    }

    /// Wait for the hand-off page's consent button after the login form is sent, standing
    /// down the save-password offer on the way and failing early on a second factor.
    ///
    /// ⛔ AN ACCOUNT WITH TOTP ENROLLED CANNOT COMPLETE THIS. The login page adds a one-time
    /// code field when the login route reports `mfaRequired`, and nothing here can produce a
    /// code, so that page fails the run by name rather than as a timeout.
    ///
    /// ⚠️ THIS IS WHERE A PASSWORD THAT NEVER LANDED SHOWS. An empty password field either keeps
    /// the form from being sent or has the sign-in refused; both leave `loginButton` on the
    /// page, so a run that ends there says so, rather than "the consent screen never appeared".
    /// ⛔ The messages name the page's state, never a field's value.
    ///
    /// Returns true when the consent button is on screen, false when the sign-in sheet has already
    /// moved past it (a stray tap pressed it, see `dismissSavePasswordOffer(over:)`).
    @discardableResult
    func awaitConsent(_ consent: XCUIElement, in browser: XCUIApplication, loginButton: XCUIElement) -> Bool {
        let twoStep = browser.staticTexts["Two-step verification"]
        // The website's `authErrors.CredentialsSignin` (English login copy).
        let refused = browser.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Invalid credentials")
        ).firstMatch
        let deadline = Date().addingTimeInterval(45)
        // Past consent: the login form and the consent button both gone from the sheet.
        let pastConsent = { !consent.exists && !loginButton.exists && !browser.webViews.firstMatch.exists }
        while !consent.exists, !pastConsent(), Date() < deadline {
            XCTAssertFalse(
                twoStep.exists,
                "the demo account has a second factor enrolled; this suite cannot produce a code"
            )
            XCTAssertFalse(
                refused.exists,
                "the login page refused the sign-in: the typed password did not arrive, "
                    + "or the demo account's password changed"
            )
            if !dismissSavePasswordOffer(over: browser) {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        XCTAssertFalse(
            !consent.exists && loginButton.exists,
            "still on the login page after 45 s: the script's password never reached the field"
        )
        if pastConsent() {
            return false
        }
        XCTAssertTrue(consent.exists, "the consent screen never appeared")
        // The offer can arrive with the page and sit over the button.
        dismissSavePasswordOffer(over: browser)
        return true
    }

    /// Wait for the app to take back the handshake after the consent press.
    ///
    /// ⚠️ A SAVE-PASSWORD SHEET THAT SLID UP AS THE BUTTON WAS PRESSED TAKES THE PRESS, so
    /// when one is turned down here and the consent button is still on the page, it is
    /// pressed again. A press the page did take navigates away from the button, so the
    /// second press only ever stands in for one that was lost.
    func awaitLanding(on root: XCUIElement, consent: XCUIElement, browser: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(90)
        while !root.exists, Date() < deadline {
            if dismissSavePasswordOffer(over: browser), browser.state != .notRunning {
                pressIfPresent(consent)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return root.exists
    }

    /// Press a web button if it is still on screen; a button already gone is skipped.
    ///
    /// ⚠️ NOT `exists` THEN `tap()`: the page can move on between the two (a stray press, the
    /// sheet closing), and `tap()` on a gone element fails the test. `snapshot()` throws instead.
    func pressIfPresent(_ button: XCUIElement) {
        guard let shot = try? button.snapshot() else { return }
        XCUIApplication().coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: shot.frame.midX, dy: shot.frame.midY))
            .tap()
    }
}
