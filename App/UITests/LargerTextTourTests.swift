import XCTest

/// A screenshot of every principal screen at the largest accessibility text size.
///
/// ⛔ THIS CASE PROVES NOTHING BY PASSING. It navigates and captures; whether a
/// screen is clipped, overlapping or truncated to unreadability is a judgement made
/// by a person looking at the attachments afterwards. Assertions here would be worse
/// than useless — a green run would read as "Larger Text works" when all it means is
/// that ten screens rendered something. The pass/fail claim lives in the report the
/// screenshots feed, not in this file.
///
/// ⛔ AND IT IS THE INVERSE OF ``LargerTextTests``: that case needs the sign-in gate
/// and skips on a signed-in app, this one needs a session and skips without one. On
/// the unsigned CI simulator the keychain read fails (-34018), no shell ever
/// appears, and this whole case skips — which is correct. It is device evidence.
///
/// ⛔ EVERY TAP IS A READ. The simulator and the test handset may be signed into a
/// LIVE production workspace: a stray tap is a real message sent
/// or a real number released. ``open(_:)`` refuses the same surfaces `UITestApp`
/// does, and the tour reaches details only by opening the FIRST row of a list —
/// never by pressing a control that writes. ⚠️ Every gesture it makes other than a
/// tap is a VERTICAL swipe: a horizontal one over a list row is how a UI test
/// discovers a destructive swipe action the hard way.
final class LargerTextTourTests: XCTestCase {
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    /// ⛔ MIRRORS `UITestApp.forbiddenSurfaces` RATHER THAN IMPORTING IT. This case
    /// does not inherit from `UITestApp` (it needs its own launch, see the ⛔ on
    /// ``LargerTextTests``), and a copy that names its original is safer here than a
    /// shared base class that would drag the single-launch rule in with it.
    private static let forbidden: Set<String> = [
        A11yID.Contacts.add,
        A11yID.Account.signOut,
        A11yID.Account.delete,
        A11yID.Marketplace.release,
        A11yID.Inbox.send,
        A11yID.Dialer.call,
    ]

    private var app: XCUIApplication!
    private var scheme = "system"
    /// What the run actually managed to reach, printed at the end so the report can
    /// say "no rows in this list" or "off screen and unreachable" rather than
    /// silently showing nine screens of ten.
    private var reached: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    // MARK: - The two runs

    /// ⚠️ ONE METHOD PER SCHEME RATHER THAN ONE PARAMETERISED BY THE ENVIRONMENT. A
    /// colour scheme can only be set at launch, `setUp` runs before the test method
    /// can say which it wants, and a `TEST_RUNNER_`-injected variable was measured
    /// NOT arriving in the runner — every attachment came out named "system". Two
    /// methods each doing their own launch needs no plumbing and cannot silently
    /// photograph the wrong scheme.
    func test_IOS_A11Y_04_everyPrincipalScreenAtAX5_light() throws {
        try tour(scheme: "Light")
    }

    func test_IOS_A11Y_05_everyPrincipalScreenAtAX5_dark() throws {
        try tour(scheme: "Dark")
    }

    private func tour(scheme: String) throws {
        try launch(scheme: scheme)
        overview()
        inbox()
        calls()
        contacts()
        account()
        // ⚠️ PRINTED, NOT ASSERTED. `xcodebuild`'s log is where the report is
        // assembled from, and an unreachable screen is a finding to write down
        // rather than a reason to stop the tour with nine screens left un-shot.
        print("TOUR-REACHED[\(scheme)]: \(reached.joined(separator: " | "))")
    }

    private func launch(scheme: String) throws {
        self.scheme = scheme
        app = XCUIApplication()
        // ⛔ THE SEAM ARGUMENT COMES FIRST AND MUST NOT BE DROPPED. This class
        // owns its own launch, so assigning `launchArguments` wholesale would
        // replace `-UITestSession` with the text-size flags. The app would then take
        // the Keychain store, whose read THROWS on an unsigned simulator build, and
        // stay running unarmed for every later class — so `UnauthenticatedTests`
        // (alphabetically last) would be tested against an app showing "We could not
        // read your saved session", the one screen that deliberately draws no Sign
        // in with Apple button.
        app.launchArguments = [
            UITestLaunch.argument,
            "-UIPreferredContentSizeCategoryName", Self.ax5,
            "-UIUserInterfaceStyle", scheme,
        ]
        app.launch()
        try XCTSkipUnless(
            ShellNavigator.shellIsUp(in: app, timeout: 30),
            "no session on this app, so there is nothing past the gate to photograph"
        )
    }

    // MARK: - Per section

    /// ⚠️ THE DIALER AND SETTINGS ARE NOT TABS. On compact width both are labelled rows in
    /// the Overview's nav list, and at AX5 both are below the fold — hence the scroll in
    /// ``push(label:as:)``. On regular width both are sidebar rows.
    private func overview() {
        show(.overview)
        capture("01-overview")
        hub(.dialer, as: "02-dialer")
        hub(.settings, as: "03-settings-hub")
    }

    private func inbox() {
        show(.inbox)
        capture("04-inbox")
        pushFirstRow(base: A11yID.Inbox.rowBase, as: "05-thread")
    }

    private func calls() {
        show(.calls)
        capture("06-calls")
        pushFirstRow(base: A11yID.Calls.rowBase, as: "07-call-detail")
    }

    private func contacts() {
        show(.contacts)
        capture("08-contacts")
        pushFirstRow(base: A11yID.Contacts.rowBase, as: "09-contact-detail")
    }

