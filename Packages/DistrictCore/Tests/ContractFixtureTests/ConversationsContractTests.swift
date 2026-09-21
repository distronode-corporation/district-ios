import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the unified Inbox list, and the reply routing
/// ``ConversationSummary`` decides on top of it.
///
/// ⚠️ THE STRICT GATE PROVES THE KEY SET; THESE PROVE THE BRANCHES. See
/// `AuthWorkspaceContractTests`. ⛔ AND THE REPLY PATH IS NOT A COSMETIC
/// BRANCH: it shipped broken on the Kotlin client, where the thread screen used
/// the thread's own identity as the recipient and asked the server to text a
/// cuid. `messages/send` hands `to` straight to the carrier or to Postmark, so
/// it failed at the provider and read as an inbox that could not reply — on the
/// majority of threads, since the server folds every counterpart that resolves
/// to a Contact into that form.
final class ConversationsContractTests: XCTestCase {
    // MARK: - The folded thread

    /// ⛔ THE THREAD MIXES SMS AND EMAIL, AND EVERY FIELD THAT LOOKS LIKE THE
    /// ANSWER IS THE WRONG ONE. `key` is the email address, `kind` is `email`,
    /// `channels` lists both — and the reply still goes out by TEXT, because
    /// `canSms` is server-decided and the contact holds a number. Reading `kind`
    /// or `channels` instead is precisely how the web's reply box decided a
    /// customer who had only ever emailed could not be sent an SMS.
    func testTheFoldedThreadRepliesByTextDespiteAnEmailKind() throws {
        let folded = try conversations().conversations[0]
        XCTAssertEqual(folded.threadKey, "contact:contact_contract_1")
        XCTAssertEqual(folded.key, "ada@contract.test", "the deprecated key is the email, not the thread")
        XCTAssertEqual(folded.kind, MessageChannel.email)
        XCTAssertEqual(Set(folded.channels), [MessageChannel.sms, MessageChannel.email])
        // ⛔ BOTH ADDRESSES FOLD INTO ONE THREAD. A search hit or a deep link on
        // either one has to land on the conversation that is already open.
        XCTAssertEqual(Set(folded.matchKeys), ["14165551234", "ada@contract.test"])

        let target = try XCTUnwrap(folded.replyTarget)
        XCTAssertEqual(target.channel, MessageChannel.sms, "sms wins when the server says both are available")
        XCTAssertEqual(target.to, "14165551234", "the contact's number, not the thread identity")

        XCTAssertEqual(folded.displayName, "Contract Test Caller")
        XCTAssertTrue(folded.hasUnread, "two unread messages")
    }

    // MARK: - The unresolved thread

    /// ⚠️ AN UNRESOLVED ADDRESS **IS** THE IDENTITY OF ITS THREAD, so the title
    /// falls back to the counterpart and never to a placeholder — "Unknown"
    /// would hide the one piece of information available. Row 1 carries four
    /// explicit nulls for exactly this reason: the counterpart matched no
    /// Contact, and the thread is still perfectly usable.
    func testTheUnresolvedThreadUsesItsCounterpartForBothTheTitleAndTheRecipient() throws {
        let unresolved = try conversations().conversations[1]
        XCTAssertNil(unresolved.contactId)
        XCTAssertNil(unresolved.contactName)
        XCTAssertNil(unresolved.contactPhone)
        XCTAssertNil(unresolved.contactEmail)
        XCTAssertTrue(unresolved.threadKey.hasPrefix("addr:"), "no Contact means an address-keyed thread")

        XCTAssertEqual(unresolved.displayName, "+14165558888")
        XCTAssertFalse(unresolved.hasUnread, "nothing unread on this row")

        let target = try XCTUnwrap(unresolved.replyTarget, "canSms is true, so this thread is replyable")
        XCTAssertEqual(target.to, "+14165558888")
        XCTAssertEqual(target.channel, MessageChannel.sms)
    }

