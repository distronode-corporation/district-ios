import XCTest

/// Visual and style QA only, never merged: every main screen over the contract fixtures
/// (and, in French, the fictional Québec sample data), captured as attachments named
/// `<tag>__<NN>-<screen>` with the accessibility tree beside each frame. One test method per
/// configuration, so the tag can never name the wrong one; the workflow sets the simulator's
/// appearance before running the methods for it.
///
/// Adapted from the W4 French tour (`w4/french-qa-shots`). Additions: a relaunch and one
/// retry when a section cannot be reached (the iPad walk used to stop at the first lost
/// sidebar), a portrait pass on iPad, the largest accessibility text size, and the empty,
/// error and loading states, which the mock produces (`QA_MODE` in qa/mock_server.py).
///
/// The app talks to `qa/mock_server.py` on 127.0.0.1:8765 through the DEBUG session seam
/// with a made-up session; nothing reaches a real service.
final class VisualQATourTests: XCTestCase {
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    private static let session = """
    {"tokenType":"Bearer","accessToken":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\
    eyJzdWIiOiJ1c2VyLWNvbnRyYWN0IiwiZGlkIjoicWEtdzQtZGV2aWNlIiwiZXhwIjo0MTAyNDQ0ODAwfQ.cWEtdzQ",\
    "accessTokenExpiresAt":4102444800000,"refreshToken":"qa-w4-refresh",\
    "refreshTokenExpiresAt":4102444800000,"deviceId":"qa-w4-device"}
    """

    private var app: XCUIApplication!
    private var tag = "en-US-light"
    private var language = "en-US"
    private var locale = "en_US"
    private var style = "Light"
    private var extra: [String] = []
    private var landscape = true
    private var reached: [String] = []
    private var missed: [String] = []

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

    // MARK: - Configurations

    func test_1_enUS_light() {
        full(language: "en-US", locale: "en_US", style: "Light", tag: "en-US-light")
    }

    func test_2_frCA_light() {
        full(language: "fr-CA", locale: "fr_CA", style: "Light", tag: "fr-CA-light")
    }

    func test_3_enUS_dark() {
        full(language: "en-US", locale: "en_US", style: "Dark", tag: "en-US-dark")
    }

    func test_4_frCA_dark() {
        full(language: "fr-CA", locale: "fr_CA", style: "Dark", tag: "fr-CA-dark")
    }

    func test_5_enUS_ax5() {
        full(language: "en-US", locale: "en_US", style: "Light", tag: "en-US-light-ax5",
             extra: ["-UIPreferredContentSizeCategoryName", Self.ax5])
    }

    func test_6_frCA_ax5() {
        full(language: "fr-CA", locale: "fr_CA", style: "Light", tag: "fr-CA-light-ax5",
             extra: ["-UIPreferredContentSizeCategoryName", Self.ax5])
    }

    /// The mock answers every list empty (QA_MODE=empty).
    func test_7_enUS_empty() {
        states(tag: "en-US-light-empty")
    }

    /// The mock answers every data route with a 500 (QA_MODE=error).
    func test_8_enUS_error() {
        states(tag: "en-US-light-error")
    }

    /// The mock holds every data route for 25 s (QA_MODE=slow), so each frame is the
    /// section's loading state.
    func test_9_enUS_loading() {
        states(tag: "en-US-light-loading", settle: 1.0)
    }

    func test_10_frCA_empty() {
        states(tag: "fr-CA-light-empty", language: "fr-CA", locale: "fr_CA")
    }

    // MARK: - The walks

    private func configure(language: String, locale: String, style: String, tag: String, extra: [String]) {
        self.language = language
        self.locale = locale
        self.style = style
        self.extra = extra
        self.tag = tag
    }

    private func full(language: String, locale: String, style: String, tag: String, extra: [String] = []) {
        configure(language: language, locale: locale, style: style, tag: tag, extra: extra)
        guard start() else { return }
        walk()
        if !isCompact() {
            portraitPass()
        }
        report()
    }

    private var settleTime: TimeInterval = 2.5

