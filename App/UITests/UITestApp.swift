import XCTest

/// The base every UI-test case inherits.
///
/// ⛔ THE APP IS LAUNCHED ONCE PER RUN, NOT ONCE PER TEST, AND THAT IS A CONSTRAINT
/// OF THE SESSION RATHER THAN AN OPTIMISATION. The injected refresh token is
/// single-use: a second `launch()` re-adopts the same pair, the server treats the
/// replay as theft, and it revokes the whole family — so a per-test launch would
/// destroy the session partway through its own run. Later cases `activate()` and
/// navigate back to a root instead.
///
/// ⚠️ THE SESSION IS COPIED FROM THE RUNNER'S OWN ENVIRONMENT, never written here.
/// `xcodebuild` passes it as `TEST_RUNNER_DISTRICT_UITEST_SESSION`, which arrives in
/// the runner process with the prefix stripped. It is read from a file on disk by
/// the run script and never appears in argv or in a message.
class UITestApp: XCTestCase {
    /// ⚠️ `static` SO IT SURVIVES BETWEEN CASES. XCTest builds a fresh instance per
    /// test method; an instance property would relaunch, which the ⛔ above forbids.
    static let app = XCUIApplication()
    private static var launched = false
    private static var signedIn: Bool?

    var app: XCUIApplication {
        Self.app
    }

    /// The orientation every case in this run starts in: landscape when the runner's
    /// environment carries `DISTRICT_UITEST_ORIENTATION=landscape` (exported as
    /// `TEST_RUNNER_DISTRICT_UITEST_ORIENTATION`), portrait otherwise.
    ///
    /// ⚠️ SO ONE SET OF CASES COVERS BOTH ORIENTATIONS OF AN iPAD, run twice, rather than a copy
    /// of each case per orientation. On a phone the app is portrait-only and asking for
    /// landscape changes nothing, which ``ensureOrientation(_:timeout:)`` accepts.
    static var runOrientation: UIDeviceOrientation {
        ProcessInfo.processInfo.environment["DISTRICT_UITEST_ORIENTATION"] == "landscape" ? .landscapeLeft : .portrait
    }

    /// ⛔ SURFACES A TEST MUST NEVER TAP, AND THE LIST IS ENFORCED RATHER THAN
    /// DOCUMENTED. The simulator and the test device may be signed into a LIVE
    /// production workspace, so a stray tap is a real message sent, a real number
    /// released, or a real account deleted. ``tap(_:)`` refuses them.
    ///
    /// ⚠️ `Dialer.call` IS HERE EVEN THOUGH THE EMERGENCY CASES LEAVE IT DISABLED:
    /// the point is that no future case may tap it, not that today's cannot.
    static let forbiddenSurfaces: Set<String> = [
        A11yID.Contacts.add,
        A11yID.Account.signOut,
        A11yID.Account.delete,
        A11yID.Marketplace.release,
        A11yID.Inbox.send,
        A11yID.Dialer.call,
        // ⛔ Moves the engine every call on the workspace runs on.
        A11yID.VoiceStudio.save,
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // ⛔ THE ARGUMENT IS SET ON EVERY INSTANCE, ABOVE THE ONE-LAUNCH GUARD.
        // `activate()` RELAUNCHES an app the system has since terminated, and it
        // relaunches it with THIS instance's `launchArguments` — which, for every
        // class after the first, would otherwise be empty. An unarmed launch takes
        // the Keychain store, whose read THROWS on an unsigned simulator build, so
        // the app renders the `unavailable` branch ("We could not read your saved
        // session"), which is the one screen that deliberately offers no Sign in
        // with Apple button. The symptom is
        // `test_IOS_AUTH_04_signInWithAppleIsOffered` failing in the full suite and
        // passing when its class runs alone.
        app.launchArguments = [UITestLaunch.argument]
        // ⚠️ ORIENTATION AFTER THE LAUNCH OR ACTIVATE: the helper reads a window only a running app has.
        guard !Self.launched else {
            app.activate()
            ensureOrientation(Self.runOrientation)
            return
        }
        Self.launched = true
        // ⛔ THE SESSION STAYS BELOW THE GUARD, AND THAT ASYMMETRY IS THE POINT.
        // Refresh rotation is single-use: re-injecting the same pair on a relaunch
        // is read as theft server-side and revokes the whole family. An armed
        // relaunch WITHOUT a session is simply a signed-out app, which is correct,
        // harmless, and exactly what the unauthenticated lane wants to see.
        if let session = ProcessInfo.processInfo.environment[UITestLaunch.sessionVariable] {
            app.launchEnvironment[UITestLaunch.sessionVariable] = session
        }
        app.launch()
        ensureOrientation(Self.runOrientation)
    }