    /// ⛔ THE RECIPIENT IS AN ADDRESS, NEVER A THREAD IDENTITY — stated once
    /// across the whole fixture so a row added by a regeneration is covered too.
    /// `messages/send` does not resolve a Contact id; a `contact:` or `addr:`
    /// prefix reaching the carrier fails at the provider and surfaces as a raw
    /// 500.
    func testNoReplyTargetIsEverAThreadIdentity() throws {
        for row in try conversations().conversations {
            guard let target = row.replyTarget else {
                XCTFail("every fixture row is sendable; a nil target means the fixture drifted")
                continue
            }
            XCTAssertNotEqual(target.to, row.threadKey)
            XCTAssertFalse(target.to.hasPrefix("contact:"), "a cuid is not a phone number")
            XCTAssertFalse(target.to.hasPrefix("addr:"), "the prefix is ours, not the carrier's")
            XCTAssertTrue(
                [MessageChannel.sms, MessageChannel.email].contains(target.channel),
                "the channel must be one messages/send branches on"
            )
        }
    }

    /// ⚠️ `scanned == scanLimit` WOULD MEAN THE LIST MAY BE INCOMPLETE. There is
    /// no page to request — the server groups a bounded window of recent
    /// messages — so it is a truthfulness signal rather than an error, and the
    /// fixture deliberately sits well inside the window.
    func testTheScanWindowIsReportedRatherThanPaged() throws {
        let response = try conversations()
        XCTAssertEqual(response.scanLimit, 500)
        XCTAssertLessThan(response.scanned, response.scanLimit, "this fixture is a complete list, not a truncated one")
    }
}

/// The reply-routing branches a committed fixture cannot carry, driven through
/// `Codable` from the wire shape.
///
/// ⚠️ SYNTHETIC BODIES, NOT FIXTURES. Each of these is a real thread shape the
/// server produces; none of them is a response worth committing, because they
/// differ from the two shipped rows only in the field being probed.
final class ReplyTargetTests: XCTestCase {
    /// ⛔ THE PUBLIC INITIALISER EXISTS SO A CONSUMER OUTSIDE `DistrictModel` CAN
    /// REBUILD A TARGET IT IS CARRYING, and it is asserted here because a
    /// synthesised memberwise initialiser would be internal — the app target
    /// would stop compiling with no line in this module having changed.
    ///
    /// ⚠️ ASSERTS THE FIELDS LAND IN THE ORDER THEY ARE LABELLED. Two `String`s
    /// with no type distinction between them is exactly the initialiser whose
    /// arguments can be transposed without the compiler noticing, and the failure
    /// would be an SMS dispatched to the literal string "sms".
    func testATargetCanBeRebuiltOutsideThisModule() {
        let target = ReplyTarget(to: "+14165550134", channel: MessageChannel.sms)
        XCTAssertEqual(target.to, "+14165550134")
        XCTAssertEqual(target.channel, "sms")
    }

    /// ⛔ CANSMS WITH ONLY AN EMAIL IN HAND MUST NOT PAIR THAT EMAIL WITH THE
    /// CARRIER BRANCH, WHICH DOES NO ADDRESS-SHAPE VALIDATION OF ITS OWN. The
    /// counterpart fallback is gated on the `@` test for this one reason, and
    /// with no email channel to fall through to the honest answer is "no reply
    /// box at all".
    func testAnEmailCounterpartIsNeverOfferedAsAnSmsRecipient() throws {
        let row = try thread(counterpart: "ada@example.com", canSms: true)
        XCTAssertNil(row.replyTarget)
    }

    /// ⛔ THE TWO CHECKS ARE SEQUENTIAL, NOT EXCLUSIVE, AND TURNING THEM INTO AN
    /// `else if` IS THE EDIT THAT BREAKS THIS. A thread the server marks
    /// sendable on both channels, whose only usable address is an email, has to
    /// fall THROUGH the SMS branch and reply by email — otherwise a customer who
    /// can be reached becomes one who cannot.
    func testAThreadWithNoUsableNumberFallsThroughToEmail() throws {
        let row = try thread(counterpart: "ada@example.com", canSms: true, canEmail: true)
        let target = try XCTUnwrap(row.replyTarget)
        XCTAssertEqual(target.channel, MessageChannel.email)
        XCTAssertEqual(target.to, "ada@example.com")
    }

