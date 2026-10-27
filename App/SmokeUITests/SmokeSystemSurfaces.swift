import XCTest

/// The system surfaces the browser leg crosses: the edit menu that pastes the password, and
/// the system's offer to save that password once the login form is sent.
///
/// ⚠️ IN ITS OWN FILE SO `SmokeUITests.swift` STAYS UNDER SwiftLint's `file_length` (500),
/// an error under `--strict`. Nothing here reads the class's private state; each helper is
/// handed the process and the elements it works on.
extension SmokeUITests {
    /// The bundle id that hosts system alerts and, on some iOS versions, the save-password offer.
    static let springboardBundle = "com.apple.springboard"

    /// The button that turns down the offer to save a password, in the sheet's own words.
    static let notNow = "Not Now"

    /// Paste the demo account's password into a focused secure field.
    ///
    /// ⛔ NEVER `typeText`, AND THE TEST PROCESS NEVER HOLDS THE PASSWORD. `typeText` records an
    /// activity titled `Type '<text>' into "Password"`, in the run log, the console log and the
    /// result bundle, for a secure field as much as any other, which is how the QA fixture's
    /// password was written into an iMac run. `scripts/smoke-simulator.sh` puts it on the
    /// simulator's pasteboard with `simctl pbcopy` (from stdin, so not in argv either) and
    /// tells this suite only that it did. Every step here is a tap, a press or a query, and
    /// XCTest logs those by the element's label ("Paste", "Password"), never by content.
    ///
    /// ⚠️ THE EDIT MENU, NOT A PROGRAMMATIC PASTE. A paste the user starts from the edit menu
    /// raises no "Allow Paste" prompt; the prompt is still handled below in case an iOS
    /// version disagrees. ⚠️ AND THE PASTEBOARD IS NOT WRITTEN FROM HERE: on iOS 14.5 and
    /// later a write from the UI-test runner fails with `PBErrorDomain` 11 ("the pasteboard
    /// name com.apple.UIKit.pboard.general is not valid").
    func pastePassword(into field: XCUIElement, in process: XCUIApplication) {
        // ⚠️ A MENU ITEM OR A BUTTON: the edit menu's commands have reported as either across
        // iOS versions, and an iPad keyboard's shortcut bar carries a "Paste" button too.
        let command = NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)",
            "Paste", XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue
        )
        let paste = process.descendants(matching: .any).matching(command).firstMatch
        let empty = field.value as? String
        // A press opens the edit menu on an empty web field; a second tap on the focused
        // field is the other gesture that does, and is tried only when the press did not.
        field.press(forDuration: 1.0)
        if !paste.waitForExistence(timeout: 3) {
            field.tap()
        }
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste command in the password field's edit menu")
        paste.tap()

        if !valueChanged(field, from: empty, timeout: 3) {
            let allow = "Allow Paste"
            let springboard = XCUIApplication(bundleIdentifier: Self.springboardBundle)
            for host in [process, springboard] where host.buttons[allow].exists {
                host.buttons[allow].tap()
            }
        }
        // ⛔ THE MESSAGE NAMES THE FIELD'S STATE, NEVER ITS VALUE.
        XCTAssertTrue(
            valueChanged(field, from: empty, timeout: 5),
            "the pasted password never reached the field; smoke-simulator.sh seeds the simulator pasteboard"
        )
    }

    /// Whether a field's value moved off what it read while empty, within `timeout`.
    ///
    /// ⚠️ A CHANGE, NOT A SPELLING. A secure field reports masked characters as its value
    /// (bullets, one per character, as far as WebKit is known to publish them), and its empty
    /// value may be "" or the placeholder; comparing against the empty reading holds for any
    /// of those. ⛔ The value is compared and never printed.
    func valueChanged(_ field: XCUIElement, from empty: String?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = field.value as? String, !value.isEmpty, value != empty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
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
        let springboard = XCUIApplication(bundleIdentifier: Self.springboardBundle)
        for host in [browser, springboard] where host.state != .notRunning {
            let button = host.buttons[Self.notNow]
            if button.exists {
                button.tap()
                return true
            }
        }
        return false
    }

    /// Wait for the hand-off page's consent button after the login form is sent, standing
    /// down the save-password offer on the way and failing early on a second factor.
    ///
    /// ⛔ AN ACCOUNT WITH TOTP ENROLLED CANNOT COMPLETE THIS. The login page adds a one-time
    /// code field when the login route reports `mfaRequired`, and nothing here can produce a
    /// code, so that page fails the run by name rather than as a timeout.
    func awaitConsent(_ consent: XCUIElement, in browser: XCUIApplication) {
        let twoStep = browser.staticTexts["Two-step verification"]
        let deadline = Date().addingTimeInterval(45)
        while !consent.exists, Date() < deadline {
            XCTAssertFalse(
                twoStep.exists,
                "the demo account has a second factor enrolled; this suite cannot produce a code"
            )
            if !dismissSavePasswordOffer(over: browser) {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        XCTAssertTrue(consent.exists, "the consent screen never appeared")
        // The offer can arrive with the page and sit over the button.
        dismissSavePasswordOffer(over: browser)
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
            if dismissSavePasswordOffer(over: browser), browser.state != .notRunning, consent.exists {
                consent.tap()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return root.exists
    }
}
