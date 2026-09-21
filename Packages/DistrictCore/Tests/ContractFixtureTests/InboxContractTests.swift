import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the inbox composer (drafts, sends, attachments),
/// contact enrichment and the workspace call directory.
///
/// ⚠️ THE STRICT GATE PROVES THE KEY SET; THESE PROVE THE BRANCHES. See
/// `AuthWorkspaceContractTests` for the full statement of why both exist.
final class InboxContractTests: XCTestCase {
    // MARK: - Drafts: persistence versus generation

    /// ⛔ ONE LETTER APART AND ONE OF THEM SPENDS MONEY, AND THE KEY NAME THEY
    /// SHARE IS THE TRAP. `messages/drafts` answers `draft` as an OBJECT;
    /// `messages/draft` answers `draft` as a STRING and bills a Vertex
    /// generation for it. Both are asserted in one test so the difference cannot
    /// be read as an inconsistency in the fixtures.
    func testDraftIsAnObjectOnThePluralRouteAndAStringOnTheBilledOne() throws {
        let persisted = try StrictDecodeVerifier.verify(
            fixture: "district-draft.json",
            as: DraftResponse.self
        )
        XCTAssertTrue(persisted.success)
        XCTAssertEqual(persisted.draft?.threadKey, "contact:contact_contract_1")
        // ⛔ Never blank on a row that exists: the route refuses to store one.
        XCTAssertFalse(persisted.draft?.body.isEmpty ?? true)
        XCTAssertEqual(persisted.draft?.subject, "Re: Thursday appointment")
        XCTAssertEqual(persisted.draft?.mediaUrls.count, 1)

        // The PUT echoes the stored row, so it is the same shape rather than a
        // receipt — which is what makes a re-read after autosave unnecessary.
        let saved = try StrictDecodeVerifier.verify(
            fixture: "district-draft-put.json",
            as: DraftResponse.self
        )
        XCTAssertEqual(saved.draft?.threadKey, persisted.draft?.threadKey)
        XCTAssertEqual(saved.draft?.updatedAt, persisted.draft?.updatedAt)

        let generated = try StrictDecodeVerifier.verify(
            fixture: "district-ai-draft.json",
            as: AiDraftResponse.self
        )
        XCTAssertFalse(generated.draft.isEmpty)
    }

