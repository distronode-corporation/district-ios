import XCTest

/// The Guideline 1.2 walk: the terms before sign-in, the flag on a conversation, and
/// the block on the caller who wrote it.
///
/// ⛔ ITS OWN CLASS AND THEREFORE ITS OWN VIDEO, NOT MORE STEPS ON
/// ``ReviewRecordingTests``. The moderation demo stands on its own, and the 2.1
/// walk is a fifteen-minute product tour — a reviewer looking for a flag and a
/// block should not have to find them inside it. Run
/// it alone with
/// `-only-testing:DistrictAIUITests/ReviewRecordingModerationTests`.
/// ⚠️ The split is also forced by SwiftLint's 500-line `file_length` ceiling. See
/// ``ReviewRecordingCase``.
///
/// ⛔ THE BLOCK HAPPENS IN ONE OF TWO PLACES AND THE CHOICE IS MADE FROM THE DATA ON
/// THE DAY, WHICH IS WHY THIS WALK IS NOT A FIXED SHOT LIST. Blocking from the thread
/// is the stronger recording — Apple asks that blocking "remove it from the user's
/// feed instantly" and only that branch shows a conversation leaving the list — but a
/// thread exists only where real telephony has happened, and the demo workspace's
/// fictional `+1 555 01xx` callers may have none. So the thread branch is taken when
/// a fictional, `contact:`-keyed conversation is on screen and the Contacts branch is
/// taken otherwise; **both** block a fictional row and nothing else, and both end in
/// a verified unblock. ⛔ It never falls back to "the first row": a skipped read must
/// abort, never fall through to an action anyway.
final class ReviewRecordingModerationTests: ReviewRecordingCase {
    /// The fragment that must appear on a row before this harness will block it.
    ///
    /// ⛔ THE GUARD THAT KEEPS THIS WALK SAFE, AND IT IS THE DATA RATHER THAN THE
    /// IDENTIFIER. The block and unblock controls are deliberately NOT in
    /// `UITestApp.forbiddenSurfaces` — the whole point of the recording is a test
    /// tapping them, and the route takes the desired STATE so an unblock puts the row
    /// back. What stops a real customer being blocked on camera is that the review
    /// workspace's seed puts every review contact in the reserved
    /// NANP `555-0100…0199` range, and nothing is ever blocked that does not either
    /// carry this fragment in its label or come from that seed by id (see
    /// ``seededContactPrefix``). A row that satisfies neither is somebody real, and
    /// the walk fails rather than touching it.
    ///
    /// ⚠️ OVERRIDABLE, so the operator can name one demo contact exactly rather than
    /// relying on the range. ⛔ Whatever it is set to is what gets blocked: it is the
    /// one place a real caller could be named, so set it to a number you have read
    /// off the Contacts tab and nothing else.
    private var blockFragment: String {
        ProcessInfo.processInfo.environment["REVIEW_BLOCK_CONTACT"] ?? "555"
    }

    /// The contact-id prefix the review seed writes.
    ///
    /// ⛔ THE FIRST-CHOICE GUARD, AND IT IS STRONGER THAN THE LABEL MATCH BECAUSE AN
    /// INBOX ROW DOES NOT SHOW A NUMBER. A conversation row's title is the CONTACT'S
    /// NAME when the thread resolved to one and its subtitle is the last message body
    /// (`ConversationDisplay.init`), so `label CONTAINS "555"` matches a conversation
    /// only when the caller never resolved to a contact — which is the one kind this
    /// walk must NOT block from, because the store cannot filter it out at once. Read
    /// off the source rather than assumed, and it is why the label tier alone would
    /// have found nothing to do in the seeded workspace and the wrong thing in any
    /// other.
    ///
    /// ⚠️ The review workspace's seed writes twenty contacts at fixed ids
    /// (`ct-review-01`…), every number in the reserved NANP `555-0100…0199` range and
    /// every address `@example.com`, with threads on the first several — so
    /// `contact:ct-review-` names a fictional caller from the identifier alone, the
    /// way `AuthenticatedTests` already addresses `ct-review-01`. ⛔ It is the seed's
    /// CONVENTION and no server test pins the prefix; the fragment tier below is what
    /// covers a workspace seeded some other way, where an auto-registered caller is
    /// named by their own number and the label therefore carries it.
    private static let seededContactPrefix = "ct-review-"