    /// Whether this run carries an injected session.
    ///
    /// ⚠️ CASES THAT NEED ONE SKIP RATHER THAN FAIL WHEN IT IS ABSENT, so the
    /// unauthenticated subset stays runnable on an unsigned CI simulator with no
    /// credential anywhere near it.
    var hasInjectedSession: Bool {
        ProcessInfo.processInfo.environment[UITestLaunch.sessionVariable]?.isEmpty == false
    }

    func requireSession() throws {
        try XCTSkipUnless(hasInjectedSession, "no minted review session in this run")
    }

    // MARK: - Orientation

    /// Turn the device to `wanted`, then wait up to `timeout`, looking every quarter second, for
    /// the app's window to take its shape: wider than tall for landscape, taller for portrait.
    ///
    /// ⛔ A ROTATION THE DEVICE DID NOT PERFORM FAILS THE CASE, IT NEVER PASSES IT. The setter
    /// reports nothing, and reading `XCUIDevice.shared.orientation` back returns the request, not
    /// the device, so only the window's frame decides; a case that trusted the setter would pass
    /// with nothing turned.
    /// ⚠️ ONE RETRY, BY WAY OF THE OTHER SHAPE: the setter is a no-op when its cached value already
    /// equals the request, so a dropped rotation would otherwise stay dropped for good.
    /// ⚠️ A PORTRAIT-ONLY PHONE IS SATISFIED, NOT FAILED: a portrait window meets a portrait request, and a
    /// landscape request on compact width is exempt: a tab bar on screen (``ShellNavigator/isCompact(_:)``),
    /// or, at the sign-in gate where there is none, a window whose shorter side is under 600 points.
    func ensureOrientation(_ wanted: UIDeviceOrientation, timeout: TimeInterval = 8) {
        XCUIDevice.shared.orientation = wanted
        let frame = windowFrame()
        let compact = ShellNavigator.isCompact(app) || (frame != .zero && min(frame.width, frame.height) < 600)
        guard !(wanted.isLandscape && compact) else { return }
        guard !windowTakes(wanted, within: timeout) else { return }
        XCUIDevice.shared.orientation = wanted.isLandscape ? .portrait : .landscapeLeft
        XCUIDevice.shared.orientation = wanted
        guard !windowTakes(wanted, within: timeout) else { return }
        let shape = wanted.isLandscape ? "landscape" : "portrait"
        XCTFail("the device never turned to \(shape) (\(wanted.rawValue)): the app's window is \(windowFrame().size)")
    }

