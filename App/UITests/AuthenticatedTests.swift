import XCTest

/// The classes that need a minted review session.
///
/// ⛔ THEY SKIP RATHER THAN FAIL WHEN THERE IS NONE, AND THAT IS THE WHOLE REASON
/// THEY CAN LIVE HERE AT ALL. `test:ios:ui` runs on an unsigned CI simulator with no
/// credential in the environment; a class that failed without one would make the CI
/// lane permanently red and the suite would be turned off within a week.
/// ⚠️ SO A GREEN RUN OF THIS FILE PROVES NOTHING BY ITSELF. Read the skip count: on
/// CI every case here is SKIPPED, and only a device run with `UITEST_SESSION_FILE`
/// set actually executes them. The test plan reports them as compiled-not-executed
/// until that run exists.
///
/// ⛔ NOTHING HERE MAY TAP A DESTRUCTIVE SURFACE. The simulator and the test handset
/// may be signed into a LIVE production workspace, so every navigation below is a
/// read. `UITestApp.tap(_:)` refuses the forbidden set outright.
final class SessionAndWorkspaceTests: UITestApp {
    func test_IOS_SESS_01_theInjectedSessionReachesTheShell() throws {
        try requireSession()
        XCTAssertTrue(
            shellIsUp(timeout: 15),
            "an injected session must reach the shell without a sign-in"
        )
        screenshot("IOS-SESS-01-shell")
    }

    /// ⚠️ ON THE OVERVIEW FIRST: the header is drawn there and nowhere else, and the app is
    /// on whatever screen the previous class left it.
    func test_IOS_SESS_02_theWorkspaceHeaderNamesTheReviewWorkspace() throws {
        try requireSession()
        navigate(to: .overview)
        let header = element(A11yID.Workspace.header)
        XCTAssertTrue(header.waitForExistence(timeout: 15))
        XCTAssertTrue(header.label.contains("District Review"), "header read '\(header.label)'")
    }
}

/// A read-only tour. Every case navigates and asserts; none writes.
final class ReadOnlyTourTests: UITestApp {
    func test_IOS_TOUR_01_aContactRowOpensItsDetail() throws {
        try requireSession()
        navigate(to: .contacts)
        tap(A11yID.Contacts.row("ct-review-01"))
        XCTAssertTrue(element(A11yID.Contacts.detailRoot).waitForExistence(timeout: 15))
        screenshot("IOS-TOUR-01-contact-detail")
    }

    func test_IOS_TOUR_02_aCallRowOpensItsTranscript() throws {
        try requireSession()
        navigate(to: .calls)
        tap(A11yID.Calls.row("call-review-01"))
        XCTAssertTrue(element(A11yID.Calls.detailRoot).waitForExistence(timeout: 15))
        screenshot("IOS-TOUR-02-call-detail")
    }

    func test_IOS_TOUR_03_theAccountScreenReports() throws {
        try requireSession()
        navigate(to: .account)
        XCTAssertTrue(element(A11yID.Account.root).waitForExistence(timeout: 15))
        XCTAssertTrue(element(A11yID.Account.notifications).exists, "push status must be readable")
        screenshot("IOS-TOUR-03-account")
    }

    /// ⛔ THE RELEASE CONTROL IS NEVER TAPPED, ONLY REACHED. Releasing a number is
    /// irreversible and billed against the live workspace; `tap(_:)` refuses it, and
    /// this case asserts the LIST rather than opening the actions sheet at all.
    /// ⚠️ IT NAVIGATES THERE ITSELF, like every case in this class: the identifier is only
    /// inside the screen, and the previous case leaves the app wherever it finished.
    func test_IOS_TOUR_04_marketplaceListsOwnedNumbers() throws {
        try requireSession()
        navigate(to: .marketplace)
        XCTAssertTrue(element(A11yID.Marketplace.root).waitForExistence(timeout: 15))
        screenshot("IOS-TOUR-04-marketplace")
    }

    func test_IOS_TOUR_05_theRoomsLobbyLists() throws {
        try requireSession()
        navigate(to: .rooms)
        XCTAssertTrue(element(A11yID.Rooms.root).waitForExistence(timeout: 15))
        screenshot("IOS-TOUR-05-rooms")
    }
}