    /// The walk itself.
    ///
    /// The shot list, in order: launch → the sign-in screen with the terms line (and
    /// the Terms page opening) → sign in → a conversation → Manage, which shows the
    /// flag and the block together → Report, and its confirmation → the block, from
    /// the thread if the data allows it and from the contact otherwise → the Blocked
    /// badge in Contacts → Unblock.
    ///
    /// ⛔ IT LEAVES THE WORKSPACE AS IT FOUND IT. The unblock at the end is not a
    /// courtesy: a demo workspace whose conversation is with a blocked caller shows
    /// an empty Inbox to the next reviewer, and the route takes a STATE so the
    /// reversal is exact. The last assertion in the walk is that the badge is gone.
    ///
    /// ⚠️ THE ONE THING IT LEAVES BEHIND IS A SUPPORT TICKET, deliberately and
    /// unavoidably (see ``setUp``). It carries "(review recording)" in its subject.
    func test_reviewWalkUserGeneratedContent() throws {
        try XCTSkipIf(
            email.isEmpty || password.isEmpty,
            "REVIEW_EMAIL / REVIEW_PASSWORD missing"
        )

        allowSystemAlerts()

        app.launch()
        showTermsBeforeSignIn()
        signIn()
        let blockable = openAConversation()
        reportTheConversation()
        let blocked = blockFromTheThread(blockable)
        blockAndUnblockInContacts(alreadyBlocked: blocked)
    }

    /// Steps 1 and 2: the sign-in gate, its terms line, and the Terms page opening.
    ///
    /// ⛔ THE LINE IS ASSERTED AND THE LINK IS TAPPED, AND BOTH HALVES ARE THE POINT.
    /// Guideline 1.2 asks that the terms be PRESENTED before sign-in; a reviewer
    /// watching a video needs to see both that the sentence is there and that it goes
    /// somewhere. The tap leaves for Safari and comes back, exactly as
    /// ``ReviewRecordingTests``' account-deletion step does.
    private func showTermsBeforeSignIn() {
        XCTAssertTrue(any(A11yID.SignIn.root).waitForExistence(timeout: 40), "sign-in gate")
        XCTAssertTrue(any(A11yID.SignIn.terms).waitForExistence(timeout: 10), "terms line")
        pause(4)
        any(A11yID.SignIn.termsLink).tap()
        pause(6)
        app.activate()
        pause(3)
        XCTAssertTrue(any(A11yID.SignIn.terms).waitForExistence(timeout: 20), "terms line after returning")
        pause(2)
    }

    /// Step 3: sign in for real, through the server's own login surface.
    private func signIn() {
        // ⚠️ ONE RETRY, because the code exchange is fail-open on the server's side:
        // a server instance whose code store is briefly unavailable loses the
        // authorization code, and the app answers "That sign-in expired" on an
        // otherwise perfect web leg. The web session survives the first attempt, so the retry lands on
        // the handoff page directly.
        for attempt in 0 ..< 2 {
            any(A11yID.SignIn.button).tap()
            let consent = springboard.buttons["Continue"]
            if consent.waitForExistence(timeout: 12) {
                consent.tap()
            }
            signInOnWeb()
            if ShellNavigator.shellIsUp(in: app, timeout: 60) {
                break
            }
            if attempt == 0, any(A11yID.SignIn.button).waitForExistence(timeout: 10) {
                pause(2)
                continue
            }
        }
        XCTAssertTrue(ShellNavigator.shellIsUp(in: app, timeout: 30), "shell")
        pause(3)
    }