    /// ⛔ `canSms`/`canEmail` ARE SERVER-DECIDED AND NOTHING HERE INFERS THEM.
    /// Both false means there is nothing to reply on even with two perfectly
    /// good addresses sitting in the row, and the caller must offer no reply box
    /// rather than a box that 4xxs on send.
    func testAThreadTheServerMarkedUnsendableHasNoTarget() throws {
        let row = try thread(
            counterpart: "+14165550134",
            contactPhone: "+14165550150",
            contactEmail: "ada@example.com"
        )
        XCTAssertNil(row.replyTarget)
    }

    /// ⚠️ SMS IS PREFERRED WHEN BOTH ARE AVAILABLE **AND THE THREAD CARRIES SMS**,
    /// which is the ordinary case for phone threads. The clause that matters is the
    /// one below.
    func testSmsWinsWhenBothAddressesAreStoredOnAnSmsThread() throws {
        let row = try thread(
            contactPhone: "+14165550150",
            contactEmail: "ada@example.com",
            canSms: true,
            canEmail: true
        )
        let target = try XCTUnwrap(row.replyTarget)
        XCTAssertEqual(target.channel, MessageChannel.sms)
        XCTAssertEqual(target.to, "+14165550150", "the stored number wins over the counterpart")
    }

    /// ⛔ THE DEFECT: A THREAD THE CUSTOMER HAS ONLY EVER EMAILED WAS ANSWERED BY
    /// BILLABLE SMS. `canSms` is `contact ? !!contactPhone : ...` server-side, so
    /// a contact with a number on file makes EVERY thread of theirs SMS-sendable,
    /// email-only ones included. The default now follows the thread's own traffic.
    func testAnEmailOnlyThreadDefaultsToEmailEvenWhenSmsIsAvailable() throws {
        let row = try thread(
            contactPhone: "+14165550150",
            contactEmail: "ada@example.com",
            canSms: true,
            canEmail: true,
            channels: [MessageChannel.email]
        )
        let target = try XCTUnwrap(row.replyTarget)
        XCTAssertEqual(target.channel, MessageChannel.email)
        XCTAssertEqual(target.to, "ada@example.com")
    }

    /// ⛔ AND SMS IS STILL OFFERED, WHICH IS WHAT KEEPS THE WEB'S OLD BUG DEAD.
    /// Ordering is a PREFERENCE; sendability stays server-decided, so a customer
    /// who has only ever emailed remains reachable by text.
    func testAnEmailOnlyThreadStillOffersSmsAsTheSecondTarget() throws {
        let row = try thread(
            contactPhone: "+14165550150",
            contactEmail: "ada@example.com",
            canSms: true,
            canEmail: true,
            channels: [MessageChannel.email]
        )
        XCTAssertEqual(row.replyTargets.map(\.channel), [MessageChannel.email, MessageChannel.sms])
    }

    /// ⛔ AND THE PREFERENCE NEVER MANUFACTURES A TARGET. An email-only thread the
    /// server marked `canEmail: false` has no email to answer on, so the order is
    /// irrelevant and SMS is the only thing left.
    func testAnEmailOnlyThreadTheServerWillNotEmailFallsBackToSms() throws {
        let row = try thread(
            contactPhone: "+14165550150",
            contactEmail: "ada@example.com",
            canSms: true,
            channels: [MessageChannel.email]
        )
        XCTAssertEqual(row.replyTargets.map(\.channel), [MessageChannel.sms])
    }

