import XCTest

/// The Integrations screen against the LOOPBACK fixture server, for the pull request's
/// screenshots: the settings hub with its new row, then the screen itself.
///
/// ⚠️ THE HOST TAKES THE FRAMES, NOT THIS RUNNER, as in ``DeleteAccountScreenshotTests``: for
/// each state it writes `want-<name>` into `DISTRICT_SHOTS_DIR` and waits for `done-<name>`.
/// Every variable arrives as `TEST_RUNNER_<name>`.
///
/// ⚠️ NOT IN CI: it needs the fixture server, the loop and a session, and skips without them.
/// It changes nothing: the screen's only control opens a sheet, which is not pressed here.
final class IntegrationsScreenshotTests: XCTestCase {
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

    func test_01_theHubAndTheScreen() {
        launch()
        openSettings()

        let row = element(A11yID.Settings.row("integrations"))
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the Integrations row")
        capture("01-hub")

        row.tap()
        XCTAssertTrue(element(A11yID.Integrations.calendar("google")).waitForExistence(timeout: 30))
        capture("02-integrations")
    }

    private func launch() {
        app.launchArguments = [
            "-UITestSession",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language.replacingOccurrences(of: "-", with: "_"),
        ]
        for name in ["DISTRICT_UITEST_SESSION", "DISTRICT_UITEST_BASE_URL"] {
            app.launchEnvironment[name] = environment[name]
        }
        // ⚠️ LANDSCAPE ON AN IPAD, as in ``DeleteAccountScreenshotTests``.
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(
            element(A11yID.Overview.root).waitForExistence(timeout: 30),
            "the fixture session must reach the shell"
        )
        if ShellNavigator.isCompact(app) {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// The Overview's settings row at compact width, the sidebar's otherwise (a regular-width
    /// Overview draws no entry points). By identifier: a French run draws no English labels.
    private func openSettings() {
        let isCompact = ShellNavigator.isCompact(app)
        let settings = isCompact
            ? element(A11yID.Overview.row("settings"))
            : app.cells.containing(.any, identifier: A11yID.Sidebar.settings).firstMatch
        // ⚠️ THE SIDEBAR IS LAZY: its last rows do not exist until it is scrolled, so the
        // wait comes after the swipes rather than before them.
        _ = element(A11yID.Overview.root).waitForExistence(timeout: 30)
        var swipes = 0
        while !(settings.exists && settings.isHittable), swipes < 8 {
            if isCompact {
                app.swipeUp()
            } else {
                app.collectionViews.firstMatch.swipeUp()
            }
            swipes += 1
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "the settings entry point")
        settings.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Ask the host for a frame of the screen as it is now, and wait until it has one.
    private func capture(_ name: String) {
        guard let shots else { return }
        usleep(800_000)
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