    /// Step 4: open a conversation, preferring one this walk may also block.
    ///
    /// ⛔ THE RETURN VALUE IS A PERMISSION, NOT A ROW. It is non-nil only for a
    /// conversation that is BOTH a fictional caller's and `contact:`-keyed, which are
    /// two separate requirements: the fragment is what keeps a real customer from
    /// being blocked on camera, and the key is what makes the thread leave the list
    /// at once — `BlockedContactsStore.isBlocked(conversation:)` answers false for an
    /// `addr:`-keyed thread by design, so blocking one is correct and invisible until
    /// the server's own filter is read again. Asserting an absence that cannot happen
    /// for another refresh would red the take for a product that behaved properly.
    ///
    /// ⚠️ A conversation is still OPENED and FLAGGED either way: reporting quotes no
    /// content and files into our own queue, so it is safe on any thread.
    private func openAConversation() -> XCUIElement? {
        ShellNavigator.navigate(app, to: .inbox)
        XCTAssertTrue(any(A11yID.Inbox.root).waitForExistence(timeout: 30), "inbox")
        pause(3)

        let blockable = blockableRow()
        guard let row = blockable ?? firstRow(A11yID.Inbox.rowBase) else {
            XCTFail("the inbox has no conversation to flag")
            return nil
        }
        // ⚠️ READ BEFORE THE TAP. The identifier is how the block step proves the row
        // is gone, and an element queried after a pop resolves to nothing.
        let identifier = row.identifier
        XCTAssertTrue(openRow(row, expecting: A11yID.Inbox.threadRoot), "thread")
        pause(4)
        app.swipeUp(); pause(2); app.swipeDown(); pause(2)
        guard blockable != nil else { return nil }
        return app.descendants(matching: .any)[identifier]
    }

    /// Step 5: flag the conversation, and show the flag being accepted.
    ///
    /// ⚠️ THE MENU IS THE SHOT THAT CARRIES BOTH MECHANISMS. Report and Block sit in
    /// it together, so the frame where it opens is where a reviewer sees that the
    /// block exists on the content surface itself — which matters most in the branch
    /// where the block is then performed on the contact.
    private func reportTheConversation() {
        any(A11yID.Inbox.threadMenu).tap()
        pause(2)
        XCTAssertTrue(any(A11yID.Inbox.threadBlock).waitForExistence(timeout: 10), "Block caller in the menu")
        pause(2)
        any(A11yID.Inbox.threadReport).tap()
        XCTAssertTrue(any(A11yID.Report.root).waitForExistence(timeout: 15), "report sheet")
        pause(3)

        let note = any(A11yID.Report.note)
        if note.waitForExistence(timeout: 5) {
            note.tap()
            pause(1)
            note.typeText("Abusive language from this caller.")
            pause(2)
        }
        any(A11yID.Report.submit).tap()
        // ⛔ THE CONFIRMATION IS THE EVIDENCE. A sheet that dismissed itself on success
        // would be indistinguishable on video from one that failed.
        XCTAssertTrue(
            any(A11yID.Report.confirmation).waitForExistence(timeout: 45),
            "report confirmation"
        )
        pause(5)
        app.buttons["Done"].tap()
        pause(2)
    }

    /// Step 6, when the data allows it: block the caller and show the conversation
    /// leaving the list. Answers whether the block actually landed.
    ///
    /// ⛔ THE ABSENCE IS ASSERTED, NOT THE TAP. Apple's ask is that blocking remove the
    /// content from view; a passing tap proves the write, and only the row's
    /// disappearance proves the requirement.
    ///
    /// ⛔ IT RETURNS THE ABSENCE RATHER THAN `true`, so a block that did not take hands
    /// the Contacts step a truthful "nothing is blocked yet" and that step performs
    /// the block itself. Returning an optimistic `true` would leave the walk asserting
    /// a badge that was never written and then trying to unblock a row that was never
    /// blocked.
    private func blockFromTheThread(_ row: XCUIElement?) -> Bool {
        guard let row else {
            // No fictional `contact:`-keyed conversation here, so this thread is left
            // exactly as it was found and the block is demonstrated on the contact.
            back()
            pause(2)
            return false
        }
        any(A11yID.Inbox.threadMenu).tap()
        pause(2)
        any(A11yID.Inbox.threadBlock).tap()
        pause(3)
        app.buttons["Block"].tap()

        XCTAssertTrue(any(A11yID.Inbox.root).waitForExistence(timeout: 30), "back on the inbox list")
        pause(2)
        // ⚠️ POLLED RATHER THAN CHECKED ONCE. The pop and the list's re-render are two
        // frames apart, and `exists` immediately after the dialog is a race.
        let gone = waitForAbsence(of: row, timeout: 20)
        XCTAssertTrue(gone, "the blocked thread is still in the list")
        pause(4)
        return gone
    }