    /// ⚠️ AN EMPTY `channels` DECIDES NOTHING AND MUST NOT. The server accumulates
    /// it from the nullable `Message.type`, so a thread of rows written before that
    /// column existed reports `[]` — an absence of evidence, not evidence of SMS.
    func testAThreadThatReportsNoChannelsKeepsTheSmsFirstOrder() throws {
        let row = try thread(
            contactPhone: "+14165550150",
            contactEmail: "ada@example.com",
            canSms: true,
            canEmail: true,
            channels: []
        )
        XCTAssertEqual(row.replyTargets.map(\.channel), [MessageChannel.sms, MessageChannel.email])
    }

    /// ⚠️ A MIXED THREAD STAYS ON SMS. Both channels are in it, so nothing says the
    /// customer prefers mail, and changing the default there would be this client
    /// guessing rather than following.
    func testAMixedThreadKeepsTheSmsDefault() throws {
        let row = try thread(
            contactPhone: "+14165550150",
            contactEmail: "ada@example.com",
            canSms: true,
            canEmail: true,
            channels: [MessageChannel.sms, MessageChannel.email]
        )
        XCTAssertEqual(row.replyTarget?.channel, MessageChannel.sms)
    }

    /// ⚠️ A THREAD WITH NOTHING TO REPLY ON HAS AN EMPTY LIST, not a list of one
    /// nil — the caller draws no reply box either way, and `first` is what
    /// ``ConversationSummary/replyTarget`` returns.
    func testAnUnsendableThreadHasNoTargetsAtAll() throws {
        XCTAssertTrue(try thread().replyTargets.isEmpty)
    }

    /// ⚠️ A STORED ADDRESS THAT IS ONLY WHITESPACE IS NOT AN ADDRESS. The row
    /// still has a usable counterpart, so the thread stays replyable rather than
    /// dispatching a blank recipient to the carrier.
    ///
    /// ⚠️ AND THE TRIM IS A PROBE, NOT A REWRITE: what goes out is the server's
    /// own string, padding and all. The Kotlin client does the same — a client
    /// that trimmed would be sending an address the server never stored.
    func testABlankStoredAddressFallsBackToTheCounterpart() throws {
        let padded = try thread(counterpart: " +14165550159 ", contactPhone: "   ", canSms: true)
        let target = try XCTUnwrap(padded.replyTarget)
        XCTAssertEqual(target.to, " +14165550159 ")
        XCTAssertEqual(target.channel, MessageChannel.sms)
    }

    /// And a counterpart that is only whitespace is no fallback at all, so the
    /// thread has nothing to reply on.
    func testAWhitespaceCounterpartIsNotAnAddress() throws {
        XCTAssertNil(try thread(counterpart: "   ", canSms: true).replyTarget)
    }

    /// ⚠️ A BLANK `contactName` FALLS BACK THE SAME WAY AN ABSENT ONE DOES.
    /// The column is free text on a row an operator can edit, so "" and "   "
    /// have to behave like null rather than blanking the thread's title.
    func testABlankContactNameFallsBackToTheCounterpart() throws {
        XCTAssertEqual(try thread(counterpart: "+14165550134", contactName: "   ").displayName, "+14165550134")
        XCTAssertEqual(try thread(counterpart: "+14165550134", contactName: "").displayName, "+14165550134")
        XCTAssertEqual(try thread(counterpart: "+14165550134", contactName: "Ada").displayName, "Ada")
    }

    /// ``ConversationSummary/hasUnread`` is the badge, and zero is the ordinary
    /// state of a thread somebody already opened.
    func testUnreadIsACountAndZeroIsRead() throws {
        XCTAssertFalse(try thread(unreadCount: 0).hasUnread)
        XCTAssertTrue(try thread(unreadCount: 1).hasUnread)
    }