    /// Whether the app's window has `wanted`'s shape, now or within `timeout`.
    private func windowTakes(_ wanted: UIDeviceOrientation, within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var frame = windowFrame()
        while wanted.isLandscape ? frame.width <= frame.height : frame.height <= frame.width {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.25)
            frame = windowFrame()
        }
        return true
    }

    /// ⚠️ ZERO WITHOUT A WINDOW, which fits neither shape, rather than a failed query.
    private func windowFrame() -> CGRect {
        let window = app.windows.firstMatch
        return window.exists ? window.frame : .zero
    }

    // MARK: - Addressing

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    func row(_ base: String, id: String) -> XCUIElement {
        element("\(base)-\(id)")
    }

    /// Whether the signed-in shell is on screen, in either layout. See ``ShellNavigator``.
    func shellIsUp(timeout: TimeInterval = 10) -> Bool {
        ShellNavigator.shellIsUp(in: app, timeout: timeout)
    }

    /// Open a section on whichever layout is on screen: the tab bar or the Overview's rows on
    /// compact width, the sidebar on regular width. See ``ShellNavigator``.
    ///
    /// ⚠️ NOT THROUGH ``tap(_:)``: the forbidden set keys on identifiers, a tab has none, and
    /// no section is a destructive surface.
    func navigate(to section: ShellSection, timeout: TimeInterval = 10) {
        XCTAssertTrue(
            ShellNavigator.navigate(app, to: section, timeout: timeout),
            "\(section) could not be reached on the layout on screen"
        )
    }

    /// Whether this run is looking at a signed-in app.
    ///
    /// ⛔ A DEVICE IS NOT A CLEAN SIMULATOR. A signed build keeps its session in the
    /// keychain, so a handset somebody has used is signed in on launch — which is why
    /// the unauthenticated cases have to check rather than assume. On an UNSIGNED CI
    /// simulator the keychain read fails (-34018) and the app lands on the gate, which
    /// is the only reason those cases pass there.
    /// ⚠️ DETERMINED ONCE PER RUN, NOT PER CASE. `setUpWithError` runs for every test,
    /// and on the CI simulator the shell never appears, so a per-case wait paid the
    /// full timeout every time — 4 unauthenticated cases × 20 s = 80 s of a run spent
    /// waiting for something that was never coming. The app is launched once (see the
    /// ⛔ on ``app``), so whether it is signed in cannot change between cases either.
    /// ⚠️ EITHER LAYOUT COUNTS: an iPad signed in shows a sidebar, not a tab bar.
    var isSignedIn: Bool {
        if let known = Self.signedIn {
            return known
        }
        let answer = shellIsUp(timeout: 10)
        Self.signedIn = answer
        return answer
    }

    /// ⛔ THE ONLY TAP HELPER FOR IDENTIFIED CONTROLS, AND IT REFUSES THE FORBIDDEN SET. A
    /// `precondition` rather than an `XCTFail`: this is not a test that should fail, it is a
    /// line that must not execute, and failing the assertion after the tap would be too late
    /// to matter.
    func tap(_ id: String, timeout: TimeInterval = 10) {
        precondition(
            !Self.forbiddenSurfaces.contains(id),
            "\(id) is a destructive surface against the live workspace and must never be tapped by a test"
        )
        let target = element(id)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(id) never appeared")
        target.tap()
    }

    /// ⛔ THE SCREEN AS A PERSON SEES IT, IN EITHER ORIENTATION: THE WINDOW'S SCREENSHOT, NEVER
    /// `app.screenshot()`. In landscape that copies the portrait-native framebuffer UN-ROTATED
    /// into a landscape canvas: the rightmost 344 points are cropped away, the rest is black, and
    /// the file displays as a 2064x2752 portrait. The window's, like the main screen's, is the
    /// whole 2752x2064 frame; in portrait they agree. Seen on the iPad Pro 13-inch (M5)
    /// simulator, iOS 26.3, Xcode 26.3.
    /// ⚠️ THE ROTATION IS A TAG, NOT THE PIXELS: a 2064x2752 buffer tagged EXIF orientation 8.
    /// `image.size` applies the tag; a tool that ignores it sees a portrait image on its side.
    /// ⚠️ NOT THE MAIN SCREEN, which gave the same frame: its name contains the device-screen
    /// token `SourceBanTests` refuses in app code.
    func screenCapture() -> XCUIScreenshot {
        app.windows.firstMatch.screenshot()
    }

    @discardableResult
    func screenshot(_ name: String) -> XCTAttachment {
        let shot = XCTAttachment(screenshot: screenCapture())
        shot.name = name
        // ⚠️ `keepAlways`, because a passing run's screenshots are the evidence the
        // test plan cites; the default discards them on success.
        shot.lifetime = .keepAlways
        add(shot)
        return shot
    }
}

