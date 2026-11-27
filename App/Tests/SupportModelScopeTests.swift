@testable import DistrictAI
import DistrictModel
import XCTest

/// Filing a support request, replying on and closing one, and reporting content, each
/// against the service's recorded answers and its refusals.
///
/// ⚠️ A ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER: nothing here draws.
final class SupportModelScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let requests = "/api/district/support/requests"
    private static let filedPath = "/api/district/support/requests/support_filed"

    private func posts(_ transport: FixtureTransport, to path: String) -> Int {
        transport.requested.filter { $0 == "POST \(path)" }.count
    }

    private func supportModel(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (SupportModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let model = try await SupportModel(container: container(transport), workspaceId: Self.workspace, role: role)
        return (model, transport)
    }

    private func compose(_ model: SupportModel, subject: String = "Calls drop", message: String = "Since Monday") {
        model.beginCompose()
        model.editSubject(subject)
        model.editMessage(message)
    }

    // MARK: - SupportModel

    func testAViewerCannotComposeOrSend() async throws {
        let (model, transport) = try await supportModel(role: .viewer)
        model.beginCompose()
        model.editSubject("Calls drop")
        model.editMessage("Since Monday")
        await model.submit()

        XCTAssertFalse(model.composing)
        XCTAssertFalse(model.canSubmit)
        XCTAssertEqual(posts(transport, to: Self.requests), 0)
    }

    func testABlankDraftIsRejectedWithoutARequestAndAnEditClearsIt() async throws {
        let (model, transport) = try await supportModel()
        compose(model, subject: "   ", message: "\n")
        XCTAssertFalse(model.canSubmit)

        await model.submit()
        XCTAssertTrue(model.draftRejected)
        XCTAssertEqual(posts(transport, to: Self.requests), 0)

        model.editSubject("Calls drop")
        XCTAssertFalse(model.draftRejected, "an edit retires the rejection")
        model.editMessage("x")
        model.selectKind(.question)
        XCTAssertEqual(model.draftKind, .question)
    }

    func testAFiledRequestClosesTheFormNamesItAndRereadsTheList() async throws {
        let (model, transport) = try await supportModel([
            "POST \(Self.requests)": .fixture("district-support-request-create"),
        ])
        await model.load()
        compose(model)
        model.selectKind(.question)
        await model.submit()

        XCTAssertFalse(model.composing)
        XCTAssertEqual(model.create.notice, SupportCopy.filed)
        XCTAssertEqual(model.draftSubject, "")
        XCTAssertEqual(model.draftMessage, "")
        XCTAssertEqual(model.draftKind, .problem)
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.requests)" }.count, 2)
        XCTAssertEqual(model.requests.count, 3)

        model.dismissNotice()
        XCTAssertNil(model.create.notice)
    }

    func testADeduplicatedAndAPendingFilingSayWhatHappened() async throws {
        let (deduplicated, _) = try await supportModel([
            "POST \(Self.requests)": .json(#"{"success":true,"deduplicated":true}"#),
        ])
        compose(deduplicated)
        await deduplicated.submit()
        XCTAssertEqual(deduplicated.create.notice, SupportCopy.deduplicated)

        let (pending, _) = try await supportModel(["POST \(Self.requests)": .json(#"{"success":true}"#)])
        compose(pending)
        await pending.submit()
        XCTAssertEqual(pending.create.notice, SupportCopy.pending)
    }

    /// ⛔ A FAILED FILING KEEPS THE FORM AND THE TEXT, and may be sent again: the key it
    /// carried is still in hand, so a repeat cannot file twice.
    func testAFailedFilingKeepsTheDraftAndStaysResendable() async throws {
        let (model, transport) = try await supportModel(["POST \(Self.requests)": .refused(503)])
        compose(model)
        await model.submit()

        XCTAssertTrue(model.composing)
        XCTAssertTrue(model.create.isFailure)
        XCTAssertNotNil(model.create.notice)
        XCTAssertEqual(model.draftSubject, "Calls drop")
        XCTAssertTrue(model.create.isArmed, "a filing is idempotent, so a 5xx may be repeated")
        XCTAssertTrue(model.canSubmit)

        await model.submit()
        XCTAssertEqual(posts(transport, to: Self.requests), 2)
    }

    func testCancellingClearsTheDraft() async throws {
        let (model, _) = try await supportModel()
        compose(model)
        model.selectKind(.question)
        model.cancelCompose()

        XCTAssertFalse(model.composing)
        XCTAssertEqual(model.draftSubject, "")
        XCTAssertEqual(model.draftMessage, "")
        XCTAssertEqual(model.draftKind, .problem)
    }

    func testARefusedListReadIsAFailureNotAnEmptyList() async throws {
        let (model, _) = try await supportModel([Self.requests: .refused(500)])
        await model.load()
        guard case .failed = model.list else {
            return XCTFail("expected the list to fail, got \(model.list)")
        }
        XCTAssertEqual(model.requests.count, 0)
    }

    // MARK: - SupportThreadModel

    private func threadModel(
        _ replies: [String: FixtureTransport.Reply],
        role: WorkspaceRole? = .client
    ) async throws -> (SupportThreadModel, FixtureTransport) {
        var all: [String: FixtureTransport.Reply] = [Self.filedPath: .fixture("district-support-request")]
        all.merge(replies) { $1 }
        let transport = FixtureTransport(all)
        let model = try await SupportThreadModel(
            container: container(transport),
            workspaceId: Self.workspace,
            role: role,
            key: "support_filed"
        )
        await model.load()
        return (model, transport)
    }

    func testAReplyIsAppendedAndTheBoxCleared() async throws {
        let (model, _) = try await threadModel([
            "POST \(Self.filedPath)/reply": .fixture("district-support-reply"),
        ])
        XCTAssertFalse(model.canReply, "an empty box cannot be sent")
        model.editReply("  Still failing  ")
        XCTAssertTrue(model.canReply)

        await model.sendReply()
        XCTAssertEqual(model.messages.map(\.id).last, "support_msg_reply")
        XCTAssertEqual(model.messages.count, 3)
        XCTAssertEqual(model.draftReply, "")
    }

    /// ⛔ A REPLY THAT FAILED ON THE SERVER IS NOT OFFERED AGAIN: it may have posted, and a
    /// repeat would put a second copy in a thread the customer reads.
    func testAServerFailedReplyIsNotOfferedAgainButARefusedOneIs() async throws {
        let (failed, _) = try await threadModel(["POST \(Self.filedPath)/reply": .refused(502)])
        failed.editReply("Still failing")
        await failed.sendReply()
        XCTAssertTrue(failed.reply.refusedRepeat)
        XCTAssertFalse(failed.canReply)

        let (refused, _) = try await threadModel(["POST \(Self.filedPath)/reply": .refused(422, "Reply is too long")])
        refused.editReply("Still failing")
        await refused.sendReply()
        XCTAssertEqual(refused.reply.notice, "Reply is too long")
        XCTAssertTrue(refused.canReply, "a 4xx was refused before anything posted")
    }

    func testClosingAdoptsTheServersStatusAndRetiresClose() async throws {
        let (model, transport) = try await threadModel([
            "POST \(Self.filedPath)/close": .fixture("district-support-close"),
        ])
        XCTAssertTrue(model.canClose)
        XCTAssertFalse(model.isResolved)

        await model.closeRequest()
        XCTAssertEqual(model.closedStatusName, "Done")
        XCTAssertTrue(model.isResolved)
        XCTAssertFalse(model.canClose)
        await model.closeRequest()
        XCTAssertEqual(posts(transport, to: "\(Self.filedPath)/close"), 1, "a closed request is not closed twice")
    }

    func testAViewerNeitherRepliesNorCloses() async throws {
        let (model, transport) = try await threadModel([:], role: .viewer)
        model.editReply("Still failing")
        await model.sendReply()
        await model.closeRequest()

        XCTAssertFalse(model.canReply)
        XCTAssertFalse(model.canClose)
        XCTAssertEqual(transport.requested.filter { $0.hasPrefix("POST /api/district/support") }, [])
    }

    func testAnUnreadThreadIsUnfiledAndCannotBeWritten() async throws {
        let (model, _) = try await threadModel([Self.filedPath: .refused(500)])
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.statusName, SupportCopy.unfiledStatus)
        XCTAssertFalse(model.canClose)
        model.editReply("x")
        XCTAssertFalse(model.canReply)
    }

    // MARK: - ReportContentModel

    private func reportModel(
        _ reply: FixtureTransport.Reply,
        target: ReportTarget = .call(callId: "call_contract_answered")
    ) async throws -> (ReportContentModel, FixtureTransport) {
        let transport = FixtureTransport(["POST \(Self.requests)": reply])
        let model = try await ReportContentModel(
            container: container(transport),
            workspaceId: Self.workspace,
            target: target
        )
        return (model, transport)
    }

    func testAFiledReportIsConfirmed() async throws {
        let (model, transport) = try await reportModel(.fixture("district-support-request-create"))
        XCTAssertEqual(model.headline, ReportCopy.headline(for: .call(callId: "call_contract_answered")))

        await model.submit(note: "  ")
        XCTAssertEqual(model.state, .done(ReportCopy.confirmation(for: .filed(issueKey: "DA-43"))))
        XCTAssertEqual(posts(transport, to: Self.requests), 1)
    }

    func testADeduplicatedAndAPendingReportSayWhatHappened() async throws {
        let (deduplicated, _) = try await reportModel(.json(#"{"success":true,"deduplicated":true}"#))
        await deduplicated.submit(note: "spam")
        XCTAssertEqual(deduplicated.state, .done(ReportCopy.confirmation(for: .deduplicated)))

        let (pending, _) = try await reportModel(.json(#"{"success":true}"#))
        await pending.submit(note: "spam")
        XCTAssertEqual(pending.state, .done(ReportCopy.confirmation(for: .pending)))
    }

    /// ⚠️ THE SERVER'S OWN SENTENCE: a 429 names the remedy, and it is shown as sent.
    func testARefusedReportShowsTheServersSentenceAndCanBeReset() async throws {
        let sentence = "Too many requests. Reply on an existing request instead."
        let (model, _) = try await reportModel(.refused(429, sentence), target: .conversation(
            threadKey: "contact:contact_contract_1",
            name: nil
        ))
        await model.submit(note: "abusive messages")
        XCTAssertEqual(model.state, .failed(sentence))
        XCTAssertFalse(model.isSending)

        model.reset()
        XCTAssertEqual(model.state, .idle)
    }

    // MARK: - SupportChrome

    func testTheStatusToneFollowsTheCategoryInAnyCase() {
        XCTAssertEqual(SupportChrome.tone(for: "done"), .success)
        XCTAssertEqual(SupportChrome.tone(for: "new"), .info)
        XCTAssertEqual(SupportChrome.tone(for: "Indeterminate"), .district)
        XCTAssertEqual(SupportChrome.tone(for: "PENDING"), .warning)
        XCTAssertEqual(SupportChrome.tone(for: ""), .neutral)
        XCTAssertEqual(SupportChrome.tone(for: "UNDEFINED"), .neutral)
    }
}