    private func states(tag: String, language: String = "en-US", locale: String = "en_US", settle: TimeInterval = 2.5) {
        configure(language: language, locale: locale, style: "Light", tag: tag, extra: [])
        settleTime = settle
        guard start() else { return }
        capture("01-overview")
        for (section, name) in mainSections {
            guard go(section) else { continue }
            capture(name)
        }
        report()
    }

    private let mainSections: [(ShellSection, String)] = [
        (.inbox, "02-inbox"), (.calls, "06-calls"), (.contacts, "10-contacts"), (.account, "12-account"),
        (.hq, "14-hq"), (.analytics, "15-analytics"), (.marketplace, "16-numbers"), (.billing, "18-billing"),
        (.rooms, "19-rooms"), (.workflows, "20-workflows"), (.desk, "21-desk"), (.scheduling, "25-scheduling"),
        (.support, "40-support"), (.settings, "42-settings"),
    ]

    private func walk() {
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
            if openFirstCell(containing: ["Outbound calls failing", "Appels sortants"]) {
                capture("41-support-thread")
                back()
            }
        }
        settings()
    }

    private func desk() {
        guard go(.desk) else { return }
        capture("21-desk")
        if openFirstCell(containing: ["Reschedule Thursday", "jeudi"]) {
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
            if index > 0, !onSchedulingHub() {
                guard go(.scheduling) else { return }
            }
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

    private func onSchedulingHub() -> Bool {
        app.descendants(matching: .any)[A11yID.Scheduling.section("overview")].firstMatch.exists
    }

    private func tabs(prefix: String, number: Int) {
        let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix + "-"))
        let count = min(query.count, 6)
        guard count > 1 else { return }
        for index in 1 ..< count {
            let tab = query.element(boundBy: index)
            guard tab.exists, tab.isHittable else { continue }
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
            if !row.exists {
                guard go(.settings) else { return }
            }
            bringIntoView(row)
            guard row.exists, row.isHittable else {
                missed.append("settings-\(raw)")
                continue
            }
            row.tap()
            capture("\(43 + index)-settings-\(raw)")
            scrollCapture("\(43 + index)b-settings-\(raw)")
            back()
        }
    }

    /// iPad only: the main sections again with the device upright, where the split view
    /// has less width and the sidebar becomes an overlay.
    private func portraitPass() {
        landscape = false
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        capture("p01-overview")
        if go(.inbox) {
            capture("p02-inbox")
            if openFirst(prefix: A11yID.Inbox.rowBase) {
                capture("p03-thread")
                back()
            }
        }
        if go(.calls) {
            capture("p06-calls")
            if openFirst(prefix: A11yID.Calls.rowBase) {
                capture("p07-call-detail")
                back()
            }
        }
        if go(.contacts) {
            capture("p10-contacts")
            if openFirst(prefix: A11yID.Contacts.rowBase) {
                capture("p11-contact")
                back()
            }
        }
        if go(.account) { capture("p12-account") }
        if go(.analytics) { capture("p15-analytics") }
        if go(.marketplace) { capture("p16-numbers") }
        if go(.billing) { capture("p18-billing") }
        if go(.desk) { capture("p21-desk") }
        if go(.dialer) { capture("p24-dialer") }
        if go(.scheduling) { capture("p25-scheduling") }
        if go(.settings) { capture("p42-settings") }
        landscape = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    // MARK: - Launching

    @discardableResult
    private func start() -> Bool {
        app = XCUIApplication()
        app.launchArguments = [
            "-UITestSession",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "-UIUserInterfaceStyle", style,
        ] + extra
        app.launchEnvironment["DISTRICT_UITEST_SESSION"] = Self.session
        app.launchEnvironment["DISTRICT_UITEST_BASE_URL"] = "http://127.0.0.1:8765"
        app.launch()
        dismissSystemAlert()
        if !isCompact() {
            XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
            Thread.sleep(forTimeInterval: 1)
        }
        // ⚠️ In French the split view's "Show Sidebar" button has a French label, so a
        // hidden sidebar is recognised by the Overview's own identifier instead.
        let overviewRoot = app.descendants(matching: .any)[A11yID.Overview.root].firstMatch
        let shellUp = ShellNavigator.shellIsUp(in: app, timeout: 30) || overviewRoot.waitForExistence(timeout: 30)
        guard shellUp else {
            capture("00-no-shell")
            missed.append("shell")
            return false
        }
        if !isCompact(), landscape,
           !app.cells.containing(.any, identifier: A11yID.Sidebar.overview).firstMatch.exists {
            let toggle = app.navigationBars.buttons.element(boundBy: 0)
            if toggle.exists, toggle.isHittable { toggle.tap() }
        }
        return true
    }

    private func relaunch() -> Bool {
        app.terminate()
        return start()
    }

    /// The notification permission prompt sits over the app and hides its tree until it is
    /// answered; it belongs to SpringBoard, so it is answered there.
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 3 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 6) else { return }
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
        guard image.waitForExistence(timeout: 5), image.isHittable else { return false }
        image.tap()
        return true
    }

    /// A section, and if it cannot be reached, a fresh launch and one more try: one lost
    /// sheet or sidebar must not end the walk.
    @discardableResult
    private func go(_ section: ShellSection) -> Bool {
        if attempt(section) { return true }
        guard relaunch(), attempt(section) else {
            missed.append("\(section)")
            return false
        }
        return true
    }

    private func attempt(_ section: ShellSection) -> Bool {
        isCompact() ? goCompact(section) : goRegular(section)
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
        guard row.exists, row.isHittable else { return false }
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
            if toggle.exists, toggle.isHittable { toggle.tap() }
            sidebar = app.collectionViews.containing(anyRow).firstMatch
            guard sidebar.waitForExistence(timeout: 3) else { return false }
        }
        // ⚠️ EVERY SWIPE CHECKS THE LIST IS STILL THERE: swiping a list that has gone (a
        // sheet came up over it) fails the test outright, which is how the W4 iPad walk
        // stopped at the dialer.
        var swipes = 0
        while !(row.exists && row.isHittable), swipes < 5 {
            guard sidebar.exists, sidebar.isHittable else { return false }
            sidebar.swipeDown()
            swipes += 1
        }
        swipes = 0
        while !(row.exists && row.isHittable), swipes < 8 {
            guard sidebar.exists, sidebar.isHittable else { return false }
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
        Thread.sleep(forTimeInterval: 0.5)
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
        guard row.exists, row.isHittable else {
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
        guard first.exists, first.isHittable else {
            missed.append(prefix + " (not hittable)")
            return false
        }
        first.tap()
        return true
    }

    private func openFirstCell(containing texts: [String]) -> Bool {
        for text in texts {
            let predicate = NSPredicate(format: "label CONTAINS %@", text)
            let target = app.staticTexts.matching(predicate).firstMatch
            guard target.waitForExistence(timeout: 4) else { continue }
            bringIntoView(target)
            guard target.exists, target.isHittable else { continue }
            target.tap()
            return true
        }
        missed.append("cell:\(texts.joined(separator: "/"))")
        return false
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
        guard target.exists, target.isHittable else {
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
        if region.exists, region.isHittable {
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
        while !(element.exists && element.isHittable), swipes < 7 {
            app.swipeUp()
            swipes += 1
        }
    }

    // MARK: - Capture

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: settleTime)
        reached.append(name)
        let window = app.windows.firstMatch
        let frame = window.exists ? window.screenshot() : app.screenshot()
        let shot = XCTAttachment(screenshot: frame)
        shot.name = "\(tag)__\(name)"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(tag)__\(name).txt"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func scrollCapture(_ name: String) {
        app.swipeUp()
        capture(name)
    }

    private func report() {
        print("VQA-TOUR[\(tag)] reached \(reached.count): \(reached.joined(separator: " | "))")
        print("VQA-TOUR[\(tag)] missed: \(missed.joined(separator: " | "))")
    }
}