/// ⛔ THE LAUNCH CONTRACT, DUPLICATED ON PURPOSE. `UITestSession` lives inside
/// `#if DEBUG` in the app target, and a `bundle.ui-testing` target cannot import the
/// app at all — so the runner cannot reference those constants even though it must
/// agree with them. Two literals that must match, with each naming the other, is the
/// honest shape; a shared file would drag the whole seam into the UI bundle.
enum UITestLaunch {
    static let argument = "-UITestSession"
    static let sessionVariable = "DISTRICT_UITEST_SESSION"
}

/// A top-level place in the signed-in shell, named once for both layouts.
///
/// ⚠️ A COPY OF THE APP'S `SidebarItem`, IN THE SAME ORDER, BECAUSE A UI-TEST BUNDLE CANNOT
/// IMPORT THE APP. The sidebar identifiers are shared source (``A11yID/Sidebar``); the tab labels
/// and the Overview's row titles are the words those screens draw, which is all a UI test can
/// address them by. The order is the sidebar's, which a case asserts.
enum ShellSection: CaseIterable {
    case overview, inbox, calls, contacts
    case hq, analytics, marketplace, billing, rooms, workflows, desk, dialer, scheduling, support, settings
    case account

    /// The tab bar button's label on compact width, or nil for a hub section, which is a row
    /// on the Overview there.
    var tabLabel: String? {
        switch self {
        case .overview: A11yID.NavLabel.overview
        case .inbox: A11yID.NavLabel.inbox
        case .calls: A11yID.NavLabel.calls
        case .contacts: A11yID.NavLabel.contacts
        case .account: A11yID.NavLabel.account
        case .hq, .analytics, .marketplace, .billing, .rooms, .workflows, .desk, .dialer, .scheduling,
             .support, .settings:
            nil
        }
    }

    /// The title of the Overview row that opens a hub section on compact width.
    ///
    /// ⚠️ HQ'S ROW IS A CALL TO ACTION, NOT THE SCREEN'S NAME: the Overview says "Open District
    /// HQ" where the sidebar says "District HQ".
    var overviewRowTitle: String? {
        switch self {
        case .hq: "Open District HQ"
        case .analytics: "Analytics"
        case .marketplace: "Phone numbers"
        case .billing: "Billing"
        case .rooms: "Rooms"
        case .workflows: "Workflows"
        case .desk: "Desk"
        case .dialer: "Dial"
        case .scheduling: "Scheduling"
        case .support: "Support"
        case .settings: "Workspace settings"
        case .overview, .inbox, .calls, .contacts, .account: nil
        }
    }

    /// The identifier on this section's sidebar row, on regular width.
    var sidebarID: String {
        switch self {
        case .overview: A11yID.Sidebar.overview
        case .inbox: A11yID.Sidebar.inbox
        case .calls: A11yID.Sidebar.calls
        case .contacts: A11yID.Sidebar.contacts
        case .hq: A11yID.Sidebar.hq
        case .analytics: A11yID.Sidebar.analytics
        case .marketplace: A11yID.Sidebar.marketplace
        case .billing: A11yID.Sidebar.billing
        case .rooms: A11yID.Sidebar.rooms
        case .workflows: A11yID.Sidebar.workflows
        case .desk: A11yID.Sidebar.desk
        case .dialer: A11yID.Sidebar.dialer
        case .scheduling: A11yID.Sidebar.scheduling
        case .support: A11yID.Sidebar.support
        case .settings: A11yID.Sidebar.settings
        case .account: A11yID.Sidebar.account
        }
    }

    /// Whether regular width draws this section as a list with the open row beside it, which
    /// in portrait starts with the list itself hidden.
    var isListSection: Bool {
        switch self {
        case .inbox, .calls, .contacts, .desk, .support: true
        case .overview, .hq, .analytics, .marketplace, .billing, .rooms, .workflows, .dialer, .scheduling,
             .settings, .account:
            false
        }
    }