    /// ⛔ `draft: null` IS THE ORDINARY ANSWER, NOT AN ERROR, WHICH IS WHY THE
    /// FIELD IS OPTIONAL. `district-draft-null.json` pins it through an allowlisted
    /// null, and the branch is also decoded here from the bytes that route emits.
    func testAnAbsentDraftIsNullRatherThanA404() throws {
        let none = try decode(DraftResponse.self, from: #"{"success":true,"draft":null}"#)
        XCTAssertTrue(none.success)
        XCTAssertNil(none.draft, "almost every thread has no draft; a 404 would log the common path as a fault")
    }

    /// ⚠️ AN SMS DRAFT'S `subject` ARRIVES AS AN EXPLICIT NULL, which is the one
    /// field keeping `district-drafts-list.json` out of the gate. Asserted on the
    /// type so the optionality is not left resting on a fixture nobody can wire
    /// in.
    func testAnSmsDraftCarriesAnExplicitlyNullSubject() throws {
        let row = try decode(
            MessageDraft.self,
            from: #"""
            {"threadKey":"addr:14165550158","body":"Following up on your quote.",
             "subject":null,"mediaUrls":[],"updatedAt":"2026-08-15T09:00:00.000Z"}
            """#
        )
        XCTAssertNil(row.subject)
        XCTAssertTrue(row.mediaUrls.isEmpty, "always an array on the wire, never omitted and never null")
        XCTAssertTrue(row.threadKey.hasPrefix("addr:"), "an unresolved counterpart keys by address, not by contact")
    }

    /// The DELETE is idempotent and echoes nothing at all, so it shares the bare
    /// acknowledgement type. Deleting a draft that is not there succeeds, because
    /// the caller's goal state is "no draft" and that is already true.
    func testDraftDeleteIsABareAcknowledgement() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-draft-delete.json",
            as: SuccessResponse.self
        )
        XCTAssertTrue(response.success)
    }

    // MARK: - Sending

    /// ⛔ ONE ENDPOINT, TWO KEY SETS, AND ONLY BOTH FIXTURES TOGETHER PROVE THE
    /// OPTIONALITY. The strict gate compares key sets per fixture, so a type
    /// proven against the SMS branch alone would have `subject` looking absent
    /// forever and one proven against email alone would lose `externalId` and
    /// `accountId`.
    func testSendCoversBothChannelBranches() throws {
        let sms = try StrictDecodeVerifier.verify(
            fixture: "district-message-send.json",
            as: SendMessageResponse.self
        )
        XCTAssertTrue(sms.success)
        XCTAssertEqual(sms.message.type, MessageChannel.sms)
        XCTAssertEqual(sms.message.provider, "twilio")
        XCTAssertNil(sms.message.subject, "the SMS branch omits the key entirely")
        XCTAssertNotNil(sms.message.externalId)
        XCTAssertNotNil(sms.message.accountId)
        // ⚠️ THE PROVIDER'S WORD, NOT A NORMALISED ONE. Twilio says `queued`
        // where Postmark says `sent`, for the same successful send.
        XCTAssertEqual(sms.message.status, "queued")

        let email = try StrictDecodeVerifier.verify(
            fixture: "district-message-send-email.json",
            as: SendMessageResponse.self
        )
        XCTAssertEqual(email.message.type, MessageChannel.email)
        XCTAssertEqual(email.message.provider, "postmark")
        XCTAssertEqual(email.message.subject, "Re: Thursday appointment")
        XCTAssertNil(email.message.externalId, "the email branch sends neither carrier field")
        XCTAssertNil(email.message.accountId)
        XCTAssertEqual(email.message.status, "sent")

        // ⚠️ `from` IS THE WORKSPACE, `to` IS THE CUSTOMER. Both rows are
        // outbound; labelling a bubble with `from` attributes the operator's own
        // reply to itself.
        XCTAssertEqual(sms.message.direction, "outbound")
        XCTAssertEqual(email.message.direction, "outbound")
        XCTAssertTrue(email.message.from.contains("@"))
        XCTAssertTrue(email.message.to.contains("@"))
    }

    /// ⚠️ THE MMS BRANCH IS THE SMS BRANCH ON THE WIRE. The attachment changes
    /// what the carrier bills and nothing about the echoed row, so the fixture
    /// exists to prove that rather than to introduce a third shape.
    func testMediaSendIsTheSmsShape() throws {
        let mms = try StrictDecodeVerifier.verify(
            fixture: "district-message-send-media.json",
            as: SendMessageResponse.self
        )
        XCTAssertEqual(mms.message.type, MessageChannel.sms)
        XCTAssertNil(mms.message.subject)
        XCTAssertNotNil(mms.message.messageSid)
        XCTAssertEqual(MessageChannel.whatsapp, "whatsapp")
    }

    /// ⚠️ ZERO IS A SUCCESS, the same shape as a device revoke. A thread another
    /// agent already opened marks nothing — the ordinary race, not a failure.
    /// ⛔ And the route excludes `viewer`, so the call has to be gated in the UI
    /// or a read-only seat gets a permanent badge plus an error on every tap.
    func testMarkReadIsACount() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-message-mark-read.json",
            as: MarkReadResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.marked, 3)
        XCTAssertFalse(WorkspaceRole.viewer.canMutate, "a viewer must not be offered the call at all")
    }

    // MARK: - One message id, resolved into a thread

    /// ⛔ THE RESOLVER THAT MAKES A MESSAGE PUSH ACTIONABLE, AND THE THREE VOCABULARIES
    /// IT HAS TO ANSWER AT ONCE. A push carries `{type, category, workspaceId,
    /// messageId}` and every endpoint on this surface is addressed by THREAD:
    /// `mark-read` takes `contactId` or `counterpart`, `send` takes `to` plus a
    /// `channel`, `drafts` takes a `threadKey`. This fixture is the record that one
    /// answer serves all three.
    ///
    /// ⛔ AND `body`/`subject` ARE ABSENT BY DESIGN RATHER THAN UNMODELLED. The thread
    /// target is routing information; content is what `timeline` serves once a thread
    /// has been chosen, which is what keeps a resolver a notification-service
    /// extension may call from becoming a second content API. The strict gate proves
    /// the absence: an added key fails as loudly as a dropped one, so the day this
    /// route starts echoing a body, this fixture reds.
    ///
    /// ⚠️ `readAt: null` IS THE ORDINARY STATE HERE, not an edge — the notification
    /// exists because nobody has read the message yet — and it is the fixture's one
    /// allowlisted path.
    func testTheThreadTargetAnswersEveryInboxVocabularyAtOnce() throws {
        let resolved = try StrictDecodeVerifier.verify(
            fixture: "district-message-thread.json",
            as: MessageThreadResponse.self
        )
        XCTAssertTrue(resolved.success)
        // The drafts table's key, in the server's own form.
        XCTAssertEqual(resolved.thread.threadKey, "contact:contact_contract_1")
        // `mark-read`'s and `timeline`'s selector, preferred over the address.
        XCTAssertEqual(resolved.thread.contactId, "contact_contract_1")
        // `send`'s `to` plus its `channel`. ⛔ The counterpart is the UNWRAPPED
        // address — the route runs `normalizeAddress` so a display-name-wrapped
        // `from` cannot reach a carrier.
        XCTAssertEqual(resolved.thread.counterpart, "+14165551234")
        XCTAssertEqual(resolved.thread.channel, MessageChannel.sms)
        // ⚠️ Unread, which is why a push was sent at all.
        XCTAssertNil(resolved.message.readAt)
        XCTAssertEqual(resolved.message.direction, "inbound")
    }

    // MARK: - Attachments

    /// ⛔ THE URL IS AN ANONYMOUS CAPABILITY AND MUST NOT BE FETCHED WITH THE
    /// BEARER TOKEN. It answers to anyone because a carrier's MMS fetcher has no
    /// session; attaching `Authorization` would send an access token to a route
    /// that does not need one.
    func testMediaUploadReturnsACapabilityUrlAndTheServersOwnSize() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-media-upload.json",
            as: MediaUploadResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertTrue(response.media.url.contains("/api/media/"))
        // The URL is nothing but the id on a server-controlled origin, which is
        // why the id is a uuid in production rather than a guessable sequence.
        XCTAssertTrue(response.media.url.hasSuffix(response.media.id))
        XCTAssertEqual(response.media.mimeType, "image/png")
        // ⚠️ The server's count, which is the one the carrier bills on.
        XCTAssertGreaterThan(response.media.sizeBytes, 0)
    }

    // MARK: - Enrichment and the call directory

    /// ⛔ A 200 HERE MEANS "ACCEPTED", NOT "ENRICHED", and the dossier is not in
    /// this body at all. The status is stamped before the response returns, which
    /// is what lets a client tell "queued" from "the button did nothing".
    func testEnrichAnswersPendingRatherThanADossier() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-enrich.json",
            as: EnrichResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.status, DgiStatus.pending)
        XCTAssertFalse(response.message.isEmpty)
    }

    /// The opt-out refusal names the settings page the opt-in lives on, and it
    /// carries no code — so the sentence is the whole product and must be
    /// surfaced verbatim rather than replaced with "that did not work".
    func testEnrichDisabledIsARouteOwnedEnvelopeWithNoCode() throws {
        let envelope = try StrictDecodeVerifier.verify(
            fixture: "district-enrich-disabled.json",
            as: ApiErrorEnvelope.self
        )
        XCTAssertEqual(envelope.success, false)
        XCTAssertNil(envelope.code)
        XCTAssertTrue(envelope.error?.contains("Settings") ?? false)
    }

    /// ⛔ THERE IS NO `processing`, AND POLLING FOR IT NEVER TERMINATES. It is the
    /// web dashboard's optimistic local state; no route sends it. ⚠️ An absent
    /// status is not in progress either — after a clear it is null, which is the
    /// state that should offer enrichment again.
    func testDgiProgressStopsOnlyOnTheTerminalStates() {
        XCTAssertTrue(DgiStatus.isInProgress(DgiStatus.pending))
        XCTAssertTrue(DgiStatus.isInProgress(DgiStatus.crawling))
        XCTAssertTrue(DgiStatus.isInProgress(DgiStatus.synthesizing))
        XCTAssertFalse(DgiStatus.isInProgress(DgiStatus.complete))
        XCTAssertFalse(DgiStatus.isInProgress(DgiStatus.failed))
        XCTAssertFalse(DgiStatus.isInProgress(nil), "no dossier and none queued is not work in flight")
    }

    /// The call directory PATCH echoes nothing, so a save must be followed by a
    /// re-read — the same shape of problem the workspace rename has, and handled
    /// the same way.
    func testDirectoryPatchIsABareAcknowledgement() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-directory-patch.json",
            as: SuccessResponse.self
        )
        XCTAssertTrue(response.success)
    }
}
