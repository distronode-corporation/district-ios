import XCTest

/// What the two App Review recording walks share: the review credentials, the real
/// sign-in leg through the server's own login surface, and the addressing helpers.
///
/// ⛔ A BASE CLASS RATHER THAN A COPY IN EACH WALK, AND THE SPLIT IS FORCED BY A
/// LINT CEILING RATHER THAN CHOSEN. Both walks in one file exceed SwiftLint's 500
/// `file_length` and 300 `type_body_length`, both errors under `--strict`. The
/// sign-in leg is the largest piece that stands WHOLE on its own, so it lives here.
/// Same reasoning `ThreadAttachments.swift` records for `ThreadModel`.
///
/// ⛔ IT DELIBERATELY DOES **NOT** INHERIT `UITestApp`, AND NEITHER WALK MAY. That
/// base launches the app ONCE per run and refuses every identifier in
/// `forbiddenSurfaces`; these walks sign in for real, place a real call, open the
/// account-deletion page and block a caller, so they own their own launch. What keeps
/// them safe is stated per walk: the 2.1 walk taps nothing that spends money, and the
/// 1.2 walk touches only rows whose label carries the demo workspace's fictional
/// `+1 555 01xx` fragment.
///
/// ⚠️ `-UITestSession` WITH NO SESSION: an empty in-memory store, i.e. a fresh
/// install, so the phone's own keychain session is never read and never written.
/// `-ReviewRecording` marks any support ticket a walk files; see ``ReviewRecordingMode``.
class ReviewRecordingCase: XCTestCase {
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    var email: String {
        ProcessInfo.processInfo.environment["REVIEW_EMAIL"] ?? ""
    }

    var password: String {
        ProcessInfo.processInfo.environment["REVIEW_PASSWORD"] ?? ""
    }

    var number: String {
        ProcessInfo.processInfo.environment["REVIEW_DIAL"] ?? ""
    }

    override func setUp() {
        super.setUp()
        // The video is the deliverable: a missed optional step must not end the take.
        continueAfterFailure = true
        // ⛔ `-ReviewRecording` IS WHAT MARKS THE SUPPORT TICKET A WALK FILES. The
        // Guideline 1.2 flag cannot be demonstrated without using it — submitting the
        // sheet files a REAL request into a REAL Atlassian queue — so the subject
        // becomes "Report: objectionable content (review recording)" and a human can
        // find and close it. Debug-only; see ``ReviewRecordingMode``.
        // ⚠️ ASSIGNED ON EVERY INSTANCE, matching the ⛔ in `UITestApp`: a per-test
        // argument list is the shape that disarms the session seam for a whole suite.
        app.launchArguments = ["-UITestSession", "-ReviewRecording"]
    }