    private func account() {
        show(.account)
        capture("10-account")
    }

    // MARK: - Navigation

    /// Open a section on the layout on screen.
    ///
    /// ⛔ A TAB IS PRESSED BY LABEL OUT OF `app.tabBars`, for the reasons on
    /// `ShellNavigator.tab(_:_:)`, and through ``press(_:what:)`` so an AX5 tab bar that
    /// offers no activation point is still recorded. Anything else, including every sidebar
    /// row on regular width, goes through `ShellNavigator`.
    private func show(_ section: ShellSection) {
        guard ShellNavigator.isCompact(app), let label = section.tabLabel else {
            if !ShellNavigator.navigate(app, to: section, timeout: 20) {
                reached.append("MISSING SECTION \(section)")
            }
            return
        }
        let target = ShellNavigator.tab(app, label)
        guard target.waitForExistence(timeout: 20) else {
            reached.append("MISSING TAB \(label)")
            return
        }
        press(target, what: "tab '\(label)'")
    }

    /// A hub section: an Overview row pushed and popped on compact width, a sidebar row
    /// on regular width.
    private func hub(_ section: ShellSection, as name: String) {
        guard ShellNavigator.isCompact(app), let title = section.overviewRowTitle else {
            show(section)
            capture(name)
            return
        }
        show(.overview)
        push(label: title, as: name)
    }

    /// Push a labelled row from the current list, photograph it, come back.
    private func push(label: String, as name: String) {
        let link = app.buttons[label].firstMatch
        guard link.waitForExistence(timeout: 10) else {
            reached.append("UNREACHABLE \(name) (no '\(label)' row)")
            return
        }
        guard bringIntoView(link) else {
            reached.append("OFF SCREEN \(name) ('\(label)' never came into reach at AX5)")
            capture("\(name)-unreachable")
            return
        }
        open(link)
        capture(name)
        back()
    }

    /// ⚠️ THE FIRST ROW, ADDRESSED BY ITS IDENTIFIER PREFIX. Every list row carries
    /// `"\(base)-\(serverId)"` and the server's ids are not knowable here, so a
    /// BEGINSWITH predicate is the only way in. It is position-dependent, which
    /// `A11yID`'s own ⛔ forbids for a test asserting behaviour — this asserts none:
    /// it needs *a* detail screen to photograph, and any row gives one.
    private func pushFirstRow(base: String, as name: String) {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "\(base)-"))
        guard rows.firstMatch.waitForExistence(timeout: 15) else {
            reached.append("EMPTY LIST for \(name) (no \(base)-* rows)")
            return
        }
        let row = rows.element(boundBy: 0)
        guard bringIntoView(row) else {
            reached.append("OFF SCREEN \(name) (first row never came into reach at AX5)")
            capture("\(name)-unreachable")
            return
        }
        open(row)
        capture(name)
        back()
    }

    /// ⛔ SCROLLING IS PART OF THE MEASUREMENT, NOT A WORKAROUND FOR IT. At AX5 a
    /// list that held ten rows holds two, so a row being below the fold is normal and
    /// reaching it by scrolling is what a person would do. What is NOT normal is a
    /// row that never becomes hittable however far the list scrolls, and returning
    /// `false` is how that gets into the report instead of failing the run.
    ///
    /// ⚠️ VERTICAL ONLY. See the ⚠️ on this type.
    private func bringIntoView(_ element: XCUIElement, swipes: Int = 6) -> Bool {
        for _ in 0 ... swipes {
            if element.exists, element.isHittable {
                return true
            }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// ⛔ THE ONLY TAP THAT OPENS SOMETHING, AND IT REFUSES THE FORBIDDEN SET. A
    /// `precondition` rather than an `XCTFail` for `UITestApp`'s reason: this is not
    /// a test that should fail, it is a line that must not execute, and asserting
    /// after the tap would be too late to matter.
    private func open(_ element: XCUIElement) {
        precondition(
            !Self.forbidden.contains(element.identifier),
            "\(element.identifier) writes against the live workspace and must never be tapped by a test"
        )
        element.tap()
    }

    /// ⛔ FALLS BACK TO A COORDINATE TAP, AND THE FALLBACK IS ITSELF A FINDING. At
    /// AX5 iOS re-presents the tab bar as a scrolling tray, and the first tour died
    /// on `Failed to compute hit point for Button … identifier: 'tray', label:
    /// 'Inbox': Activation point invalid` — the button is on screen, its frame is
    /// {{85, 814}, {79, 48}}, and XCUITest still cannot derive a point to press.
    /// Tapping the frame's centre gets the tour past it; the note in `reached` is
    /// what keeps the fact from being lost, because a tab a person may also struggle
    /// to press is exactly what this pass exists to find.
    private func press(_ element: XCUIElement, what: String) {
        if element.isHittable {
            element.tap()
            return
        }
        reached.append("NOTE \(what) had no valid activation point at AX5; pressed by coordinate")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// ⚠️ THE FIRST NAVIGATION-BAR BUTTON IS THE BACK BUTTON, and if there is no bar
    /// the tour is already at a root — the next tab tap will put it right either way,
    /// so a missing back button is not worth failing over.
    private func back() {
        let button = app.navigationBars.buttons.firstMatch
        guard button.exists, button.isHittable else { return }
        button.tap()
    }

    // MARK: - Evidence

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "AX5-\(scheme)-\(name)"
        // ⚠️ `keepAlways`. The default discards attachments on a passing run, and
        // this case's entire product is its attachments.
        shot.lifetime = .keepAlways
        add(shot)
        reached.append(name)
    }
}