    /// Steps 7 and 8: the block (if it has not happened yet), the Blocked badge in
    /// Contacts, and the unblock that restores the workspace.
    ///
    /// ⛔ THE UNBLOCK IS THE LAST THING THE WALK DOES AND IT IS ASSERTED. A take that
    /// ended after the block would leave the demo workspace hiding a conversation from
    /// the next reviewer.
    private func blockAndUnblockInContacts(alreadyBlocked: Bool) {
        ShellNavigator.navigate(app, to: .contacts)
        XCTAssertTrue(any(A11yID.Contacts.root).waitForExistence(timeout: 30), "contacts")
        pause(3)

        if alreadyBlocked {
            // ⚠️ ASSERTED BY PREFIX, because this walk knew a thread key and never
            // learned the contact id — the server resolves one to the other. Any badge
            // present is the badge for the caller just blocked: the demo workspace
            // starts with none.
            XCTAssertTrue(blockedRowBadge().waitForExistence(timeout: 30), "Blocked badge on the contact row")
            pause(5)
        } else {
            blockOnTheContact()
        }

        unblockOnTheContact()
    }

    /// The Contacts-tab block: the badge appears on the detail header and then on the
    /// list row, which is the cross-screen half of "immediately".
    private func blockOnTheContact() {
        guard let contact = blockableContactRow() else {
            XCTFail(
                "no contact row is seeded (\(Self.seededContactPrefix)) or carries "
                    + "\(blockFragment) — nothing safe to block, so nothing was blocked"
            )
            return
        }
        XCTAssertTrue(openRow(contact, expecting: A11yID.Contacts.detailRoot), "contact detail")
        pause(3)

        // ⚠️ IF THIS FAILS TO FIND THE CONTROL, THE ROW IS ALREADY BLOCKED — the
        // identifier flips with the state — and the unblock step below still restores
        // the workspace. That is the direction to fail in.
        let block = scrolledInto(A11yID.Contacts.block)
        XCTAssertTrue(block.waitForExistence(timeout: 15), "Block caller")
        block.tap()
        pause(3)
        app.buttons["Block"].tap()
        XCTAssertTrue(any(A11yID.Contacts.blockedBadge).waitForExistence(timeout: 30), "Blocked badge on the detail")
        pause(5)

        back()
        XCTAssertTrue(blockedRowBadge().waitForExistence(timeout: 30), "Blocked badge on the contact row")
        pause(5)
    }

    /// The restore, from the contact's own screen.
    private func unblockOnTheContact() {
        // ⚠️ THE BADGE FIRST, BECAUSE IT NAMES THE ROW THE SERVER ACTUALLY BLOCKED.
        // See the ⛔ on ``blockedContactRow()``.
        guard let contact = blockedContactRow() ?? blockableContactRow() else {
            XCTFail("cannot re-open the blocked contact — the workspace is LEFT BLOCKED, unblock it by hand")
            return
        }
        XCTAssertTrue(openRow(contact, expecting: A11yID.Contacts.detailRoot), "contact detail")
        XCTAssertTrue(any(A11yID.Contacts.blockedBadge).waitForExistence(timeout: 15), "Blocked badge")
        pause(4)

        let unblock = scrolledInto(A11yID.Contacts.unblock)
        XCTAssertTrue(unblock.waitForExistence(timeout: 15), "Unblock caller")
        unblock.tap()
        pause(3)
        app.buttons["Unblock"].tap()
        pause(4)
        // ⛔ THE RESTORE IS VERIFIED. A walk that tapped Unblock and did not check
        // would leave the demo workspace showing an empty Inbox to the next reviewer.
        XCTAssertTrue(
            waitForAbsence(of: any(A11yID.Contacts.blockedBadge), timeout: 20),
            "the contact still reads as blocked"
        )
        pause(3)
    }
}

// MARK: - Demo-data guards

private extension ReviewRecordingModerationTests {
    /// An inbox row this walk may block from the thread: a fictional caller AND a
    /// `contact:`-keyed conversation. See the ⛔ on ``openAConversation()``.
    ///
    /// ⚠️ SEEDED IDS FIRST, LABEL SECOND, and neither tier will match a row that is
    /// not demonstrably a fictional caller's. See the ⛔ on ``seededContactPrefix``.
    func blockableRow() -> XCUIElement? {
        firstWithPrefix(A11yID.Inbox.row("contact:\(Self.seededContactPrefix)"))
            ?? firstMatching(prefix: A11yID.Inbox.row("contact:"), labelContaining: blockFragment)
    }

