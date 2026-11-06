import XCTest

/// Walks every Live supervise state against the LOOPBACK fixture server and asks the host to
/// capture each one with `simctl io screenshot`.
///
/// ⛔ NEVER AGAINST A REAL WORKSPACE. It presses Listen, Take over and Send note, each of which
/// reaches a customer's call (``UITestApp/forbiddenSurfaces``), so it SKIPS unless the base URL
/// it is given is `http://127.0.0.1`, and the media are the app's debug-only staged device
/// (`DISTRICT_UITEST_STAGED_MEDIA=1`, `StagedSuperviseMedia`): no CallKit call and no room.
///
/// ⚠️ THE HOST TAKES THE FRAMES, NOT THIS RUNNER. For each state it writes `want-<name>` into
/// `DISTRICT_SHOTS_DIR` and waits for `done-<name>`, which the host's capture loop writes after
/// `xcrun simctl io <udid> screenshot <name>.png`. Every variable arrives as `TEST_RUNNER_<name>`.
///
/// ⚠️ NOT IN CI: it needs the fixture server, the loop and a session, and skips without them.
final class LiveSuperviseScreenshotTests: XCTestCase {
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

    private func launch(role: String) {
        fixture("set?reset=1&calls=none&monitor=ok&receipt=used&stale=&role=\(role)")
        app.launchArguments = [
            "-UITestSession",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language.replacingOccurrences(of: "-", with: "_"),
        ]
        for name in ["DISTRICT_UITEST_SESSION", "DISTRICT_UITEST_BASE_URL"] {
            app.launchEnvironment[name] = environment[name]
        }
        app.launchEnvironment["DISTRICT_UITEST_STAGED_MEDIA"] = "1"
        app.launch()
        XCTAssertTrue(ShellNavigator.shellIsUp(in: app, timeout: 30), "the fixture session must reach the shell")
        openLive()
    }

    // MARK: - A writer: every state