/// ⛔ THE EMERGENCY REFUSAL, ON THE REAL KEYPAD. The sentence itself is pinned by
/// `EmergencyCopyTests` in the unit bundle, which CAN reference `DialerModel`; a UI
/// test target cannot import the app, so duplicating the literal here would be a
/// second source of truth. What only this can prove is that the keypad reaches the
/// refusal and leaves Call disabled.
final class DialerRefusalTests: UITestApp {
    func test_IOS_DIAL_01_nineOneOneRefusesAndLeavesCallDisabled() throws {
        try requireSession()
        navigate(to: .dialer)
        // ⚠️ TYPED, NOT TAPPED. iOS has no keypad: the dialer is a `TextField` with
        // `.keyboardType(.phonePad)`, so the digits come from the system keyboard.
        let entry = element(A11yID.Dialer.entry)
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.tap()
        entry.typeText("911")
        XCTAssertTrue(element(A11yID.Dialer.refusal).waitForExistence(timeout: 5))
        XCTAssertFalse(element(A11yID.Dialer.call).isEnabled, "Call must stay disabled for an emergency code")
        screenshot("IOS-DIAL-01-emergency-refusal")
    }
}

/// District Desk's "New ticket": the button opens the form and Cancel closes it.
///
/// ⛔ THE FORM IS NEVER SUBMITTED. `A11yID.Desk.composeSubmit` is in the forbidden set: a
/// submit is a real ticket in a live workspace's queue. The case asserts that Open ticket
/// is disabled for an empty draft and leaves by Cancel.
/// ⚠️ IT SKIPS WHERE THE BUTTON IS RIGHTLY ABSENT: a desk that is off, or a settings read
/// that failed, offers no "New ticket" on any client (`DeskModel.canStartTicket`).
final class DeskNewTicketTests: UITestApp {
    func test_IOS_DESK_01_newTicketOpensTheFormAndCancelClosesIt() throws {
        try requireSession()
        navigate(to: .desk)
        XCTAssertTrue(element(A11yID.Desk.root).waitForExistence(timeout: 15), "the desk never opened")
        try XCTSkipUnless(
            element(A11yID.Desk.newTicket).waitForExistence(timeout: 15),
            "this workspace's desk is off or unreadable, so no New ticket is offered"
        )
        tap(A11yID.Desk.newTicket)
        XCTAssertTrue(element(A11yID.Desk.composeRoot).waitForExistence(timeout: 10), "the form never opened")
        XCTAssertFalse(element(A11yID.Desk.composeSubmit).isEnabled, "an empty draft must not be submittable")
        screenshot("IOS-DESK-01-new-ticket")
        tap(A11yID.Desk.composeCancel)
        // ⚠️ A PREDICATE WAIT, because `waitForNonExistence` is not on every toolchain this
        // bundle meets (see `ReviewRecordingCase.waitForAbsence`).
        let gone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: element(A11yID.Desk.composeRoot)
        )
        wait(for: [gone], timeout: 10)
    }
}

/// Knowledge's "Read a text file", reached and never used.
///
/// ⚠️ IT DOES NOT OPEN THE PICKER. The Files sheet is system UI with no identifiers of
/// ours, and a pick would put a real file's text in a live workspace's form; what the
/// file is turned into is ``KnowledgeFileReaderTests``' job. This case proves the button
/// is drawn, for a role that may add, beside the form it fills.
final class KnowledgeReadFileTests: UITestApp {
    func test_IOS_KNOW_01_readATextFileIsOfferedBesideTheAddForm() throws {
        try requireSession()
        navigate(to: .settings)
        tap(A11yID.Settings.row("knowledge"))
        XCTAssertTrue(element(A11yID.Knowledge.root).waitForExistence(timeout: 15), "Knowledge never opened")
        let readFile = element(A11yID.Knowledge.readFile)
        try XCTSkipUnless(readFile.waitForExistence(timeout: 10), "this role is not offered the add form")
        XCTAssertTrue(readFile.isEnabled, "Read a text file must be usable while nothing is being added")
        screenshot("IOS-KNOW-01-read-a-text-file")
    }
}

/// The regular-width shell, signed in: what a rotation and the sidebar must not lose.
///
/// ⚠️ EACH CASE SKIPS WHEN A TAB BAR IS SHOWING, which is how compact width shows itself. The
/// check is what is on screen, never the device: an iPad in narrow Split View is compact, and
/// these cases have nothing to say about it.
///
/// ⛔ EVERY CASE ENDS IN THE RUN'S ORIENTATION, because the app is launched once per run and
/// every later case inherits whatever orientation this one leaves.
///
/// ⛔ READS ONLY, like the rest of this file. The dialler case types the emergency code, which
/// the keypad refuses with Call disabled; nothing here reaches `A11yID.Dialer.call`.
final class RegularWidthShellTests: UITestApp {
    override func tearDown() {
        ensureOrientation(Self.runOrientation)
        super.tearDown()
    }

