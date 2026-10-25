import XCTest

/// The mobile smoke suite: one signed-in journey across the six screens a reviewer
/// opens first.
///
/// ⛔ THIS BUNDLE IS NOT `DistrictAIUITests`, AND THE SPLIT IS THE WHOLE DESIGN. That
/// suite's base class launches the app ONCE per run and shares one `XCUIApplication`,
/// because the session it injects is a single-use refresh token that a second
/// `launch()` replays and the server then revokes the whole family for. This suite
/// signs in the way a real user does, through the browser handshake, with the demo
/// account's own credentials, so it owns its launch. Inheriting `UITestApp` would have
/// meant one of those two contracts quietly losing.
///
/// ⛔ READ-ONLY ON THE PRODUCT. Every step is a read or a navigation. In particular the
/// sign-out row is ASSERTED AND NEVER TAPPED: `UITestApp.forbiddenSurfaces` lists
/// `district-account-sign-out` and the reason applies here too, signing out revokes
/// the refresh-token family, and a suite that ends by destroying its own credential
/// cannot be re-run against the same injected session. ⚠️ THIS IS A DELIBERATE
/// DIVERGENCE FROM THE ANDROID FLOW, which does tap sign out. Android signs in from
/// scratch on every run and has no injected session to protect; iOS does.
///
/// ⛔ CREDENTIALS COME FROM `scripts/smoke-simulator.sh` AND ARE NEVER COMMITTED. The email
/// arrives in the runner's environment; the password NEVER reaches this process at all, the
/// script puts it on the simulator's pasteboard and this suite pastes it (see
/// `pastePassword(into:in:)`). With either missing every case skips with a message naming
/// what was missing, which is a real outcome rather than a silent pass.
final class SmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The demo account, supplied by `scripts/smoke-simulator.sh`.
    ///
    /// ⚠️ `TEST_RUNNER_`-PREFIXED ON THE COMMAND LINE, BARE HERE. `xcodebuild` passes a
    /// variable into the UI-test RUNNER process by prefixing it, and strips the prefix
    /// before the test sees it. `scripts/uitest-device-imac.sh` already does this for
    /// `DISTRICT_UITEST_SESSION`; the same rule applies to these.
    private static let emailVariable = "DISTRICT_SMOKE_EMAIL"
    /// ⛔ A FLAG, NOT THE PASSWORD: "1" when the script has put the password on the
    /// simulator's pasteboard.
    private static let pasteboardVariable = "DISTRICT_SMOKE_PASSWORD_ON_PASTEBOARD"
    private static let contactVariable = "DISTRICT_SMOKE_CONTACT"
    private static let planVariable = "DISTRICT_SMOKE_PLAN"

    /// ⚠️ THE SYSTEM'S LABEL FOR THE SPLIT VIEW'S SIDEBAR BUTTON, which carries no identifier.
    private static let showSidebar = "Show Sidebar"

    private var email: String {
        Self.environment(Self.emailVariable)
    }

    private var passwordOnPasteboard: Bool {
        Self.environment(Self.pasteboardVariable) == "1"
    }

    private var contactName: String {
        Self.environment(Self.contactVariable)
    }

    private var expectedPlan: String {
        let value = Self.environment(Self.planVariable)
        return value.isEmpty ? "Studio" : value
    }

    private static func environment(_ key: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? ""
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // ⛔ FAIL THE FIRST ASSERTION RATHER THAN CARRYING ON. A UI test that keeps
        // going after a missed element reports the LAST failure, which is never the
        // one that explains anything.
        continueAfterFailure = false

        try XCTSkipIf(
            email.isEmpty || !passwordOnPasteboard,
            "\(Self.emailVariable) / \(Self.pasteboardVariable) unset; run scripts/smoke-simulator.sh"
        )

        // ⚠️ NOTHING IN `launchEnvironment`: the app reads none of the smoke variables, and the
        // password was once handed to it here for no reader at all.
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    /// The whole journey, in order, because the screens after the first are only
    /// reachable once the handshake has completed.
    ///
    /// ⚠️ ONE TEST METHOD RATHER THAN SIX. XCTest builds a fresh instance per method,
    /// so six methods would mean six launches and six browser sign-ins against the
    /// same account, six PKCE handshakes to prove one thing, and a rate limiter that
    /// would eventually notice.
    func test_IOS_SMOKE_01_theDemoAccountReachesEveryReviewedScreen() throws {
        try signIn()
        try tourConsoleHome()
        try tourCallsAndInbox()
        try tourContactsAndDossier()
        try tourBilling()
        try tourAccount()
    }
}

// MARK: - Legs

