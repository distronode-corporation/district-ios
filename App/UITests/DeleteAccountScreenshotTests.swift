import XCTest

/// Walks every state of the in-app account deletion against the LOOPBACK fixture server and
/// asks the host to capture each one with `simctl io screenshot`.
///
/// ⛔ NEVER AGAINST A REAL ACCOUNT. It presses Delete my account
/// (``UITestApp/forbiddenSurfaces``), so it SKIPS unless the base URL it is given is
/// `http://127.0.0.1`, where the fixture server answers the re-authentication and the deletion
/// and deletes nothing.
///
/// ⚠️ THE HOST TAKES THE FRAMES, NOT THIS RUNNER, as in ``LiveSuperviseScreenshotTests``: for
/// each state it writes `want-<name>` into `DISTRICT_SHOTS_DIR` and waits for `done-<name>`.
/// Every variable arrives as `TEST_RUNNER_<name>`.
///
/// ⚠️ NOT IN CI: it needs the fixture server, the loop and a session, and skips without them.
/// The SSO sheet is the system's and is not drawn here; the password path stands in for it.
final class DeleteAccountScreenshotTests: XCTestCase {
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

    func test_01_everyStep() {
        launch()
        openAccount()
        let row = element(A11yID.Account.delete)
        var swipes = 0
        while !row.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        capture("01-account")

        row.tap()
        XCTAssertTrue(element(A11yID.DeleteAccount.usePassword).waitForExistence(timeout: 10))
        capture("02-explain")

        element(A11yID.DeleteAccount.usePassword).tap()
        type("wrong", into: A11yID.DeleteAccount.password)
        element(A11yID.DeleteAccount.passwordContinue).tap()
        XCTAssertTrue(element(A11yID.DeleteAccount.message).waitForExistence(timeout: 10))
        capture("03-wrong-password")

        type("two-step", into: A11yID.DeleteAccount.password)
        element(A11yID.DeleteAccount.passwordContinue).tap()
        XCTAssertTrue(element(A11yID.DeleteAccount.code).waitForExistence(timeout: 10))
        type("two-step", into: A11yID.DeleteAccount.password)
        type("123456", into: A11yID.DeleteAccount.code)
        capture("04-two-step-code")

        element(A11yID.DeleteAccount.passwordContinue).tap()
        XCTAssertTrue(element(A11yID.DeleteAccount.email).waitForExistence(timeout: 10))
        type("me@example.test", into: A11yID.DeleteAccount.email)
        capture("05-last-step")

        element(A11yID.DeleteAccount.submit).tap()
        XCTAssertTrue(element(A11yID.DeleteAccount.message).waitForExistence(timeout: 10))
        capture("06-email-mismatch")

        // ⚠️ THE MISTYPED ADDRESS IS KEPT, to be corrected: erased key by key.
        let email = element(A11yID.DeleteAccount.email)
        email.tap()
        email.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        email.typeText("you@example.test")
        element(A11yID.DeleteAccount.submit).tap()
        XCTAssertTrue(element(A11yID.SignIn.status).waitForExistence(timeout: 20), "the sign-in screen")
        capture("07-deleted")
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