    /// ⛔ `Hashable` IS A REQUIREMENT RATHER THAN A NICETY, AND THIS IS WHAT SAYS SO.
    /// `Route.thread` carries the whole ORDERED SET of reply targets so the composer
    /// can OFFER a channel instead of merely naming one, and a `Route` has to be
    /// `Hashable` because `NavigationPath` demands it. Dropping this conformance
    /// breaks navigation in the App target, which is a tier with no test lane at all
    /// — so the assertion lives here, on the tier that can run.
    ///
    /// ⚠️ THE CONFORMANCE IS SYNTHESISED (both stored properties are `String`), so
    /// there is no hand-written `hash(into:)` that can drift from `==`. What is worth
    /// pinning is that the CHANNEL participates: two targets sharing an address and
    /// differing only in channel are the exact pair a picker offers, and collapsing
    /// them would silently drop one of the two choices from a `Set`.
    func testAReplyTargetHashesOnBothHalvesSoAPickerCannotLoseAChoice() {
        let sms = ReplyTarget(to: "+14165550134", channel: MessageChannel.sms)
        let email = ReplyTarget(to: "+14165550134", channel: MessageChannel.email)

        XCTAssertNotEqual(sms, email)
        // ⚠️ THE SET IS THE ASSERTION AND `hashValue` IS DELIBERATELY NOT COMPARED.
        // Swift seeds `String` hashing per process, so two distinct values are not
        // GUARANTEED to hash differently — an inequality assertion on `hashValue`
        // would be a test that can only fail by luck. Set membership is the behaviour
        // anything downstream actually depends on.
        XCTAssertEqual(Set([sms, email, sms]).count, 2)
        XCTAssertEqual(sms, ReplyTarget(to: "+14165550134", channel: MessageChannel.sms))
    }

    /// ⚠️ AND THE ADDRESS PARTICIPATES TOO, which is the mirror of the case above and
    /// the one a channel-keyed dictionary would break: one thread can offer two SMS
    /// targets in principle (a contact's stored number and the counterpart it was
    /// reached on), and they are not the same destination.
    func testAReplyTargetOnOneChannelStillDistinguishesTwoAddresses() {
        let stored = ReplyTarget(to: "+14165550134", channel: MessageChannel.sms)
        let reached = ReplyTarget(to: "+14165550159", channel: MessageChannel.sms)

        XCTAssertNotEqual(stored, reached)
        XCTAssertEqual(Set([stored, reached]).count, 2)
    }
}

// MARK: - Helpers

/// The Inbox list fixture, through the strict gate so these tests never read a
/// shape the gate has not already blessed.
private func conversations() throws -> ConversationsResponse {
    try StrictDecodeVerifier.verify(
        fixture: "district-conversations.json",
        as: ConversationsResponse.self
    )
}

/// One synthetic thread in the server's own wire shape.
///
/// ⚠️ THE DEFAULTS ARE THE UNSENDABLE CASE. `canSms` and `canEmail` are
/// server-decided, so a test that wants a replyable thread has to say which
/// channel the server allowed — the same way the row itself does.
private func thread(
    counterpart: String = "+14165550134",
    contactName: String? = nil,
    contactPhone: String? = nil,
    contactEmail: String? = nil,
    canSms: Bool = false,
    canEmail: Bool = false,
    channels: [String] = [MessageChannel.sms],
    unreadCount: Int = 0
) throws -> ConversationSummary {
    let channelList = channels.map { "\"\($0)\"" }.joined(separator: ",")
    return try decode(
        ConversationSummary.self,
        from: #"""
        {"key":"k","threadKey":"contact:contact_contract_1",
         "counterpart":"\#(counterpart)","matchKeys":[],
         "kind":"sms","channels":[\#(channelList)],"contactId":"contact_contract_1",
         "contactName":\#(jsonString(contactName)),
         "contactEmail":\#(jsonString(contactEmail)),
         "contactPhone":\#(jsonString(contactPhone)),
         "canSms":\#(canSms),"canEmail":\#(canEmail),
         "lastMessage":{"body":"Is this the roofing company?","direction":"inbound",
                        "type":"sms","status":"received",
                        "createdAt":"2026-08-15T13:10:00.000Z"},
         "unreadCount":\#(unreadCount),"totalMessages":1}
        """#
    )
}

/// `"value"` or `null`, so an unresolved contact field is written the way the
/// server writes it — an explicit null rather than an omitted key.
private func jsonString(_ value: String?) -> String {
    guard let value else { return "null" }
    return "\"\(value)\""
}