/// ⚠️ IN AN EXTENSION SO THE CLASS BODY STAYS UNDER SwiftLint's `type_body_length`
/// (300) and each leg under `function_body_length` (60). Both are errors under
/// `--strict`, so this is a constraint rather than a preference.
private extension SmokeUITests {
    /// The browser leg of the PKCE handshake.
    ///
    /// ⛔ THREE PROCESSES, NOT ONE, AND THAT IS WHY THIS IS THE FRAGILE LEG.
    /// `WebAuthLoginController` uses `ASWebAuthenticationSession`, which (1) raises a
    /// SpringBoard consent alert naming the domain, and (2) renders the page in
    /// `SafariViewService`, a separate process. Neither is reachable through `app`, so
    /// both are addressed by bundle id. A query against `app.webViews` finds nothing
    /// here and reads as "the page did not load".
    func signIn() throws {
        let root = element(A11yID.SignIn.root)
        XCTAssertTrue(root.waitForExistence(timeout: 30), "the sign-in screen never rendered")
        attach(name: "IOS-SMOKE-01-sign-in")

        let button = element(A11yID.SignIn.button)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the sign-in control is missing")
        button.tap()

        try acceptAuthenticationConsent()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let consent = safari.buttons["Continue to District AI"]
        try completeWebLogin(in: safari, consent: consent)

        // Back in the app over the custom scheme. The budget covers a code exchange
        // and then the overview's own network read, not just a navigation.
        let overview = element(A11yID.Overview.root)
        XCTAssertTrue(
            awaitLanding(on: overview, consent: consent, browser: safari),
            "the handshake never landed on the console"
        )
    }