    func test_01_everyStateAsAWriter() {
        launch(role: "agency")
        XCTAssertTrue(element(A11yID.Live.empty).waitForExistence(timeout: 20))
        capture("01-list-empty")

        fixture("set?calls=some")
        refreshList()
        XCTAssertTrue(element(A11yID.Live.row("cmhlive01maya")).waitForExistence(timeout: 20))
        capture("02-list")

        element(A11yID.Live.row("cmhlive01maya")).tap()
        XCTAssertTrue(element(A11yID.Live.listen).waitForExistence(timeout: 20))
        waitForTranscript()
        capture("03-idle")

        element(A11yID.Live.listen).tap()
        capture("04-connecting")
        XCTAssertTrue(element(A11yID.Live.takeOver).waitForExistence(timeout: 20))
        capture("05-listening")

        sendNote(language == "en" ? "Offer a visit today before 4 p.m." : "Offrez une visite aujourd'hui avant 16 h.")
        XCTAssertTrue(element(A11yID.Live.receipt).waitForExistence(timeout: 20))
        capture("06-receipt-used")

        element(A11yID.Live.takeOver).tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        capture("07-take-over-confirm")
        // ⚠️ BY LABEL: a French alert stacks its buttons and puts Cancel last.
        alert.buttons[language == "en" ? "Take over" : "Prendre l'appel"].tap()
        capture("08-taking-over")
        XCTAssertTrue(element(A11yID.Live.handBack).waitForExistence(timeout: 20))
        capture("09-taken-over")

        element(A11yID.Live.mute).tap()
        sleep(1)
        capture("10-taken-over-muted")

        element(A11yID.Live.handBack).tap()
        XCTAssertTrue(element(A11yID.Live.listen).waitForExistence(timeout: 20))
        fixture("set?receipt=notUsed")
        sendNote(language == "en" ? "Ask if they have photos." : "Demandez s'il a des photos.")
        XCTAssertTrue(element(A11yID.Live.receipt).waitForExistence(timeout: 20))
        sleep(3)
        capture("11-handed-back-receipt-not-used")

        fixture("end?callId=cmhlive01maya")
        XCTAssertTrue(app.staticTexts[language == "en" ? "The call has ended." : "L'appel est terminé."]
            .waitForExistence(timeout: 20))
        capture("12-call-ended")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(A11yID.Live.row("cmhlive03priya")).waitForExistence(timeout: 20))
        sleep(2)
        capture("13-list-after-end")
        otherCalls()
    }

    /// A colleague's own softphone call (Q2: listen only), and an ended call's refusal.
    private func otherCalls() {
        element(A11yID.Live.row("cmhlive03priya")).tap()
        XCTAssertTrue(element(A11yID.Live.listen).waitForExistence(timeout: 20))
        waitForTranscript()
        XCTAssertTrue(element(A11yID.Live.noReceptionist).exists, "Q2: no note and no take over here")
        capture("14-colleague-call-listen-only")
        element(A11yID.Live.listen).tap()
        XCTAssertTrue(element(A11yID.Live.stop).waitForExistence(timeout: 20))
        sleep(4)
        capture("15-colleague-call-listening")
        element(A11yID.Live.stop).tap()

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(A11yID.Live.row("cmhlive02anon")).waitForExistence(timeout: 20))
        element(A11yID.Live.row("cmhlive02anon")).tap()
        XCTAssertTrue(element(A11yID.Live.listen).waitForExistence(timeout: 20))
        fixture("set?monitor=ended")
        element(A11yID.Live.listen).tap()
        XCTAssertTrue(element(A11yID.Live.problem).waitForExistence(timeout: 20))
        capture("16-listen-refused-call-ended")
    }

    // MARK: - A viewer: listen only

    func test_02_aViewerListensOnly() {
        launch(role: "viewer")
        fixture("set?calls=some")
        refreshList()
        XCTAssertTrue(element(A11yID.Live.row("cmhlive01maya")).waitForExistence(timeout: 20))
        element(A11yID.Live.row("cmhlive01maya")).tap()
        XCTAssertTrue(element(A11yID.Live.listen).waitForExistence(timeout: 20))
        waitForTranscript()
        capture("17-viewer-idle")
        element(A11yID.Live.listen).tap()
        XCTAssertTrue(element(A11yID.Live.stop).waitForExistence(timeout: 20))
        sleep(4)
        capture("18-viewer-listening")
        element(A11yID.Live.stop).tap()
    }

    // MARK: - A call that ended before its screen opened

    /// ⛔ THE SCREEN OPENS ON "The call has ended.", never on Listen (xhigh review, item 3): the
    /// list still showed the call, and its row says it is over.
    func test_03_aCallThatEndedBeforeItsScreenOpened() {
        launch(role: "agency")
        fixture("set?calls=some&stale=cmhlive02anon")
        refreshList()
        XCTAssertTrue(element(A11yID.Live.row("cmhlive02anon")).waitForExistence(timeout: 20))
        element(A11yID.Live.row("cmhlive02anon")).tap()
        XCTAssertTrue(app.staticTexts[language == "en" ? "The call has ended." : "L'appel est terminé."]
            .waitForExistence(timeout: 20))
        XCTAssertFalse(element(A11yID.Live.listen).exists)
        capture("19-opened-after-it-ended")
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// The Overview tab by POSITION, then its Live calls row by identifier. ⚠️ ``ShellNavigator``
    /// taps a tab by its English label, which a French run does not draw.
    private func openLive() {
        let overview = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(overview.waitForExistence(timeout: 30), "the tab bar")
        overview.tap()
        let row = element(A11yID.Overview.row("live"))
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the Live calls row")
        var swipes = 0
        while !row.isHittable, swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        row.tap()
    }

    private func refreshList() {
        let list = app.collectionViews.firstMatch
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
    }

    private func waitForTranscript() {
        let line = app.staticTexts["Good afternoon, Northside Roofing. How can I help?"]
        XCTAssertTrue(line.waitForExistence(timeout: 20), "the fixture's transcript snapshot")
    }

    private func sendNote(_ text: String) {
        let field = element(A11yID.Live.whisperField)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        element(A11yID.Live.whisperSend).tap()
        // ⚠️ THE KEYBOARD OFF THE FRAME: a tap on the title.
        app.navigationBars.firstMatch.tap()
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

    /// A control request to the fixture server.
    private func fixture(_ request: String) {
        guard let url = URL(string: "\(server)/fixture/\(request)") else { return XCTFail("bad fixture URL") }
        let finished = expectation(description: request)
        URLSession.shared.dataTask(with: url) { _, _, _ in finished.fulfill() }.resume()
        wait(for: [finished], timeout: 10)
    }
}