    /// The section a sidebar row identifier names, or nil for one this list does not know.
    init?(sidebarID: String) {
        guard let match = Self.allCases.first(where: { $0.sidebarID == sidebarID }) else { return nil }
        self = match
    }
}

/// Reaching a section of the signed-in shell on whichever layout is on screen.
///
/// ⛔ THE LAYOUT IS READ OFF THE SCREEN, NEVER OFF THE DEVICE. An iPad in narrow Split View
/// draws the tab bar and a full-screen one draws the sidebar, so "is this an iPad" answers the
/// wrong question here for the same reason the app never asks it. A tab bar means compact
/// width; a sidebar row, or the split view's own button that shows the sidebar, means regular.
///
/// ⚠️ A SHARED TYPE RATHER THAN A METHOD ON ``UITestApp``, because the recording walks and the
/// Larger Text tour own their launches and do not inherit that base.
enum ShellNavigator {
    /// ⚠️ THE SYSTEM'S LABEL FOR THE SPLIT VIEW'S SIDEBAR BUTTON, WHICH CARRIES NO IDENTIFIER.
    /// In portrait, and after a row is chosen from the overlay, the sidebar is hidden and its
    /// rows are absent from the accessibility tree altogether, so this button is the only sign
    /// on screen that there is a sidebar.
    static let showSidebar = "Show Sidebar"

    /// The prefix every ``A11yID/Sidebar`` row identifier shares.
    static let sidebarPrefix = "district-sidebar-"

    /// Whether the signed-in shell is on screen, in either layout, waiting up to `timeout`.
    static func shellIsUp(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let shell = NSPredicate(
            format: "elementType == %d OR identifier BEGINSWITH %@ OR label == %@",
            XCUIElement.ElementType.tabBar.rawValue,
            sidebarPrefix,
            showSidebar
        )
        return app.descendants(matching: .any).matching(shell).firstMatch.waitForExistence(timeout: timeout)
    }

    /// Whether the shell on screen is the tab bar. ⚠️ Meaningful only once ``shellIsUp(in:timeout:)``
    /// has answered true.
    static func isCompact(_ app: XCUIApplication) -> Bool {
        app.tabBars.firstMatch.exists
    }

    /// Open `section`, and say whether its control was found and tapped.
    @discardableResult
    static func navigate(_ app: XCUIApplication, to section: ShellSection, timeout: TimeInterval = 10) -> Bool {
        guard shellIsUp(in: app, timeout: timeout) else { return false }
        guard isCompact(app) else {
            guard tapSidebarRow(app, section) else { return false }
            if section.isListSection {
                showListColumn(app)
            }
            return true
        }
        if let label = section.tabLabel {
            return tapTab(app, label, timeout: timeout)
        }
        guard let title = section.overviewRowTitle, tapTab(app, A11yID.NavLabel.overview, timeout: timeout) else {
            return false
        }
        popToOverview(app)
        let row = overviewRow(app, title)
        guard row.waitForExistence(timeout: timeout) else { return false }
        bringIntoView(row) { app.swipeUp() }
        row.tap()
        return true
    }

    // MARK: - Compact width

    /// ⛔ BY LABEL AND OUT OF `app.tabBars`, NOT BY IDENTIFIER AND NOT OUT OF
    /// `app.buttons`. Two separate reasons, both measured rather than reasoned:
    ///
    /// `.tabItem` carries NO identifier in SwiftUI, so `app.buttons["district-nav-…"]`
    /// matches nothing — on an iPhone XS Max the id sat on a full-screen `Other` while
    /// the TabBar held `Button, label: 'Overview'`.
    ///
    /// ⚠️ AND `app.buttons[…]` IS UNSCOPED: it matches any button whose identifier OR
    /// label equals the string, anywhere in the hierarchy. "Calls" and "Contacts" are
    /// plausible labels for buttons on the shell outside the tab bar, and a query that
    /// resolves to more than one element fails on `.tap()` with a multiple-matches
    /// error — the same silent-until-first-run shape as the identifier trap.
    static func tab(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.tabBars.buttons[label]
    }

