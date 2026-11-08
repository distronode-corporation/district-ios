import XCTest

/// Walks a thread's received attachments against the LOOPBACK fixture server and asks the host
/// to capture each state with `simctl io screenshot`: a PDF's file tile, an image, a carrier
/// URL that answers 401, then the PDF in Quick Look and its share sheet.
///
/// ⛔ NEVER AGAINST A REAL ACCOUNT: it SKIPS unless the base URL it is given is
/// `http://127.0.0.1`. It reads and opens; it sends nothing.
///
/// ⚠️ THE HOST TAKES THE FRAMES, NOT THIS RUNNER, as in ``DeleteAccountScreenshotTests``: for
/// each state it writes `want-<name>` into `DISTRICT_SHOTS_DIR` and waits for `done-<name>`.
/// Every variable arrives as `TEST_RUNNER_<name>`.
///
/// ⚠️ NOT IN CI: it needs the fixture server, the loop and a session, and skips without them.
final class AttachmentPreviewScreenshotTests: XCTestCase {
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

    func test_01_receivedAttachments() {
        launch()
        openInbox()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", A11yID.Inbox.rowBase)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the fixture thread's row")
        row.tap()

        let tile = element(A11yID.Inbox.attachmentFile)
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "the PDF's file tile")
        XCTAssertTrue(element(A11yID.Inbox.attachmentUnavailable).waitForExistence(timeout: 20), "the 401 state")
        usleep(800_000)
        capture("01-thread")

        tile.tap()
        // ⚠️ QUICK LOOK IS UP WHEN THE TILE IS COVERED.
        let deadline = Date().addingTimeInterval(15)
        while tile.isHittable, Date() < deadline {
            usleep(250_000)
        }
        XCTAssertFalse(tile.isHittable, "Quick Look covers the thread")
        // ⚠️ QUICK LOOK DRAWS THE PAGE A BEAT AFTER ITS CHROME.
        sleep(5)
        capture("02-preview")

        // ⚠️ QUICK LOOK'S OWN SHARE BUTTON, found by its system label in either language.
        let share = app.buttons.matching(NSPredicate(format: "label IN %@", ["Share", "Partager"])).firstMatch
        if share.waitForExistence(timeout: 5) {
            share.tap()
            sleep(2)
            capture("03-share")
        }
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
        // ⚠️ LANDSCAPE ON AN IPAD, so the sidebar is on screen (see ``DeleteAccountScreenshotTests``).
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

    /// The Inbox tab by POSITION (the second) at compact width, the sidebar row otherwise.
    /// ⚠️ ``ShellNavigator`` finds both by English labels, which a French run does not draw.
    private func openInbox() {
        if ShellNavigator.isCompact(app) {
            let tabs = app.tabBars.buttons
            XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 30), "the tab bar")
            tabs.element(boundBy: 1).tap()
        } else {
            let row = app.cells.containing(.any, identifier: A11yID.Sidebar.inbox).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the Inbox row")
            row.tap()
        }
        XCTAssertTrue(element(A11yID.Inbox.root).waitForExistence(timeout: 20))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Ask the host for a frame of the screen as it is now, and wait until it has one.
    private func capture(_ name: String) {
        guard let shots else { return }
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
