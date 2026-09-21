import XCTest

/// Walks App Review's shot list on a physical iPhone while XCTest records the screen.
///
/// ⚠️ NOT A GATE AND NOT IN ANY LANE. It is run by hand, once, with
/// `-scheme DistrictAIReviewRecording -only-testing:DistrictAIUITests/ReviewRecordingTests`
/// and `REVIEW_EMAIL` / `REVIEW_PASSWORD` / `REVIEW_DIAL` set. That scheme's only plan is
/// `ReviewRecording.xctestplan`, whose `preferredScreenCaptureFormat: video` is what turns
/// the run into the video recording App Review asks for. It is deliberately NOT a plan on the
/// `DistrictAI` scheme, because a scheme with a plan runs that plan instead of its targets
/// (see project.yml). It signs in for real with the review account, places
/// one real call to the demo receptionist and opens the account-deletion page without
/// touching it, so it deliberately does NOT inherit `UITestApp` and its forbidden set.
///
/// ⚠️ `-UITestSession` WITH NO SESSION: an empty in-memory store, i.e. a fresh install,
/// so the phone's own keychain session is never read and never written.
final class ReviewRecordingTests: ReviewRecordingCase {
    func test_reviewWalk() throws {
        try XCTSkipIf(
            email.isEmpty || password.isEmpty || number.isEmpty,
            "REVIEW_EMAIL / REVIEW_PASSWORD / REVIEW_DIAL missing"
        )

        allowSystemAlerts()

        // 1. Cold launch, 2. sign-in gate with every option visible.
        app.launch()
        XCTAssertTrue(any("district-sign-in-root").waitForExistence(timeout: 40), "sign-in gate")
        pause(3)

        // 3. Sign in with the review account through the web sheet.
        any("district-sign-in-button").tap()
        let consent = springboard.buttons["Continue"]
        if consent.waitForExistence(timeout: 12) {
            consent.tap()
        }
        signInOnWeb()

        // 4. Home.
        XCTAssertTrue(ShellNavigator.shellIsUp(in: app, timeout: 90), "shell after sign-in")
        pause(3)
        app.swipeUp(); pause(2); app.swipeDown(); pause(1)

        // 5. Calls: a call and its transcript.
        ShellNavigator.navigate(app, to: .calls); pause(3)
        if let row = firstRow("district-call-row-") {
            row.tap(); pause(3)
            let show = any("district-call-detail-show-transcript")
            if show.waitForExistence(timeout: 3) {
                show.tap()
            }
            pause(4); app.swipeUp(); pause(2); back()
        }

        // 6. Contacts: a contact and its intelligence.
        ShellNavigator.navigate(app, to: .contacts); pause(3)
        if let row = firstRow("district-contact-row-") {
            row.tap(); pause(4); app.swipeUp(); pause(2); back()
        }

        // 7. Dial: show the dialer and its on-screen microphone disclosure. The demo
        //    workspace has no outbound number, so we do not place a call; the reviewer
        //    calls the demo line instead, and the microphone is requested the first time a
        //    call is placed or answered.
        ShellNavigator.navigate(app, to: .dialer); pause(1)
        XCTAssertTrue(any("district-dialer-entry").waitForExistence(timeout: 15), "dialer entry")
        pause(4)
        back()

        walkSchedulingAndSettings()
        walkAccountDeletion()
    }

    /// Steps 8 and 9, extracted ONLY to keep `test_reviewWalk` under SwiftLint's
    /// 60-line `function_body_length`. The recording is still one continuous take;
    /// these are not independently runnable steps.
    private func walkSchedulingAndSettings() {
        // 8. Scheduling → Bookings.
        ShellNavigator.navigate(app, to: .scheduling); pause(4)
        let bookings = any("district-scheduling-section-bookings")
        if bookings.waitForExistence(timeout: 8) {
            bookings.tap(); pause(4); back()
        }
        back()

        // 9. Workspace settings → Agent persona.
        ShellNavigator.navigate(app, to: .settings); pause(3)
        rowTitled("Agent persona").tap(); pause(4)
        back(); back()
    }

    /// Step 10, same extraction rationale as `walkSchedulingAndSettings`.
    private func walkAccountDeletion() {
        // Account → Delete account opens the deletion page in Safari; nothing is tapped there.
        ShellNavigator.navigate(app, to: .account); pause(3)
        let delete = any("district-account-delete")
        var swipes = 0
        while !delete.isHittable, swipes < 6 {
            app.swipeUp(); swipes += 1; pause(1)
        }
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "delete account row")
        delete.tap()
        pause(8)
        app.activate()
        pause(3)
    }
}