    private static func tapTab(_ app: XCUIApplication, _ label: String, timeout: TimeInterval) -> Bool {
        let target = tab(app, label)
        guard target.waitForExistence(timeout: timeout) else { return false }
        target.tap()
        return true
    }

    /// ⚠️ A HUB OPENED EARLIER CAN STILL BE PUSHED ON THE OVERVIEW'S STACK, and the Overview's
    /// rows are not on screen until it is popped.
    private static func popToOverview(_ app: XCUIApplication) {
        let root = app.descendants(matching: .any)[A11yID.Overview.root]
        var presses = 0
        while !root.waitForExistence(timeout: 2), presses < 4 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { return }
            back.tap()
            presses += 1
        }
    }

    /// ⚠️ THE EXACT TITLE, OR THE TITLE FOLLOWED BY THE ROW'S CAPTION ("Billing, Read-only").
    /// A bare prefix would also match a recent-activity row whose caller's name happens to
    /// start with the same word.
    private static func overviewRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let titled = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")
        return app.buttons.matching(titled).firstMatch
    }

    // MARK: - Regular width

    /// ⛔ THE CELL, NOT THE IDENTIFIER. A sidebar row's identifier lands on both its icon and
    /// its title, so `descendants(matching: .any)[id]` matches two elements and refuses to tap;
    /// the collection cell that holds them is one element, and the thing a finger presses.
    static func sidebarRow(_ app: XCUIApplication, _ section: ShellSection) -> XCUIElement {
        app.cells.containing(.any, identifier: section.sidebarID).firstMatch
    }

    /// ⚠️ THE SYSTEM'S LABEL FOR THE SIDEBAR'S LIST, like ``showSidebar``.
    static func sidebarList(_ app: XCUIApplication) -> XCUIElement {
        app.collectionViews["Sidebar"]
    }

    /// Show the sidebar if the width has hidden it, and say whether it is on screen.
    @discardableResult
    static func revealSidebar(_ app: XCUIApplication) -> Bool {
        let list = sidebarList(app)
        var presses = 0
        while !list.waitForExistence(timeout: 2), presses < 2 {
            let toggle = app.buttons[showSidebar]
            guard toggle.exists else { return false }
            toggle.tap()
            presses += 1
        }
        return list.exists
    }

    /// ⚠️ SCROLLED INTO VIEW BEFORE THE TAP, IN EITHER DIRECTION: a sidebar taller than the
    /// window (an iPad mini in landscape) has cells for the rows it shows and none for the
    /// rest, and it may have been left scrolled either way.
    private static func tapSidebarRow(_ app: XCUIApplication, _ section: ShellSection) -> Bool {
        guard revealSidebar(app) else { return false }
        let row = sidebarRow(app, section)
        let list = sidebarList(app)
        bringIntoView(row) { list.swipeUp() }
        bringIntoView(row) { list.swipeDown() }
        guard row.exists else { return false }
        row.tap()
        return true
    }

    /// ⚠️ A LIST SECTION IN PORTRAIT OPENS ON ITS EMPTY DETAIL COLUMN, with the list behind the
    /// same button as the sidebar. One press shows both, so the section's rows are on screen as
    /// they are on a phone; where the width already shows them, there is no button to press.
    static func showListColumn(_ app: XCUIApplication) {
        let toggle = app.buttons[showSidebar]
        if toggle.waitForExistence(timeout: 2) {
            toggle.tap()
        }
    }

    /// ⚠️ VERTICAL ONLY. A horizontal swipe over a list row is how a UI test finds a destructive
    /// swipe action.
    private static func bringIntoView(_ element: XCUIElement, swipe: () -> Void) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 6 {
            swipe()
            swipes += 1
        }
    }
}
