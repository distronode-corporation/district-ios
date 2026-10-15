import XCTest

/// W4 French QA only, never merged: every main screen over the contract fixtures, in one
/// language per test, captured as attachments named `<lang>/<NN>-<screen>` with the
/// accessibility tree beside each frame (`<lang>/<NN>-<screen>.txt`).
///
/// The app talks to `qa/mock_server.py` on 127.0.0.1:8765 through the DEBUG session seam
/// with a made-up session; nothing reaches a real service. Navigation is by identifier, or
/// by position for the tab bar, so the same walk works in every language.
final class W4FrenchTourTests: XCTestCase {
    private var app: XCUIApplication!
    private var tag = "en-US"
    private var step = 0
    private var reached: [String] = []
    private var missed: [String] = []

    private static let session = """
    {"tokenType":"Bearer","accessToken":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\
    eyJzdWIiOiJ1c2VyLWNvbnRyYWN0IiwiZGlkIjoicWEtdzQtZGV2aWNlIiwiZXhwIjo0MTAyNDQ0ODAwfQ.cWEtdzQ",\
    "accessTokenExpiresAt":4102444800000,"refreshToken":"qa-w4-refresh",\
    "refreshTokenExpiresAt":4102444800000,"deviceId":"qa-w4-device"}
    """

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Don\u{2019}t Allow", "Don't Allow", "Ne pas autoriser", "Refuser", "OK"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    func test_1_enUS() {
        tour(language: "en-US", locale: "en_US")
    }

    func test_2_frCA() {
        tour(language: "fr-CA", locale: "fr_CA")
    }

    func test_3_frFR() {
        tour(language: "fr-FR", locale: "fr_FR")
    }

    // MARK: - The walk

    private func tour(language: String, locale: String) {
        tag = ProcessInfo.processInfo.environment["W4_TAG"].map { "\($0)-\(language)" } ?? language
        app = XCUIApplication()
        app.launchArguments = [
            "-UITestSession",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        app.launchEnvironment["DISTRICT_UITEST_SESSION"] = Self.session
        app.launchEnvironment["DISTRICT_UITEST_BASE_URL"] = "http://127.0.0.1:8765"
        app.launch()
        dismissSystemAlert()
        if !isCompact() {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        // ⚠️ In French the split view's "Show Sidebar" button has a French label, so a
        // hidden sidebar is recognised by the Overview's own identifier instead.
        let overviewRoot = app.descendants(matching: .any)[A11yID.Overview.root].firstMatch
        let shellUp = ShellNavigator.shellIsUp(in: app, timeout: 30) || overviewRoot.waitForExistence(timeout: 30)
        if !isCompact(), !app.cells.containing(.any, identifier: A11yID.Sidebar.overview).firstMatch.exists {
            let toggle = app.navigationBars.buttons.element(boundBy: 0)
            if toggle.exists { toggle.tap() }
        }
        guard shellUp else {
            capture("00-no-shell")
            XCTFail("the shell never appeared")
            return
        }
        capture("01-overview")
        scrollCapture("01b-overview")

        if go(.inbox) {
            capture("02-inbox")
            if openFirst(prefix: A11yID.Inbox.rowBase) {
                capture("03-thread")
                if tapID(A11yID.Inbox.threadMenu) {
                    capture("04-thread-menu")
                    if tapID(A11yID.Inbox.threadReport) {
                        capture("05-report")
                        _ = tapID(A11yID.Report.cancel)
                    } else {
                        dismissMenu()
                    }
                }
                composeProbe()
                back()
            }
        }

        if go(.calls) {
            capture("06-calls")
            if openFirst(prefix: A11yID.Calls.rowBase) {
                capture("07-call-detail")
                scrollCapture("07b-call-detail")
                if tapID(A11yID.Calls.showTranscript) {
                    capture("08-call-transcript")
                }
                if tapID(A11yID.Calls.detailMenu) {
                    capture("09-call-menu")
                    dismissMenu()
                }
                back()
            }
        }

        if go(.contacts) {
            capture("10-contacts")
            if openFirst(prefix: A11yID.Contacts.rowBase) {
                capture("11-contact")
                scrollCapture("11b-contact")
                back()
            }
        }

        if go(.account) {
            capture("12-account")
            scrollCapture("12b-account")
            if tapID(A11yID.Account.devices) {
                capture("13-devices")
                back()
            }
        }

        hubs()
        print("W4-TOUR[\(tag)] reached: \(reached.joined(separator: " | "))")
        print("W4-TOUR[\(tag)] missed: \(missed.joined(separator: " | "))")
    }

    private func hubs() {
        if go(.hq) { capture("14-hq") }
        if go(.analytics) {
            capture("15-analytics")
            scrollCapture("15b-analytics")
            scrollCapture("15c-analytics")
        }
        if go(.marketplace) {
            capture("16-numbers")
            scrollCapture("16b-numbers")
            scrollCapture("16c-numbers")
            if openFirst(prefix: A11yID.Marketplace.rowBase) {
                capture("17-number-actions")
                dismissSheet()
            }
        }
        if go(.billing) {
            capture("18-billing")
            scrollCapture("18b-billing")
        }
        if go(.rooms) { capture("19-rooms") }
        if go(.workflows) {
            capture("20-workflows")
            scrollCapture("20b-workflows")
        }
        desk()
        if go(.dialer) { capture("24-dialer") }
        scheduling()
        if go(.support) {
            capture("40-support")
            if openFirstCell(containing: "Outbound calls failing") {
                capture("41-support-thread")
                back()
            }
        }
        settings()
    }

    private func desk() {
        guard go(.desk) else { return }
        capture("21-desk")
        if openFirstCell(containing: "Reschedule Thursday") {
            capture("22-ticket")
            back()
        }
        if tapID(A11yID.Desk.newTicket) {
            capture("23-new-ticket")
            if !tapID(A11yID.Desk.composeCancel) { dismissSheet() }
        }
    }

    private func scheduling() {
        guard go(.scheduling) else { return }
        capture("25-scheduling")
        scrollCapture("25b-scheduling")
        let sections = ["overview", "event-types", "hours", "bookings", "calendar", "team", "settings", "developer"]
        for (index, segment) in sections.enumerated() {
            let number = 26 + index
            guard openSection(segment) else { continue }
            capture("\(number)-sched-\(segment)")
            scrollCapture("\(number)b-sched-\(segment)")
            switch segment {
            case "event-types":
                if openFirst(prefix: A11yID.Scheduling.eventTypeRowBase) {
                    capture("\(number)c-sched-event-type")
                    scrollCapture("\(number)d-sched-event-type")
                    back()
                }
            case "bookings":
                if openFirst(prefix: A11yID.Scheduling.bookingRowBase) {
                    capture("\(number)c-sched-booking")
                    back()
                }
            case "team":
                if tapFirst(id: A11yID.SchedulingWriteEntry.userArchive) {
                    capture("\(number)c-sched-archive")
                    dismissSheet()
                }
            case "settings":
                tabs(prefix: A11yID.Scheduling.settingsTabBase, number: number)
            case "developer":
                tabs(prefix: A11yID.Scheduling.developerTabBase, number: number)
            default:
                break
            }
            back()
        }
    }

    private func tabs(prefix: String, number: Int) {
        let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix + "-"))
        let count = min(query.count, 6)
        guard count > 1 else { return }
        for index in 1 ..< count {
            let tab = query.element(boundBy: index)
            guard tab.exists else { continue }
            tab.tap()
            capture("\(number)t\(index)-tab")
        }
    }

    private func settings() {
        guard go(.settings) else { return }
        capture("42-settings")
        scrollCapture("42b-settings")
        let sections = ["persona", "voiceStudio", "capabilities", "calls", "directory", "routing",
                        "knowledge", "messaging", "members", "scheduling"]
        for (index, raw) in sections.enumerated() {
            let row = app.descendants(matching: .any)[A11yID.Settings.row(raw)].firstMatch
            bringIntoView(row)
            guard row.exists else {
                missed.append("settings-\(raw)")
                continue
            }
            row.tap()
            capture("\(43 + index)-settings-\(raw)")
            scrollCapture("\(43 + index)b-settings-\(raw)")
            back()
        }
    }

    /// The notification permission prompt sits over the app and hides its tree until it is
    /// answered; it belongs to SpringBoard, so it is answered there.
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 8) else { return }
            let refuse = alert.buttons.element(boundBy: 0)
            if refuse.exists { refuse.tap() }
        }
    }

    // MARK: - Navigation

    private func isCompact() -> Bool {
        app.tabBars.firstMatch.waitForExistence(timeout: 3)
    }

    /// The tab's symbol: a tab bar button carries no identifier and its label is the
    /// language's, but its image is named after the SF Symbol in every language.
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

    private func tapTab(_ symbol: String) -> Bool {
        let predicate = NSPredicate(format: "identifier == %@ OR identifier == %@", symbol, symbol + ".fill")
        let image = app.tabBars.images.matching(predicate).firstMatch
        guard image.waitForExistence(timeout: 5) else { return false }
        image.tap()
        return true
    }

    @discardableResult
    private func go(_ section: ShellSection) -> Bool {
        let ok = isCompact() ? goCompact(section) : goRegular(section)
        if !ok {
            missed.append("\(section)")
        }
        return ok
    }

    private func goCompact(_ section: ShellSection) -> Bool {
        if let symbol = tabSymbol(section) {
            guard tapTab(symbol) else { return false }
            popToRoot()
            return true
        }
        guard tapTab("square.grid.2x2") else { return false }
        popToRoot()
        guard let id = section.overviewRowID else { return false }
        let row = app.buttons[id].firstMatch
        bringIntoView(row)
        guard row.exists else { return false }
        row.tap()
        return true
    }

    private func goRegular(_ section: ShellSection) -> Bool {
        let row = app.cells.containing(.any, identifier: section.sidebarID).firstMatch
        // ⚠️ THE SIDEBAR'S OWN LIST, found by any row it holds: its cells are created only
        // around what is on screen, so a row scrolled away does not exist until the list
        // moves, and the first collection view can be the content's.
        let anyRow = NSPredicate(format: "identifier BEGINSWITH %@", ShellNavigator.sidebarPrefix)
        var sidebar = app.collectionViews.containing(anyRow).firstMatch
        if !sidebar.waitForExistence(timeout: 3) {
            // The sidebar is hidden: its toggle is the navigation bar's first button.
            let toggle = app.navigationBars.buttons.element(boundBy: 0)
            if toggle.exists { toggle.tap() }
            sidebar = app.collectionViews.containing(anyRow).firstMatch
            guard sidebar.waitForExistence(timeout: 3) else { return false }
        }
        var swipes = 0
        while !(row.exists && row.isHittable), swipes < 5 {
            sidebar.swipeDown()
            swipes += 1
        }
        swipes = 0
        while !(row.exists && row.isHittable), swipes < 8 {
            sidebar.swipeUp()
            swipes += 1
        }
        guard row.exists else { return false }
        if row.isHittable {
            row.tap()
        } else {
            // A row under the home indicator is on screen but reported not hittable.
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        return true
    }

    private func popToRoot() {
        var presses = 0
        while presses < 5, let button = backButton() {
            button.tap()
            presses += 1
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    /// The front column's back button, or nil at a root. On a wide screen the front column
    /// is the rightmost navigation bar; a back button sits at its leading edge and carries
    /// the system's identifier or none, while the app's own toolbar items carry theirs.
    private func backButton() -> XCUIElement? {
        let bars = app.navigationBars.allElementsBoundByIndex.filter { $0.exists && $0.frame.width > 0 }
        guard let bar = bars.max(by: { $0.frame.minX < $1.frame.minX }) else { return nil }
        let button = bar.buttons.element(boundBy: 0)
        guard button.exists, button.isHittable else { return nil }
        let leading = button.frame.minX < bar.frame.minX + 60
        let system = button.identifier == "BackButton" || button.identifier.isEmpty
        return leading && system ? button : nil
    }

    private func back() {
        if let button = backButton() {
            button.tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    private func openSection(_ segment: String) -> Bool {
        let row = app.descendants(matching: .any)[A11yID.Scheduling.section(segment)].firstMatch
        bringIntoView(row)
        guard row.exists else {
            missed.append("sched-\(segment)")
            return false
        }
        row.tap()
        return true
    }

    private func openFirst(prefix: String) -> Bool {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix + "-"))
        let first = query.firstMatch
        guard first.waitForExistence(timeout: 8) else {
            missed.append(prefix)
            return false
        }
        bringIntoView(first)
        first.tap()
        return true
    }

    private func openFirstCell(containing text: String) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let target = app.staticTexts.matching(predicate).firstMatch
        guard target.waitForExistence(timeout: 8) else {
            missed.append("cell:\(text)")
            return false
        }
        bringIntoView(target)
        target.tap()
        return true
    }

    private func tapID(_ id: String) -> Bool {
        tapFirst(id: id)
    }

    private func tapFirst(id: String) -> Bool {
        let target = app.descendants(matching: .any)[id].firstMatch
        guard target.waitForExistence(timeout: 5) else {
            missed.append(id)
            return false
        }
        bringIntoView(target)
        guard target.isHittable else {
            missed.append(id + " (not hittable)")
            return false
        }
        target.tap()
        return true
    }

    private func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func dismissSheet() {
        // ⚠️ ON A WIDE SCREEN A SHEET CAN BE A POPOVER, closed by its dismiss region.
        let region = app.descendants(matching: .any)["PopoverDismissRegion"].firstMatch
        if region.exists {
            region.tap()
            Thread.sleep(forTimeInterval: 0.8)
            return
        }
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 0.8)
        if app.sheets.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        }
    }

    private func composeProbe() {
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        guard field.exists, field.isHittable else { return }
        field.tap()
        capture("03b-thread-compose")
        app.swipeDown()
    }

    private func bringIntoView(_ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
    }

    // MARK: - Capture

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 2.5)
        step += 1
        reached.append(name)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "\(tag)/\(name)"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(tag)/\(name).txt"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func scrollCapture(_ name: String) {
        app.swipeUp()
        capture(name)
    }
}
