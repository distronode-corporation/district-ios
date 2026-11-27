@testable import DistrictAI
import DistrictData
import DistrictModel
import XCTest

/// ``InboxModel`` over the recorded conversations: the list's states, the draft badges, the
/// mark-all-read write, assignment and message search.
///
/// ⚠️ IT DERIVES FROM ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN ``container(_:)``.
final class InboxModelScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let search = "GET /api/district/messages/search"

    private static let hit = #"""
    {"messageId":"msg_search_email","key":"ada@contract.test","threadKey":"contact:contact_contract_1",
     "counterpart":"ada@contract.test","kind":"email","contactId":"contact_contract_1",
     "contactName":"Contract Test Caller","contactEmail":"ada@contract.test",
     "body":"Could we move Thursday to Friday?","subject":"Re: Thursday appointment",
     "direction":"inbound","type":"email","createdAt":"2026-08-15T14:20:00.000Z"}
    """#

    private func model(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (InboxModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let model = try await InboxModel(container: container(transport), workspaceId: Self.workspace, role: role)
        return (model, transport)
    }

    private func count(_ transport: FixtureTransport, _ request: String) -> Int {
        transport.requested.filter { $0 == request }.count
    }

    // MARK: - The list

    func testTheRecordedListIsContentWithItsUnreadTotalAndDraftBadges() async throws {
        let (model, _) = try await model()
        await model.load()
        guard case let .content(conversations, isPartial, draftKeys, refreshing) = model.state else {
            return XCTFail("expected content, got \(model.state)")
        }
        XCTAssertEqual(conversations.count, 2)
        XCTAssertFalse(isPartial, "scanned 4 of 500 is a complete list")
        XCTAssertFalse(refreshing)
        XCTAssertEqual(draftKeys, ["contact:contact_contract_1", "addr:14165558888"])
        let unread = conversations.reduce(0) { $0 + $1.unreadCount }
        XCTAssertEqual(model.unreadTotal, unread)
        XCTAssertEqual(model.conversation(forThreadKey: "addr:14165558888")?.counterpart, "+14165558888")
        XCTAssertNil(model.conversation(forThreadKey: "addr:nobody"))
    }

    /// A viewer never reads drafts (`messages/drafts` excludes viewer): no badges, no 403.
    func testAViewerReadsTheListButNotTheDrafts() async throws {
        let (model, transport) = try await model(role: .viewer)
        await model.load()
        guard case let .content(_, _, draftKeys, _) = model.state else {
            return XCTFail("expected content, got \(model.state)")
        }
        XCTAssertTrue(draftKeys.isEmpty)
        XCTAssertEqual(count(transport, "GET /api/district/messages/drafts"), 0)
    }

    func testAnEmptyListIsTheEmptyStateNotContent() async throws {
        let none: FixtureTransport.Reply = .recorded("district-conversations") { $0["conversations"] = [Any]() }
        let (model, _) = try await model(["/api/district/conversations": none])
        await model.load()
        guard case .empty = model.state else {
            return XCTFail("expected empty, got \(model.state)")
        }
        XCTAssertEqual(model.unreadTotal, 0)
    }

    func testAnExhaustedScanIsPartial() async throws {
        let partial: FixtureTransport.Reply = .recorded("district-conversations") { $0["scanned"] = 500 }
        let (model, _) = try await model(["/api/district/conversations": partial])
        await model.load()
        guard case let .content(_, isPartial, _, _) = model.state else {
            return XCTFail("expected content, got \(model.state)")
        }
        XCTAssertTrue(isPartial)
    }

    func testARefusedReadIsAFailure() async throws {
        let (model, _) = try await model(["/api/district/conversations": .refused(500)])
        await model.load()
        guard case .failed = model.state else {
            return XCTFail("expected a failure, got \(model.state)")
        }
        XCTAssertNil(model.conversation(forThreadKey: "contact:contact_contract_1"))
    }

    /// A failed draft read leaves the list without badges rather than failing it.
    func testARefusedDraftReadKeepsTheList() async throws {
        let (model, _) = try await model(["GET /api/district/messages/drafts": .refused(500)])
        await model.load()
        guard case let .content(_, _, draftKeys, _) = model.state else {
            return XCTFail("expected content, got \(model.state)")
        }
        XCTAssertTrue(draftKeys.isEmpty)
    }

    // MARK: - Mark all read

    func testMarkAllReadWritesOnceThenReReads() async throws {
        let (model, transport) = try await model(
            ["POST /api/district/messages/mark-read": .fixture("district-message-mark-read")]
        )
        await model.load()
        XCTAssertGreaterThan(model.unreadTotal, 0)
        await model.markAllRead()
        XCTAssertEqual(count(transport, "POST /api/district/messages/mark-read"), 1)
        XCTAssertEqual(count(transport, "GET /api/district/conversations"), 2, "re-read after the write")
    }

    func testMarkAllReadSendsNothingWhenNothingIsUnreadOrForAViewer() async throws {
        let read: FixtureTransport.Reply = .recorded("district-conversations") { json in
            json.editEach("conversations") { $0["unreadCount"] = 0 }
        }
        let (quiet, quietTransport) = try await model(["/api/district/conversations": read])
        await quiet.load()
        await quiet.markAllRead()
        XCTAssertEqual(count(quietTransport, "POST /api/district/messages/mark-read"), 0)

        let (viewer, viewerTransport) = try await model(role: .viewer)
        await viewer.load()
        await viewer.markAllRead()
        XCTAssertEqual(count(viewerTransport, "POST /api/district/messages/mark-read"), 0)
    }

    /// A refused write leaves the list as it was, with no re-read.
    func testARefusedMarkAllReadDoesNotReRead() async throws {
        let (model, transport) = try await model(["POST /api/district/messages/mark-read": .refused(500)])
        await model.load()
        await model.markAllRead()
        XCTAssertEqual(count(transport, "GET /api/district/conversations"), 1)
    }

    // MARK: - Assignment

    func testAssigningIsOfferedOnlyToARoleThatCanWrite() async throws {
        let (viewer, _) = try await model(role: .viewer)
        await viewer.load()
        let row = try XCTUnwrap(viewer.conversation(forThreadKey: "contact:contact_contract_1"))
        viewer.beginAssigning(row)
        XCTAssertNil(viewer.assigning)

        let (client, _) = try await model()
        await client.load()
        let same = try XCTUnwrap(client.conversation(forThreadKey: "contact:contact_contract_1"))
        client.beginAssigning(same)
        XCTAssertEqual(client.assigning?.threadKey, "contact:contact_contract_1")
        XCTAssertNil(client.assigning?.current)
    }

    func testTheAssignedToMeFilterKeepsOnlyRowsTheServerMarked() async throws {
        let mine: FixtureTransport.Reply = .recorded("district-conversations") { json in
            json.editEach("conversations") { row in
                row["assignedToMe"] = row["threadKey"] as? String == "addr:14165558888"
            }
        }
        let (model, _) = try await model(["/api/district/conversations": mine])
        await model.load()
        guard case let .content(conversations, _, _, _) = model.state else {
            return XCTFail("expected content, got \(model.state)")
        }
        XCTAssertEqual(model.visible(conversations).count, 2)
        model.assignedToMeOnly = true
        XCTAssertEqual(model.visible(conversations).map(\.threadKey), ["addr:14165558888"])
    }

    // MARK: - Search

    func testABlankQueryIsIdleAndAOneCharacterQueryIsBelowTheFloor() async throws {
        let (model, transport) = try await model()
        model.searchQueryChanged(" \n ")
        guard case .idle = model.searchState else {
            return XCTFail("expected idle, got \(model.searchState)")
        }
        model.searchQueryChanged(" a ")
        guard case .belowFloor = model.searchState else {
            return XCTFail("expected below the floor, got \(model.searchState)")
        }
        try await Task.sleep(for: InboxModel.searchDebounce * 2)
        XCTAssertEqual(count(transport, Self.search), 0, "nothing below the floor reaches the service")
    }

    /// Typing quickly sends one search, for the last query, after the debounce.
    func testRapidQueriesSendOneSearch() async throws {
        let body = #"{"success":true,"limit":50,"results":[\#(Self.hit)]}"#
        let (model, transport) = try await model([Self.search: .json(body)])
        model.searchQueryChanged("th")
        model.searchQueryChanged("thu")
        model.searchQueryChanged("thursday")
        guard case .searching = model.searchState else {
            return XCTFail("expected searching, got \(model.searchState)")
        }
        await waitUntil(state: "\(model.searchState)") {
            if case .results = model.searchState {
                return true
            }
            return false
        }
        XCTAssertEqual(count(transport, Self.search), 1)
        guard case let .results(hits, capped) = model.searchState else { return }
        XCTAssertEqual(hits.map(\.messageId), ["msg_search_email"])
        XCTAssertFalse(capped)
    }

    func testAFullPageOfHitsIsCapped() async throws {
        let body = #"{"success":true,"limit":1,"results":[\#(Self.hit)]}"#
        let (model, _) = try await model([Self.search: .json(body)])
        model.searchQueryChanged("thursday")
        await waitUntil(state: "\(model.searchState)") {
            if case .results = model.searchState {
                return true
            }
            return false
        }
        guard case let .results(_, capped) = model.searchState else { return }
        XCTAssertTrue(capped)
    }

    func testNoHitsIsTheEmptyResult() async throws {
        let (model, _) = try await model([Self.search: .json(#"{"success":true,"limit":50,"results":[]}"#)])
        model.searchQueryChanged("nothing-matches")
        await waitUntil(state: "\(model.searchState)") {
            if case .empty = model.searchState {
                return true
            }
            return false
        }
    }

    func testARefusedSearchIsAFailure() async throws {
        let (model, _) = try await model([Self.search: .refused(500)])
        model.searchQueryChanged("thursday")
        await waitUntil(state: "\(model.searchState)") {
            if case .failed = model.searchState {
                return true
            }
            return false
        }
    }

    /// Clearing the box mid-debounce cancels the pending search.
    func testClearingTheQueryCancelsThePendingSearch() async throws {
        let (model, transport) = try await model([Self.search: .json(#"{"success":true,"results":[]}"#)])
        model.searchQueryChanged("thursday")
        model.searchQueryChanged("")
        try await Task.sleep(for: InboxModel.searchDebounce * 2)
        XCTAssertEqual(count(transport, Self.search), 0)
        guard case .idle = model.searchState else {
            return XCTFail("expected idle, got \(model.searchState)")
        }
    }
}