    /// ⚠️ THE SYSTEM ALERT IS NOT OPTIONAL AND NOT SUPPRESSIBLE. iOS raises it on every
    /// `ASWebAuthenticationSession` start because the session may carry existing
    /// website credentials; `prefersEphemeralWebBrowserSession` changes the cookie jar,
    /// not the prompt. It is tolerated rather than required, because the button's label
    /// is localised and a missing alert must not fail a run that otherwise proceeds.
    func acceptAuthenticationConsent() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let button = springboard.buttons["Continue"]
        if button.waitForExistence(timeout: 15) {
            button.tap()
        }
    }

    /// ⛔ THE WEB PAGE IS ADDRESSED BY ITS VISIBLE ENGLISH LABELS, BECAUSE NOTHING ELSE
    /// IS EXPOSED. Safari publishes an input's label as accessibility text and does not
    /// publish its HTML `id`, so the fields' ids are real and unreachable. The labels
    /// come from the website's English copy, and a copy change there breaks this with
    /// nothing linking the two.
    ///
    /// ⛔ THE PASSWORD IS PASTED, NEVER TYPED, and the second factor and the system's
    /// save-password offer are handled while waiting for consent: see `pastePassword(into:in:)`
    /// and `awaitConsent(_:in:)`.
    func completeWebLogin(in safari: XCUIApplication, consent: XCUIElement) throws {
        let emailField = safari.textFields["Work Email"]
        // A website session left by an earlier run skips the login form.
        let deadline = Date().addingTimeInterval(45)
        while !emailField.exists, !consent.exists, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if consent.exists {
            attach(name: "IOS-SMOKE-02-consent")
            consent.tap()
            return
        }
        XCTAssertTrue(emailField.exists, "the login page never rendered")
        emailField.tap()
        emailField.typeText(email)
        // The keyboard's accessory bar sits over the password field on a 6.3-inch screen, so a
        // tap there lands on the bar and the field never takes focus. Close the keyboard first.
        let done = safari.buttons["Done"]
        if done.waitForExistence(timeout: 2) {
            done.tap()
        }

        let passwordField = safari.secureTextFields["Password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "no password field on the login page")
        passwordField.tap()
        pastePassword(into: passwordField, in: safari)

        let doneAgain = safari.buttons["Done"]
        if doneAgain.waitForExistence(timeout: 2) {
            doneAgain.tap()
        }
        safari.buttons["Enter platform"].tap()

        // ⛔ CONSENT IS A PRESS, NOT A REDIRECT. The server's hand-off page mints the
        // authorization code only on an explicit tap, which is the anti-drive-by guard
        // for the native sign-in. It will not be removed.
        awaitConsent(consent, in: safari)
        attach(name: "IOS-SMOKE-02-consent")
        consent.tap()
    }

    /// The release gate's two screens (3.0.3): Calls and Inbox render for the signed-in account.
    /// ⚠️ `A11yID.Nav.calls`, not `A11yID.Calls.root`: the call log screen carries the tab's
    /// content identifier and nothing sets the latter.
    func tourCallsAndInbox() throws {
        navigate(to: .calls)
        XCTAssertTrue(element(A11yID.Nav.calls).waitForExistence(timeout: 30), "the calls screen never rendered")
        attach(name: "IOS-SMOKE-03b-calls")
        navigate(to: .inbox)
        XCTAssertTrue(element(A11yID.Inbox.root).waitForExistence(timeout: 30), "the inbox never rendered")
        attach(name: "IOS-SMOKE-03c-inbox")
    }

    func tourConsoleHome() throws {
        XCTAssertTrue(element(A11yID.Overview.root).exists, "the console home is not showing")
        attach(name: "IOS-SMOKE-03-console-home")
    }

    /// ⛔ NEVER TAPS `A11yID.Contacts.add`. It opens a create sheet on a live workspace,
    /// and this repo has already paid once for a sweep that addressed rows by index and
    /// hit exactly that control.
    func tourContactsAndDossier() throws {
        navigate(to: .contacts)

        let list = element(A11yID.Contacts.root)
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the contacts list never rendered")
        attach(name: "IOS-SMOKE-04-contacts")

        // ⛔ RETURNS RATHER THAN SKIPS. `XCTSkipIf` here would abandon the WHOLE journey,
        // taking the billing and account legs with it, because a skip thrown mid-test
        // ends that test. Without a seeded contact the dossier is the only leg that
        // cannot run, so it is the only one that stands down.
        guard !contactName.isEmpty else {
            return
        }

        // ⚠️ BY NAME, NEVER BY INDEX. ⛔ AND MATCHED ON `label`, NOT `identifier`: a row
        // is a `NavigationLink` whose accessibility label is its title and subtitle
        // concatenated, so an exact subscript (`app.buttons[contactName]`) misses and
        // `containing(.staticText, identifier:)` matches an identifier the row never
        // sets. A CONTAINS predicate on the label is what actually resolves, and it is
        // still an identity rather than a position.
        let named = NSPredicate(format: "label CONTAINS[c] %@", contactName)
        let row = app.buttons.matching(named).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no contact named \(contactName) in the list")
        row.tap()

        let detail = element(A11yID.Contacts.detailRoot)
        XCTAssertTrue(detail.waitForExistence(timeout: 30), "the contact detail never rendered")

        // ⛔ THE DOSSIER, NOT THE SCREEN. The detail root renders for every contact; the
        // dossier is the DGI payload and is what this leg exists to prove.
        let dossier = element(A11yID.Contacts.dossier)
        XCTAssertTrue(dossier.waitForExistence(timeout: 30), "the DGI dossier section is missing")
        attach(name: "IOS-SMOKE-05-contact-dossier")
    }

    /// ⚠️ NOT A TAB. On compact width Billing is a row on the Overview (`OverviewEntry`
    /// lists it among the console's destinations); on regular width it is a sidebar row.
    func tourBilling() throws {
        navigate(to: .billing)

        let billing = element(A11yID.Billing.root)
        XCTAssertTrue(billing.waitForExistence(timeout: 30), "the billing screen never rendered")

        // ⚠️ THE CARD SHOWS THE PLAN'S NAME, NOT THE WIRE KEY. `BillingCopy.planName`
        // turns `VoiceStudio` into "Voice Studio" (an unknown tier is shown as sent) and a
        // null tier renders "no plan" rather than an invented "Free". The default,
        // "Studio", is in both spellings; a DISTRICT_SMOKE_PLAN must be the name.
        let plan = element(A11yID.Billing.plan).firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 15), "the plan card is missing")
        // ⚠️ THE IDENTIFIER REACHES EACH OF THE CARD'S TEXTS ("Plan", the plan's name, the
        // status badge), so `element(_:)` alone matches several and the first is "Plan".
        // The plan's name is one of them; the failure lists all three.
        let named = app.descendants(matching: .any)
            .matching(identifier: A11yID.Billing.plan)
            .matching(NSPredicate(format: "label CONTAINS %@", expectedPlan)).firstMatch
        let labels = app.descendants(matching: .any).matching(identifier: A11yID.Billing.plan)
            .allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(named.exists, "expected the \(expectedPlan) plan on the card; it reads \(labels)")
        attach(name: "IOS-SMOKE-06-billing")
    }

    /// ⛔ ASSERTS SIGN-OUT AND DOES NOT TAP IT. See the note on the class: the control
    /// is a forbidden surface in the sibling suite for a reason that holds here too.
    func tourAccount() throws {
        navigate(to: .account)

        let account = element(A11yID.Account.root)
        XCTAssertTrue(account.waitForExistence(timeout: 30), "the account screen never rendered")

        let signOut = element(A11yID.Account.signOut)
        XCTAssertTrue(signOut.waitForExistence(timeout: 15), "the sign-out control is missing")
        XCTAssertTrue(signOut.isHittable, "the sign-out control is present but unreachable")
        attach(name: "IOS-SMOKE-07-account")
    }
}

// MARK: - Helpers