    /// Allow any system alert that appears mid-walk (notifications, microphone).
    ///
    /// ⚠️ ARMED PER TEST RATHER THAN IN `setUp`, because `addUIInterruptionMonitor`
    /// registers against the running test case, and the two walks differ in which
    /// alerts they expect.
    func allowSystemAlerts() {
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            let allow = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Allow'")).firstMatch
            if allow.exists {
                allow.tap(); return true
            }
            if alert.buttons["OK"].exists {
                alert.buttons["OK"].tap(); return true
            }
            return false
        }
    }

    // MARK: - Steps

    func signInOnWeb() {
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 40), "login web sheet")

        // The device may already hold a distronode.com session, in which case the sheet
        // lands straight on the handoff page. Otherwise the login form appears; type into
        // it best-effort (a WKWebView field does not always take a synthesized focus, and
        // the reviewer signs in by hand anyway), then submit.
        let handoff = web.buttons["Continue to District AI"]
        if !handoff.waitForExistence(timeout: 4) {
            let emailField = web.textFields.firstMatch
            // ⚠️ Hoisted out of the `if` DELIBERATELY. Inline, the condition exceeds
            // swiftformat's 120-col wrap, and its `wrapMultilineStatementBraces` then puts
            // the brace on its own line — which SwiftLint's `opening_brace` rejects. The
            // two tools disagree only when the condition is long, so keep it short.
            let existing = emailField.value as? String ?? ""
            let isUnfilled = existing.isEmpty || existing == "email@organization.com"
            if emailField.waitForExistence(timeout: 20), isUnfilled {
                typeInWebField(emailField, email)
            }
            let passwordField = web.secureTextFields.firstMatch
            if passwordField.waitForExistence(timeout: 10) {
                typeInWebField(passwordField, password)
            }
            pause(1)
            let submit = web.buttons["Enter platform"]
            if submit.waitForExistence(timeout: 5), submit.isHittable {
                submit.tap()
            }
        }

        // The handoff page mints the PKCE code and returns it to the app only when tapped.
        if handoff.waitForExistence(timeout: 60) {
            pause(2)
            handoff.tap()
        }
    }

    /// Focus a WKWebView text field and type into it, tolerating the tap that does not
    /// take focus on the first try. A bare `tap()` then `typeText()` raced on the web
    /// email field ("Neither element nor any descendant has keyboard focus"); this waits
    /// for the keyboard and retries with a coordinate tap before giving up.
    func typeInWebField(_ field: XCUIElement, _ text: String) {
        for attempt in 0 ..< 4 {
            if attempt == 0 {
                field.tap()
            } else {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                pause(1)
                field.typeText(text)
                pause(1)
                // ⛔ VERIFY, BECAUSE A PASSWORD-MANAGER SHEET CAN SWALLOW THE KEYSTROKES.
                // A browser's "Fill Password" sheet can rise over the keyboard as the
                // email field focuses; every keystroke goes to it, the field stays at
                // its placeholder, and the form refused with "Fill out
                // this field". A secure field reports dots, so it is checked by length.
                if webFieldHolds(field, text) {
                    return
                }
                clearWebField(field)
            }
            pause(1)
        }
        // best-effort: a web field that will not take text is left to the reviewer
    }

    /// Whether the field now carries `text` (dots counted for a secure field).
    private func webFieldHolds(_ field: XCUIElement, _ text: String) -> Bool {
        let value = field.value as? String ?? ""
        if field.elementType == .secureTextField {
            return value.count == text.count
        }
        return value == text
    }

    /// Select whatever landed and delete it, so the retry types into an empty field.
    private func clearWebField(_ field: XCUIElement) {
        let value = field.value as? String ?? ""
        let placeholder = field.placeholderValue ?? ""
        guard !value.isEmpty, value != placeholder else { return }
        field.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) {
            selectAll.tap()
        }
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        pause(1)
    }

    func allowMicrophone() {
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 12) else { return }
        pause(2)
        let allow = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Allow'")).firstMatch
        if allow.exists {
            allow.tap()
        } else if alert.buttons["OK"].exists {
            alert.buttons["OK"].tap()
        }
    }

    // MARK: - Addressing

    /// ⚠️ `firstMatch`, BECAUSE ONE IDENTIFIER CAN SIT ON TWO ELEMENTS. A SwiftUI
    /// `Menu` in the toolbar exposes `district-thread-menu` on an `Other` AND on the
    /// `Button` inside it (measured on a device hierarchy), and a bare subscript then
    /// refuses to tap: "Multiple matching elements found". The first in tree order is
    /// the wrapper, whose frame is the button's, so a tap on it is a tap on the button.
    func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func firstRow(_ prefix: String) -> XCUIElement? {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let first = query.firstMatch
        return first.waitForExistence(timeout: 10) ? first : nil
    }

    /// A `NavigationLink` row: its button label starts with the row's title.
    func rowTitled(_ title: String) -> XCUIElement {
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", title)).firstMatch
        if button.waitForExistence(timeout: 8) {
            return button
        }
        let text = app.staticTexts[title]
        _ = text.waitForExistence(timeout: 8)
        return text
    }

    /// Open a List row carrying `identifier` and wait for `destination` to appear.
    ///
    /// ⛔ THREE WAYS IN, BECAUSE A `NavigationLink` ROW IS NOT ONE ELEMENT TO XCUITEST.
    /// On a device, `descendants(matching: .any)[id].tap()` can return without error
    /// while nothing navigates: the identifier set on a link inside a
    /// `List` is carried by an element whose frame is not the tappable cell, so the
    /// tap lands beside the row and the walk fails three steps later. The
    /// button (how a List exposes a link row), the cell that contains it, then the
    /// element's own centre are tried in turn, each checked against the destination.
    @discardableResult
    func openRow(_ row: XCUIElement, expecting destination: String) -> Bool {
        let id = row.identifier
        let candidates: [XCUIElement] = [
            app.buttons[id],
            app.cells.containing(NSPredicate(format: "identifier == %@", id)).firstMatch,
            app.cells.containing(.any, identifier: id).firstMatch,
            row,
        ]
        for candidate in candidates where candidate.exists {
            // ⚠️ ONCE, THEN WAIT. A second tap on a row that DID open lands inside the
            // pushed screen. The strategies below are a fallback for a row whose
            // element the tree exposes differently.
            if candidate.isHittable {
                candidate.tap()
            } else {
                candidate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if any(destination).waitForExistence(timeout: 8) {
                return true
            }
        }
        // Last resort: the first visible text of the row, then the first list cell.
        let title = String(row.label.split(separator: ",").first ?? "").trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
            let text = app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
            if text.exists {
                text.tap()
                if any(destination).waitForExistence(timeout: 8) {
                    return true
                }
            }
        }
        let cell = app.cells.element(boundBy: 0)
        if cell.exists {
            cell.tap()
            if any(destination).waitForExistence(timeout: 8) {
                return true
            }
        }
        // Diagnose rather than guess: the tree is what the next edit needs.
        NSLog(
            "[openRow] nothing opened %@ (label '%@'); tree follows\n%@",
            id,
            row.label,
            String(app.debugDescription.prefix(12000))
        )
        return any(destination).waitForExistence(timeout: 3)
    }

    func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.waitForExistence(timeout: 5) {
            button.tap(); pause(1)
        }
    }

    func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
