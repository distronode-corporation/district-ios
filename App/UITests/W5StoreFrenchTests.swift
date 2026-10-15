import XCTest

/// QA only, never merged: the App Store screenshots in Canadian French, the same scenes,
/// order and sizes as the live en-US set (StoreScreenshotTests), over the fictional Québec
/// sample data that `qa/mock_server.py` serves on 127.0.0.1:8765 through the DEBUG session
/// seam. Nothing reaches a real service.
///
/// Frames are attachments named `STORE-<n>-<scene>` (iPhone 6.9-inch, portrait) or
/// `STORE-IPAD-<n>-<scene>` (iPad 13-inch, landscape), each with its accessibility tree.
final class W5StoreFrenchTests: XCTestCase {
    private var app: XCUIApplication!

    private static let session = """
    {"tokenType":"Bearer","accessToken":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\
    eyJzdWIiOiJ1c2VyLWNvbnRyYWN0IiwiZGlkIjoicWEtdzQtZGV2aWNlIiwiZXhwIjo0MTAyNDQ0ODAwfQ.cWEtdzQ",\
    "accessTokenExpiresAt":4102444800000,"refreshToken":"qa-w5-refresh",\
    "refreshTokenExpiresAt":4102444800000,"deviceId":"qa-w5-device"}
    """

    private static let scenes: [(section: ShellSection, name: String)] = [
        (.overview, "1-overview"),
        (.contacts, "2-contacts"),
        (.calls, "3-calls"),
        (.inbox, "4-inbox"),
        (.account, "5-account"),
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
    }

    func test_storeFrench() {
        app = XCUIApplication()
        app.launchArguments = ["-UITestSession", "-AppleLanguages", "(fr-CA)", "-AppleLocale", "fr_CA"]
        app.launchEnvironment["DISTRICT_UITEST_SESSION"] = Self.session
        app.launchEnvironment["DISTRICT_UITEST_BASE_URL"] = "http://127.0.0.1:8765"
        app.launch()
        answerNotificationPrompt()
        let wide = !app.tabBars.firstMatch.waitForExistence(timeout: 5)
        if wide {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let overviewRoot = app.descendants(matching: .any)[A11yID.Overview.root].firstMatch
        XCTAssertTrue(
            ShellNavigator.shellIsUp(in: app, timeout: 30) || overviewRoot.waitForExistence(timeout: 30),
            "the shell never appeared"
        )
        let prefix = wide ? "STORE-IPAD-" : "STORE-"
        for scene in Self.scenes {
            guard go(scene.section, wide: wide) else {
                print("W5-STORE missed \(scene.name)")
                continue
            }
            // ⚠️ AS THE ENGLISH iPAD SET: Contacts and Calls show their first row opened beside
            // the list; Inbox shows its empty detail.
            if wide, let rowBase = openedRow(scene.section) {
                openFirst(prefix: rowBase)
            }
            capture(prefix + scene.name)
        }
        if wide, go(.inbox, wide: true) {
            capture(prefix + "6-sidebar-inbox")
        }
    }

    // MARK: - Navigation

    private func go(_ section: ShellSection, wide: Bool) -> Bool {
        guard wide else {
            guard let symbol = tabSymbol(section) else { return false }
            let predicate = NSPredicate(format: "identifier == %@ OR identifier == %@", symbol, symbol + ".fill")
            let image = app.tabBars.images.matching(predicate).firstMatch
            guard image.waitForExistence(timeout: 5) else { return false }
            image.tap()
            return true
        }
        let row = app.cells.containing(.any, identifier: section.sidebarID).firstMatch
        let anyRow = NSPredicate(format: "identifier BEGINSWITH %@", ShellNavigator.sidebarPrefix)
        var sidebar = app.collectionViews.containing(anyRow).firstMatch
        if !sidebar.waitForExistence(timeout: 3) {
            showSidebar()
            sidebar = app.collectionViews.containing(anyRow).firstMatch
            guard sidebar.waitForExistence(timeout: 3) else { return false }
        }
        var swipes = 0
        while !(row.exists && row.isHittable), swipes < 5 {
            sidebar.swipeDown()
            swipes += 1
        }
        guard row.exists else { return false }
        row.isHittable ? row.tap() : row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        // ⚠️ THE SIDEBAR STAYS OPEN, as in every frame of the English iPad set.
        showSidebar()
        return true
    }

    private func openedRow(_ section: ShellSection) -> String? {
        switch section {
        case .contacts: A11yID.Contacts.rowBase
        case .calls: A11yID.Calls.rowBase
        default: nil
        }
    }

    private func openFirst(prefix: String) {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix + "-")).firstMatch
        guard row.waitForExistence(timeout: 8), row.isHittable else { return }
        row.tap()
    }

    private func tabSymbol(_ section: ShellSection) -> String? {
        switch section {
        case .overview: "square.grid.2x2"
        case .inbox: "tray"
        case .calls: "phone"
        case .contacts: "person.2"
        case .account: "person.crop.circle"
        default: nil
        }
    }

    private func showSidebar() {
        let anyRow = NSPredicate(format: "identifier BEGINSWITH %@", ShellNavigator.sidebarPrefix)
        guard !app.collectionViews.containing(anyRow).firstMatch.exists else { return }
        let toggle = app.navigationBars.buttons.element(boundBy: 0)
        if toggle.exists { toggle.tap() }
    }

    // MARK: - System chrome

    /// The notification prompt belongs to SpringBoard and hides the app until answered.
    /// ⚠️ ALLOWED, so the Account frame shows notifications turned on, as a customer's does.
    private func answerNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 8) else { return }
            let allow = alert.buttons.element(boundBy: 1)
            if allow.exists { allow.tap() }
        }
    }

    /// A system banner (Apple Intelligence, a notification) over the app is swiped away and
    /// waited out before a frame is taken.
    private func clearBanners() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 4 {
            let banner = springboard.otherElements["NotificationShortLookView"].firstMatch
            guard banner.exists else { return }
            banner.swipeUp()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Capture

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 3)
        clearBanners()
        let frame = app.windows.firstMatch.screenshot()
        let shot = XCTAttachment(screenshot: frame)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + ".txt"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
