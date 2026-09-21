import XCTest

/// A one-run diagnostic, not a walk: screenshots and the full element hierarchy at
/// every step, attached to the result bundle, so a failed navigation is read off
/// facts rather than guessed at. Not part of any release lane.
final class InboxDiagnosticTests: ReviewRecordingCase {
    func test_inboxRowDiagnostic() throws {
        try XCTSkipIf(
            email.isEmpty || password.isEmpty,
            "REVIEW_EMAIL / REVIEW_PASSWORD missing"
        )

        launchSignedIn()
        tapACallsRow()

        ShellNavigator.navigate(app, to: .inbox)
        XCTAssertTrue(any(A11yID.Inbox.root).waitForExistence(timeout: 30), "inbox")
        pause(3)
        snap("05-inbox")
        dump("05-inbox-hierarchy")

        let row = firstRow(A11yID.Inbox.rowBase)
        XCTAssertNotNil(row, "a row")
        if let row {
            let cell = app.cells.firstMatch
            NSLog(
                "[diag] row exists=%d hittable=%d frame=%@ | cells=%d cellFrame=%@ | buttons(id) exists=%d",
                row.exists,
                row.isHittable,
                NSCoder.string(for: row.frame),
                app.cells.count,
                NSCoder.string(for: cell.frame),
                app.buttons[row.identifier].exists
            )
            row.tap(); pause(3)
            snap("06-after-row-tap")
            dump("06-after-row-tap-hierarchy")
            if !any(A11yID.Inbox.threadRoot).exists {
                tapASearchHit()
            }
        }
    }

    private func launchSignedIn() {
        allowSystemAlerts()
        app.launch()
        snap("01-launch")
        if any(A11yID.SignIn.button).waitForExistence(timeout: 15) {
            any(A11yID.SignIn.button).tap()
            let consent = springboard.buttons["Continue"]
            if consent.waitForExistence(timeout: 12) {
                consent.tap()
            }
            signInOnWeb()
        }
        XCTAssertTrue(ShellNavigator.shellIsUp(in: app, timeout: 90), "shell")
        snap("02-shell")
    }

    /// Control: a Calls row is a plain `NavigationLink` with no gesture beside it.
    private func tapACallsRow() {
        ShellNavigator.navigate(app, to: .calls); pause(3)
        snap("03-calls")
        let callRow = app.cells.firstMatch
        if callRow.waitForExistence(timeout: 10) {
            callRow.tap(); pause(3)
            snap("04-calls-row-tapped")
            back(); pause(1)
        }
    }

    /// Second route in: the search results list, keyed on the message rather than the thread.
    private func tapASearchHit() {
        let search = app.searchFields.firstMatch
        guard search.waitForExistence(timeout: 5) else { return }
        search.tap(); pause(1)
        search.typeText("Hello"); pause(4)
        snap("07-search")
        let hit = app.cells.firstMatch
        if hit.waitForExistence(timeout: 10) {
            hit.tap(); pause(3)
            snap("08-after-search-hit-tap")
            dump("08-after-search-hit-hierarchy")
        }
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func dump(_ name: String) {
        let text = XCTAttachment(string: app.debugDescription)
        text.name = name
        text.lifetime = .keepAlways
        add(text)
    }
}
