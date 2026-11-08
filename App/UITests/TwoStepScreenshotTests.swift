import XCTest

/// Walks every state of two-step verification (Account, Two-step verification) against the
/// LOOPBACK fixture server and asks the host to capture each one with `simctl io screenshot`.
///
/// ⛔ NEVER AGAINST A REAL ACCOUNT. It turns two-step verification on and off
/// (``UITestApp/forbiddenSurfaces``), so it SKIPS unless the base URL it is given is
/// `http://127.0.0.1`, where the fixture server answers from district-core-swift 8.5.0's
/// vendored `district-mfa-*` fixtures and changes nothing anywhere.
///
/// ⚠️ THE HOST TAKES THE FRAMES, NOT THIS RUNNER, as in ``DeleteAccountScreenshotTests``: for
/// each state it writes `want-<name>` into `DISTRICT_SHOTS_DIR` and waits for `done-<name>`.
/// Every variable arrives as `TEST_RUNNER_<name>`.
///
/// ⚠️ NOT IN CI: it needs the fixture server, the loop and a session, and skips without them.
/// The SSO sheet is the system's and is not drawn here; the password path stands in for it.
final class TwoStepScreenshotTests: XCTestCase {
    private let app = XCUIApplication()
    private var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    private var shots: String? {
        environment["DISTRICT_SHOTS_DIR"]
    }

    private var server: String {
        environment["DISTRICT_UITEST_BASE_URL"] ?? ""
    }

    private var language: String {
        environment["DISTRICT_SHOTS_LANGUAGE"] ?? "en"
    }

    private var prefix: String {
        environment["DISTRICT_SHOTS_PREFIX"] ?? ""
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(server.hasPrefix("http://127.0.0.1:"), "only against the loopback fixture server")
        try XCTSkipUnless(shots != nil, "no capture folder")
    }

    func test_01_onThenOff() {
        launch()
        openAccount()
        let row = element(A11yID.Account.twoStep)
        var swipes = 0
        while !row.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        capture("01-account")

        row.tap()
        XCTAssertTrue(element(A11yID.TwoStep.turnOn).waitForExistence(timeout: 10), "off, from the fixture server")
        capture("02-off")

        element(A11yID.TwoStep.turnOn).tap()
        XCTAssertTrue(element(A11yID.TwoStep.usePassword).waitForExistence(timeout: 10))
        capture("03-confirm-it-is-you")

        element(A11yID.TwoStep.usePassword).tap()
        type("wrong", into: A11yID.TwoStep.password)
        element(A11yID.TwoStep.passwordContinue).tap()
        XCTAssertTrue(element(A11yID.TwoStep.message).waitForExistence(timeout: 10))
        capture("04-wrong-password")

        type("correct", into: A11yID.TwoStep.password)
        element(A11yID.TwoStep.passwordContinue).tap()
        XCTAssertTrue(element(A11yID.TwoStep.qr).waitForExistence(timeout: 10), "the QR code")
        capture("05-scan")

        enterCode("000000")
        XCTAssertTrue(element(A11yID.TwoStep.message).waitForExistence(timeout: 10))
        capture("06-wrong-code")

        enterCode("123456")
        XCTAssertTrue(element(A11yID.TwoStep.codes).waitForExistence(timeout: 10), "the recovery codes")
        capture("07-recovery-codes")

        element(A11yID.TwoStep.codesDone).tap()
        XCTAssertTrue(element(A11yID.TwoStep.turnOff).waitForExistence(timeout: 10), "on")
        capture("08-on")

        element(A11yID.TwoStep.turnOff).tap()
        XCTAssertTrue(element(A11yID.TwoStep.usePassword).waitForExistence(timeout: 10))
        element(A11yID.TwoStep.usePassword).tap()
        type("two-step", into: A11yID.TwoStep.password)
        element(A11yID.TwoStep.passwordContinue).tap()
        XCTAssertTrue(element(A11yID.TwoStep.code).waitForExistence(timeout: 10))
        type("two-step", into: A11yID.TwoStep.password)
        type("123456", into: A11yID.TwoStep.code)
        capture("09-turn-off-code")

        element(A11yID.TwoStep.passwordContinue).tap()
        XCTAssertTrue(element(A11yID.TwoStep.turnOn).waitForExistence(timeout: 10), "off again")
        capture("10-off-again")
    }

    // MARK: - Helpers

    private func launch() {
        app.launchArguments = [
            "-UITestSession",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language.replacingOccurrences(of: "-", with: "_"),
        ]
        for name in ["DISTRICT_UITEST_SESSION", "DISTRICT_UITEST_BASE_URL"] {
            app.launchEnvironment[name] = environment[name]
        }
        // ⚠️ LANDSCAPE ON AN IPAD, so the sidebar is on screen: ``ShellNavigator`` finds a hidden
        // one by its English "Show Sidebar" label, which a French run does not draw.
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(
            element(A11yID.Overview.root).waitForExistence(timeout: 30),
            "the fixture session must reach the shell"
        )
        if !ShellNavigator.isCompact(app) {
            XCTAssertTrue(ShellNavigator.shellIsUp(in: app, timeout: 10), "the sidebar")
        } else {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// The Account tab by POSITION (the last one) at compact width, the sidebar row otherwise.
    /// ⚠️ ``ShellNavigator`` finds both by English labels, which a French run does not draw.
    private func openAccount() {
        if ShellNavigator.isCompact(app) {
            let tabs = app.tabBars.buttons
            XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 30), "the tab bar")
            tabs.element(boundBy: tabs.count - 1).tap()
        } else {
            // ⚠️ BY IDENTIFIER, NOT THROUGH ``ShellNavigator``, which finds the sidebar by its
            // English "Sidebar" label.
            let row = app.cells.containing(.any, identifier: A11yID.Sidebar.account).firstMatch
            var swipes = 0
            while !(row.exists && row.isHittable), swipes < 6 {
                app.collectionViews.firstMatch.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the Account row")
            row.tap()
        }
        XCTAssertTrue(element(A11yID.Account.root).waitForExistence(timeout: 20))
    }

    /// ⚠️ IN A LANDSCAPE IPAD'S FORM SHEET THE CODE FIELD SITS ON THE SHEET'S BOTTOM EDGE, half
    /// clipped, and a tap there lands outside it: scroll the sheet's own content up first.
    ///
    /// ⚠️ AND THE KEYBOARD COVERS TURN ON THERE, so a regular-width run submits with the field's
    /// return key (the same `confirm()`); an iPhone's number pad has none, so it taps the button.
    private func enterCode(_ code: String) {
        app.scrollViews.containing(.any, identifier: A11yID.TwoStep.totp).firstMatch.swipeUp()
        if ShellNavigator.isCompact(app) {
            type(code, into: A11yID.TwoStep.totp)
            element(A11yID.TwoStep.confirm).tap()
        } else {
            type(code + "\n", into: A11yID.TwoStep.totp)
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), identifier)
        field.tap()
        field.typeText(text)
    }

    /// Ask the host for a frame of the screen as it is now, and wait until it has one.
    private func capture(_ name: String) {
        guard let shots else { return }
        // ⚠️ THE CARET BLINKS: a beat so the frame is not taken mid-animation.
        usleep(600_000)
        let want = URL(fileURLWithPath: shots).appendingPathComponent("want-\(prefix)\(name)")
        let done = URL(fileURLWithPath: shots).appendingPathComponent("done-\(prefix)\(name)")
        FileManager.default.createFile(atPath: want.path, contents: Data())
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            usleep(200_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "the host did not capture \(name)")
    }
}