    /// The fictional caller's contact row: seeded id, then the label match. A contact
    /// row DOES show a number (`ContactsView.subtitle(for:title:)`), so the label tier
    /// is a real guard here, unlike on a conversation.
    func blockableContactRow() -> XCUIElement? {
        firstWithPrefix(A11yID.Contacts.row(Self.seededContactPrefix))
            ?? firstMatching(prefix: A11yID.Contacts.rowBase, labelContaining: blockFragment)
    }

    /// The row the Blocked badge names.
    ///
    /// ⛔ THE ONLY EXACT WAY BACK TO A CALLER A **THREAD** BLOCK CHOSE, AND IT ONLY
    /// WORKS BECAUSE THE BADGE CARRIES THE CONTACT ID. That branch knew a thread key
    /// and never learned the id — the server resolves one to the other — so a walk
    /// that unblocked "the first fictional row" could restore a different contact and
    /// leave the blocked one blocked. The badge's identifier is
    /// `blockedRowBase-<contactId>`, which is `rowBase-<contactId>` with one
    /// substitution.
    func blockedContactRow() -> XCUIElement? {
        let badge = blockedRowBadge()
        guard badge.waitForExistence(timeout: 5) else { return nil }
        let identifier = badge.identifier.replacingOccurrences(
            of: A11yID.Contacts.blockedRowBase,
            with: A11yID.Contacts.rowBase
        )
        let row = any(identifier)
        return row.waitForExistence(timeout: 10) ? row : nil
    }

    /// The first element whose identifier starts with `prefix`, or nil.
    ///
    /// ⚠️ A SHORT WAIT, BECAUSE A MISS IS AN ORDINARY OUTCOME AND THIS IS A VIDEO. The
    /// list is asserted on screen before either guard runs, so whatever rows exist
    /// exist now; `ReviewRecordingCase.firstRow(_:)`'s ten seconds would be ten
    /// seconds of a motionless screen in the take for every workspace without seeded
    /// data.
    func firstWithPrefix(_ prefix: String) -> XCUIElement? {
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
        return first.waitForExistence(timeout: 3) ? first : nil
    }

    /// Any "Blocked" badge on a contact LIST row.
    ///
    /// ⚠️ THE PREFIX ORDER IS LOAD-BEARING and documented on
    /// ``A11yID/Contacts/blockedRowBase``: `district-contact-blocked-row` does not
    /// begin with `district-contact-row`, so the badge and the row are disjoint
    /// namespaces and `firstMatch` cannot hand this walk a badge to tap as a row.
    func blockedRowBadge() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", A11yID.Contacts.blockedRowBase))
            .firstMatch
    }

    /// ⚠️ BOTH CONDITIONS IN ONE PREDICATE. Filtering by prefix and then scanning
    /// labels in Swift walks the accessibility tree twice and is measurably slower on
    /// a handset, which on a recording shows up as a pause nobody chose.
    func firstMatching(prefix: String, labelContaining fragment: String) -> XCUIElement? {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", prefix, fragment)
        )
        let first = query.firstMatch
        return first.waitForExistence(timeout: 15) ? first : nil
    }

    /// Scroll a control into reach and answer it.
    ///
    /// ⚠️ THE CONTACT DETAIL IS LONGER THAN A HANDSET SCREEN and the moderation
    /// control sits between Rename and Delete, so it is below the fold on every
    /// contact that has a dossier.
    func scrolledInto(_ identifier: String) -> XCUIElement {
        let element = any(identifier)
        var swipes = 0
        while !element.isHittable, swipes < 6 {
            app.swipeUp(); swipes += 1; pause(1)
        }
        return element
    }

    /// ⚠️ A POLL, BECAUSE `XCUIElement` HAS NO `waitForNonExistence` ON THIS
    /// TOOLCHAIN and `!exists` read once is a race against the frame the pop lands on.
    func waitForAbsence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            pause(0.5)
        }
        return !element.exists
    }
}
