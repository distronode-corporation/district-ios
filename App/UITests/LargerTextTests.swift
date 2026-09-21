import XCTest

/// The app at the largest accessibility text size.
///
/// ⛔ ITS OWN `XCUIApplication`, NOT `UITestApp`'S SHARED ONE, AND THAT IS FORCED.
/// The shared app is launched exactly once per run (the injected refresh token is
/// single-use, so a relaunch would revoke the session mid-suite), and a content-size
/// category can only be set AT LAUNCH. This case needs no session, so it can own its
/// own instance without touching that rule.
///
/// ⛔ IT ASSERTS `isHittable`, NEVER `exists`. That distinction is the whole point at
/// AX5: a control pushed off the bottom of the screen, or under the tab bar, or
/// behind another view, still EXISTS. `waitForExistence` would pass on a sign-in
/// button nobody can reach, which is precisely the failure Larger Text introduces and
/// exactly the claim Apple's evaluation asks us to make.
final class LargerTextTests: XCTestCase {
    /// ⚠️ `UICTContentSizeCategoryAccessibilityXXXL` IS AX5, the largest the system
    /// offers, and the size Apple's own Larger Text criteria are written against.
    private static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        // ⛔ THE SEAM ARGUMENT COMES FIRST AND MUST NOT BE DROPPED. This class
        // owns its own launch, so assigning `launchArguments` wholesale would
        // replace `-UITestSession` with the text-size flags. The app would then take
        // the Keychain store, whose read THROWS on an unsigned simulator build, and
        // stay running unarmed for every later class — so `UnauthenticatedTests`
        // (alphabetically last) would be tested against an app showing "We could not
        // read your saved session", the one screen that deliberately draws no Sign
        // in with Apple button.
        app.launchArguments = [UITestLaunch.argument, "-UIPreferredContentSizeCategoryName", Self.ax5]
        XCUIDevice.shared.orientation = UITestApp.runOrientation
        app.launch()
        // ⚠️ SKIPPED ON A SIGNED-IN APP, for the same reason as the other
        // unauthenticated cases: a signed build restores its session from the
        // keychain and never shows the gate. On the unsigned CI simulator the
        // keychain read fails and this runs, which is where it has to run. Signed
        // in means either shell: the tab bar, or the sidebar on regular width.
        try XCTSkipIf(
            ShellNavigator.shellIsUp(in: app, timeout: 10),
            "this app is signed in; the sign-in gate is not reachable to measure"
        )
    }

    func test_IOS_A11Y_02_theSignInGateIsUsableAtTheLargestTextSize() {
        let root = app.descendants(matching: .any)[A11yID.SignIn.root]
        XCTAssertTrue(root.waitForExistence(timeout: 30), "the gate never rendered at AX5")

        let button = app.descendants(matching: .any)[A11yID.SignIn.button]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "the sign-in control vanished at AX5")
        // ⛔ THE ASSERTION THAT MATTERS. Existence is not usability.
        XCTAssertTrue(
            button.isHittable,
            "the sign-in button exists but cannot be tapped at AX5 — it is off screen or covered"
        )

        let status = app.descendants(matching: .any)[A11yID.SignIn.status]
        if status.exists {
            XCTAssertTrue(status.isHittable, "the status line is present but unreachable at AX5")
        }

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "IOS-A11Y-02-sign-in-AX5"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// ⚠️ A CHEAP GUARD ON THE SCALING ITSELF. If the descriptors ever stop scaling —
    /// the frozen-`static let` failure this suite exists to catch — the gate renders
    /// identically at AX5 and every assertion above still passes. Comparing the
    /// button's height against a default-size launch is what would notice.
    func test_IOS_A11Y_03_theTypeActuallyGrows() {
        let atAX5 = app.descendants(matching: .any)[A11yID.SignIn.button]
        XCTAssertTrue(atAX5.waitForExistence(timeout: 30))
        let tallAtAX5 = atAX5.frame.height

        app.terminate()
        let plain = XCUIApplication()
        plain.launchArguments = [
            UITestLaunch.argument,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryLarge",
        ]
        plain.launch()
        let atDefault = plain.descendants(matching: .any)[A11yID.SignIn.button]
        XCTAssertTrue(atDefault.waitForExistence(timeout: 30))

        XCTAssertGreaterThan(
            tallAtAX5, atDefault.frame.height,
            "the sign-in button is the same height at AX5 as at the default size, "
                + "so the type is not scaling at all"
        )
    }
}