    /// ⛔ A ROTATION CHANGES WHAT IS DRAWN, NEVER WHERE ANYBODY IS. The sidebar collapses and
    /// returns and the columns are rebuilt around the same selection, so the open call and the
    /// section it belongs to are both still there afterwards.
    ///
    /// ⛔ EVERY STEP CHANGES THE WINDOW'S SHAPE, SO EVERY STEP IS PROVED TO HAVE HAPPENED.
    /// ``UITestApp/ensureOrientation(_:timeout:)`` fails the case when the window did not turn;
    /// without it, a rotation the simulator dropped would leave this case passing with nothing
    /// rotated.
    func test_IOS_IPAD_01_rotationKeepsTheSectionAndTheOpenDetail() throws {
        try requireRegularWidth()
        navigate(to: .calls)
        openListRow(A11yID.Calls.row("call-review-01"))
        let detail = element(A11yID.Calls.detailRoot)
        XCTAssertTrue(detail.waitForExistence(timeout: 15), "the call never opened")
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            ensureOrientation(orientation)
            XCTAssertTrue(detail.waitForExistence(timeout: 10), "the open call was lost to a rotation")
            XCTAssertTrue(isSelectedInSidebar(.calls), "Calls stopped being the selected section on a rotation")
        }
        screenshot("IOS-IPAD-01-rotation-keeps-the-call")
    }

    /// ⛔ THE DIALLER COMES THROUGH A ROTATION AND A SECTION SWITCH STILL ANSWERING, and still
    /// refusing what it must. A rotation redraws the columns around the open screen; on a
    /// window that also changes size class (Split View), the same state rebuilds the other
    /// layout, which `ShellNavigationStateTests` pins. A switch away and back rebuilds the screen: an idle
    /// keypad starts again empty, and only a live call is re-attached.
    func test_IOS_IPAD_02_theDiallerSurvivesASectionSwitchAndARotation() throws {
        try requireRegularWidth()
        try XCTSkipUnless(sidebarRows().contains { $0.section == .dialer }, "this role is not offered the dialler")
        navigate(to: .dialer)
        typeTheEmergencyCode()
        ensureOrientation(.landscapeLeft)
        XCTAssertTrue(element(A11yID.Dialer.entry).waitForExistence(timeout: 10), "a rotation closed the dialler")
        XCTAssertTrue(element(A11yID.Dialer.refusal).exists, "a rotation dropped the emergency refusal")
        XCTAssertFalse(element(A11yID.Dialer.call).isEnabled, "Call must stay disabled for an emergency code")
        screenshot("IOS-IPAD-02-dialler-after-rotation")

        navigate(to: .contacts)
        XCTAssertTrue(element(A11yID.Contacts.root).waitForExistence(timeout: 15), "the switch away never landed")
        navigate(to: .dialer)
        let entry = element(A11yID.Dialer.entry)
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "the dialler did not come back")
        XCTAssertFalse(element(A11yID.Dialer.call).isEnabled, "the dialler came back offering a call")
        ensureOrientation(.portrait)
        // ⚠️ ONLY INTO AN EMPTY FIELD: a field that kept the code would read a second one as
        // another number entirely.
        if (entry.value as? String ?? "").isEmpty || entry.value as? String == entry.placeholderValue {
            typeTheEmergencyCode()
        } else {
            XCTAssertTrue(element(A11yID.Dialer.refusal).exists, "the kept code is no longer refused")
        }
        screenshot("IOS-IPAD-02-dialler-after-switch")
    }

    /// ⛔ EXACTLY THE ROWS THE ROLE MAY USE, IN SIDEBAR ORDER, AND NO OTHERS. A role that may
    /// act on the workspace gets all sixteen with no caption; a viewer loses Desk, Dial and
    /// Support (every request behind them refuses a viewer) and sees Workflows, Scheduling and
    /// Workspace settings captioned "Read-only".
    /// ⚠️ THE RUN DOES NOT KNOW THE SESSION'S ROLE, so the dialler row picks which of the two
    /// lists is expected and the captions are then checked against it. A gate that dropped the
    /// dialler while leaving a writer's captions off would fail on the captions.
    func test_IOS_IPAD_03_theSidebarOffersExactlyWhatTheRoleMayUse() throws {
        try requireRegularWidth()
        let rows = sidebarRows()
        let viewerHidden: Set<ShellSection> = [.desk, .dialer, .support]
        let viewerReadOnly: Set<ShellSection> = [.workflows, .scheduling, .settings]
        let writer = rows.contains { $0.section == .dialer }
        let expected = ShellSection.allCases.filter { writer || !viewerHidden.contains($0) }
        XCTAssertEqual(rows.map(\.section), expected, "the sidebar offers a different set of sections from the role's")
        let captioned = Set(rows.filter(\.readOnly).map(\.section))
        XCTAssertEqual(captioned, writer ? [] : viewerReadOnly, "the Read-only captions disagree with the rows")
        screenshot("IOS-IPAD-03-sidebar-rows")
    }

    // MARK: - Support

    /// ⚠️ CHECKED ON SCREEN AFTER THE SESSION: a tab bar is compact width, whatever the device.
    private func requireRegularWidth() throws {
        try requireSession()
        ensureOrientation(.portrait)
        XCTAssertTrue(shellIsUp(timeout: 30), "an injected session must reach the shell")
        try XCTSkipIf(ShellNavigator.isCompact(app), "compact width: a tab bar, so there is no sidebar here")
    }

    /// Tap a row in a list section's content column, showing the column first if the width
    /// has hidden it.
    private func openListRow(_ id: String) {
        let row = element(id).firstMatch
        if !row.waitForExistence(timeout: 10) {
            ShellNavigator.showListColumn(app)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(id) is not in the list")
        row.tap()
    }

    /// ⚠️ TYPED, NOT TAPPED, as ``DialerRefusalTests`` explains.
    private func typeTheEmergencyCode() {
        let entry = element(A11yID.Dialer.entry)
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "no number field on the dialler")
        entry.tap()
        entry.typeText("911")
        XCTAssertTrue(element(A11yID.Dialer.refusal).waitForExistence(timeout: 5), "the emergency code was not refused")
        XCTAssertFalse(element(A11yID.Dialer.call).isEnabled, "Call must stay disabled for an emergency code")
    }

    private func isSelectedInSidebar(_ section: ShellSection) -> Bool {
        ShellNavigator.revealSidebar(app) && ShellNavigator.sidebarRow(app, section).isSelected
    }

    /// Every row the sidebar draws, in order, and whether it carries the "Read-only" caption,
    /// scrolling a sidebar taller than the window and then back to its top.
    ///
    /// ⛔ AN IDENTIFIER THIS LIST DOES NOT KNOW FAILS THE CASE rather than being skipped, because
    /// "no others" is half of what the rows are checked for.
    /// ⚠️ THE CAPTION IS ITS OWN TEXT INSIDE THE ROW'S CELL, which is where a sidebar puts a badge.
    private func sidebarRows() -> [(section: ShellSection, readOnly: Bool)] {
        XCTAssertTrue(ShellNavigator.revealSidebar(app), "the sidebar could not be shown")
        let list = ShellNavigator.sidebarList(app)
        let prefix = NSPredicate(format: "identifier BEGINSWITH %@", ShellNavigator.sidebarPrefix)
        var seen: [(id: String, readOnly: Bool)] = []
        var swipes = 0
        while swipes < 4 {
            let fresh = list.cells.allElementsBoundByIndex
                .sorted { $0.frame.minY < $1.frame.minY }
                .compactMap { cell -> (id: String, readOnly: Bool)? in
                    let row = cell.descendants(matching: .any).matching(prefix).firstMatch
                    guard row.exists else { return nil }
                    return (row.identifier, cell.staticTexts["Read-only"].exists)
                }
                .filter { candidate in !seen.contains { $0.id == candidate.id } }
            guard !fresh.isEmpty else { break }
            seen += fresh
            list.swipeUp()
            swipes += 1
        }
        for _ in 0 ..< swipes {
            list.swipeDown()
        }
        let unknown = seen.map(\.id).filter { ShellSection(sidebarID: $0) == nil }
        XCTAssertTrue(unknown.isEmpty, "the sidebar draws rows this suite does not know: \(unknown)")
        return seen.compactMap { entry in ShellSection(sidebarID: entry.id).map { ($0, entry.readOnly) } }
    }
}
