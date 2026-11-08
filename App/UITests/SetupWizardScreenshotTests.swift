import Foundation
import XCTest

/// Walks the setup wizard step by step against the LOOPBACK fixture server and asks the host
/// to capture each state with `simctl io screenshot`.
///
/// ⛔ NEVER AGAINST A REAL ACCOUNT. It renames a workspace, rewrites its receptionist and
/// business facts and places a test call and a forwarding check, so it SKIPS unless the base
/// URL it is given is `http://127.0.0.1`, where the fixture server answers from
/// district-core-swift 8.5.0's vendored `district-setup*`, persona and forwarding fixtures and
/// changes nothing anywhere.
///
/// ⚠️ THE HOST TAKES THE FRAMES, NOT THIS RUNNER, as in ``TwoStepScreenshotTests``: for each
/// state it writes `want-<name>` into `DISTRICT_SHOTS_DIR` and waits for `done-<name>`. Every
/// variable arrives as `TEST_RUNNER_<name>`.
///
/// ⚠️ NOT IN CI: it needs the fixture server, the loop and a session, and skips without them.
final class SetupWizardScreenshotTests: XCTestCase {
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
        control("reset")
        launch()
        let card = element(A11yID.Overview.finishSetup)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the owner mid-setup is offered the card")
        capture("00-overview-card")

        card.tap()
        XCTAssertTrue(element(A11yID.Setup.step("business")).waitForExistence(timeout: 20), "step 1, all todo")
        capture("01-business")

        type("example.com\n", into: A11yID.Setup.Business.website)
        tapScrolling(A11yID.Setup.Business.readWebsite)
        XCTAssertTrue(element(A11yID.Setup.Business.notice).waitForExistence(timeout: 15), "the drafts were found")
        capture("02-business-read")

        tapScrolling(A11yID.Setup.Business.save)
        XCTAssertTrue(element(A11yID.Setup.step("number")).waitForExistence(timeout: 15))
        capture("03-number")

        element(A11yID.Setup.Number.keep).tap()
        XCTAssertTrue(element(A11yID.Setup.Receptionist.save).waitForExistence(timeout: 15))
        capture("04-receptionist")

        tapScrolling(A11yID.Setup.Receptionist.save)
        XCTAssertTrue(element(A11yID.Setup.step("callers")).waitForExistence(timeout: 15))
        capture("05-callers")
        scrollTo(A11yID.Setup.Callers.addService)
        capture("06-callers-drafts")

        tapScrolling(A11yID.Setup.Callers.saveAndContinue)
        XCTAssertTrue(element(A11yID.Setup.Calls.saveAndContinue).waitForExistence(timeout: 15))
        capture("07-calls")
        scrollTo(A11yID.Setup.Calls.openIntegrations)
        capture("08-calls-handoffs")

        tapScrolling(A11yID.Setup.Calls.saveAndContinue)
        XCTAssertTrue(element(A11yID.Setup.GoLive.mobile).waitForExistence(timeout: 15))
        capture("09-golive")

        type("4165550123", into: A11yID.Setup.GoLive.mobile)
        tapScrolling(A11yID.Setup.GoLive.callMe)
        XCTAssertTrue(element(A11yID.Setup.GoLive.callStatus).waitForExistence(timeout: 15), "calling")
        capture("10-golive-calling")

        type("4165550199", into: A11yID.Setup.GoLive.businessLine)
        tapScrolling(A11yID.Setup.GoLive.startCheck)
        let passed = element(A11yID.Setup.GoLive.checkStatus)
        XCTAssertTrue(passed.waitForExistence(timeout: 15))
        sleep(5)
        scrollTo(A11yID.Setup.GoLive.finish)
        capture("11-golive-forwarding")

        tapScrolling(A11yID.Setup.GoLive.finish)
        XCTAssertTrue(element(A11yID.Setup.finished).waitForExistence(timeout: 15), "every step done")
        capture("12-finished")
    }

    /// ⚠️ OWNERSHIP CHANGING UNDER AN OPEN CARD is the one way to reach the refusal from the UI:
    /// the card itself is only offered to the owner. The fixture answers the card's read and
    /// then refuses the wizard's.
    func test_02_notTheOwner() {
        control("reset")
        launch()
        let card = element(A11yID.Overview.finishSetup)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        control("not-owner")
        card.tap()
        XCTAssertTrue(element(A11yID.Setup.refused).waitForExistence(timeout: 20), "a clear explanation, no error")
        capture("13-not-owner")
        control("reset")
    }

    // MARK: - Helpers

    private func control(_ name: String) {
        guard let url = URL(string: server + "/__fixture/" + name) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let done = expectation(description: name)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
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
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(
            element(A11yID.Overview.root).waitForExistence(timeout: 30),
            "the fixture session must reach the shell"
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// ⚠️ THE WIZARD IS A SHEET: swipe ITS scroll view, never the screen, which would dismiss it.
    private func scrollTo(_ identifier: String) {
        let target = element(identifier)
        let scroll = app.scrollViews.containing(.any, identifier: A11yID.Setup.root).firstMatch
        var swipes = 0
        while !(target.exists && target.isHittable), swipes < 12 {
            (scroll.exists ? scroll : app.scrollViews.firstMatch).swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    private func tapScrolling(_ identifier: String) {
        scrollTo(identifier)
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), identifier)
        target.tap()
    }

    private func type(_ text: String, into identifier: String) {
        scrollTo(identifier)
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), identifier)
        field.tap()
        field.typeText(text)
        // ⚠️ THE KEYBOARD COVERS THE BUTTONS BELOW: put it away.
        if app.keyboards.firstMatch.exists {
            app.navigationBars.firstMatch.tap()
        }
    }

    /// Ask the host for a frame of the screen as it is now, and wait until it has one.
    private func capture(_ name: String) {
        guard let shots else { return }
        // ⚠️ THE CARET BLINKS: a beat so the frame is not taken mid-animation.
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