private extension SmokeUITests {
    /// ⛔ `descendants(matching: .any)`, NOT `app.otherElements[id]` OR `app.buttons[id]`.
    /// Which XCUIElement TYPE a SwiftUI view reports is not stable: an
    /// `.accessibilityElement(children: .contain)` container usually surfaces as an
    /// `otherElement` and sometimes as a group, and a row that looks like a button can
    /// report as a cell or a link depending on the container it sits in. Querying by
    /// type turns a renamed-nothing into "element not found". The sibling suite's
    /// `element(_:)` helper makes the same choice for the same reason.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Open a section on the layout on screen: a tab or an Overview row on compact width, a
    /// sidebar row on regular width.
    ///
    /// ⛔ THE LAYOUT IS READ OFF THE SCREEN, NEVER OFF THE DEVICE: an iPad in narrow Split View
    /// draws the tab bar. A tab bar is compact width; a sidebar row, or the split view's own
    /// "Show Sidebar" button (the only sign of a sidebar while it is hidden), is regular.
    ///
    /// ⛔ TABS ARE TAPPED BY LABEL OUT OF `tabBars`, NEVER BY IDENTIFIER. `A11yID.Nav.*`
    /// tags each tab's CONTENT root rather than its button, so `app.buttons[...]` finds
    /// nothing. The sibling suite's `ShellNavigator` says the same thing.
    func navigate(to section: SmokeSection, timeout: TimeInterval = 20) {
        let shell = NSPredicate(
            format: "elementType == %d OR identifier BEGINSWITH %@ OR label == %@",
            XCUIElement.ElementType.tabBar.rawValue, "district-sidebar-", Self.showSidebar
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(shell).firstMatch.waitForExistence(timeout: timeout),
            "the signed-in shell is not on screen"
        )
        guard app.tabBars.firstMatch.exists else {
            openSidebarRow(section, timeout: timeout)
            return
        }
        let button = app.tabBars.buttons[section.tabLabel ?? A11yID.NavLabel.overview]
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "no tab for \(section)")
        button.tap()
        guard let rowID = section.overviewRow else { return }
        let entry = app.buttons[rowID]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "no \(rowID) row on the console home")
        entry.tap()
    }

    /// ⛔ THE CELL, NOT THE IDENTIFIER: a sidebar row's identifier lands on its icon and its
    /// title, two elements that refuse a tap together. ⚠️ A hidden sidebar is shown first,
    /// and a list section in portrait needs the same button once more to show its list.
    func openSidebarRow(_ section: SmokeSection, timeout: TimeInterval) {
        let sidebar = app.collectionViews["Sidebar"]
        if !sidebar.waitForExistence(timeout: 3), app.buttons[Self.showSidebar].exists {
            app.buttons[Self.showSidebar].tap()
        }
        let row = app.cells.containing(.any, identifier: section.sidebarID).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "no sidebar row for \(section)")
        row.tap()
        if section.isListSection, app.buttons[Self.showSidebar].waitForExistence(timeout: 2) {
            app.buttons[Self.showSidebar].tap()
        }
    }

    /// ⚠️ `.keepAlways`, BECAUSE THE DEFAULT DISCARDS ON SUCCESS. A smoke run's
    /// screenshots are the evidence that it did what it said, and they are most wanted
    /// on the green run nobody is debugging.
    @discardableResult
    func attach(name: String) -> XCTAttachment {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        return shot
    }
}

/// A section the smoke journey opens, addressed the way each layout draws it.
///
/// ⚠️ A SMALL COPY OF THE SIBLING SUITE'S `ShellSection`, BECAUSE THIS BUNDLE COMPILES ONLY
/// `App/Shared` BESIDE ITSELF. It holds only the sections the journey visits.
enum SmokeSection {
    case contacts, billing, account, calls, inbox

    /// The tab bar label on compact width, or nil for a section that is an Overview row there.
    var tabLabel: String? {
        switch self {
        case .calls: A11yID.NavLabel.calls
        case .inbox: A11yID.NavLabel.inbox
        case .contacts: A11yID.NavLabel.contacts
        case .account: A11yID.NavLabel.account
        case .billing: nil
        }
    }

    /// The Overview row that opens the section on compact width.
    var overviewRow: String? {
        switch self {
        case .billing: A11yID.Overview.row("billing")
        case .contacts, .account, .calls, .inbox: nil
        }
    }

    var sidebarID: String {
        switch self {
        case .contacts: A11yID.Sidebar.contacts
        case .billing: A11yID.Sidebar.billing
        case .account: A11yID.Sidebar.account
        case .calls: A11yID.Sidebar.calls
        case .inbox: A11yID.Sidebar.inbox
        }
    }

    /// Whether regular width draws the section as a list beside its open row.
    var isListSection: Bool {
        switch self {
        case .contacts, .calls, .inbox: true
        case .billing, .account: false
        }
    }
}
