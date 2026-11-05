@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// App parity (3), DistrictCore 8.2.0: the assignee badge, the Assigned to me filter,
/// the assign sheet's members, the write and its refusals.
@MainActor
final class ThreadAssignmentTests: XCTestCase {
    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    private static let roster = #"""
    {"success":true,"members":[
     {"email":"owner@contract.test","role":"agency","createdAt":"2026-08-01T00:00:00.000Z"},
     {"email":"teammate@contract.test","role":"client","createdAt":"2026-08-02T00:00:00.000Z"},
     {"email":"reader@contract.test","role":"viewer","createdAt":"2026-08-03T00:00:00.000Z"}]}
    """#

    private static let assigned = #"""
    {"success":true,"assignment":{"threadKey":"contact:c_1","assigneeEmail":"teammate@contract.test",
     "assignedAt":"2026-10-29T12:00:00.000Z"}}
    """#

    private func model(_ transport: ParityTransport, current: String? = nil) -> ThreadAssignModel {
        ThreadAssignModel(
            inbox: ParityFixtures.inbox(transport),
            workspaces: WorkspaceRepository(client: ParityFixtures.client(transport)),
            workspaceId: "ws_1",
            threadKey: "contact:c_1",
            current: current
        )
    }

    // MARK: - The list

    func testTheBadgeSaysYouOrTheAssigneeAndVoiceOverHearsTheAddress() async {
        let rows = [
            ParityFixtures.row(
                threadKey: "a", counterpart: "+1", channels: ["sms"], replyOptions: "[]",
                assigneeEmail: "me@contract.test", assignedToMe: true
            ),
            ParityFixtures.row(
                threadKey: "b", counterpart: "+2", channels: ["sms"], replyOptions: "[]",
                assigneeEmail: "teammate@contract.test"
            ),
            ParityFixtures.row(threadKey: "c", counterpart: "+3", channels: ["sms"], replyOptions: "[]"),
        ]
        let displays = await ParityFixtures.summaries(rows).map(ConversationDisplay.init)

        XCTAssertEqual(displays.map(\.assigneeLabel), ["You", "teammate", nil])
        XCTAssertEqual(displays[1].assigneeEmail, "teammate@contract.test")
        XCTAssertEqual(InboxCopy.assignedTo("teammate@contract.test"), "Assigned to teammate@contract.test")
        XCTAssertEqual(french { InboxCopy.assignedTo("teammate@contract.test") }, "Assignée à teammate@contract.test")
        XCTAssertEqual(french { InboxCopy.assigneeYou }, "Vous")
    }

    /// ⛔ THE FILTER READS THE SERVER'S `assignedToMe`, never an address comparison.
    func testAssignedToMeKeepsOnlyTheRowsTheServerSaysAreMine() async {
        let rows = [
            ParityFixtures.row(
                threadKey: "mine", counterpart: "+1", channels: ["sms"], replyOptions: "[]",
                assigneeEmail: "Me@Contract.test", assignedToMe: true
            ),
            ParityFixtures.row(
                threadKey: "theirs", counterpart: "+2", channels: ["sms"], replyOptions: "[]",
                assigneeEmail: "me@contract.test", assignedToMe: false
            ),
            ParityFixtures.row(threadKey: "nobody", counterpart: "+3", channels: ["sms"], replyOptions: "[]"),
        ]
        let conversations = await ParityFixtures.summaries(rows)

        XCTAssertEqual(InboxModel.visible(conversations, assignedToMeOnly: true).map(\.threadKey), ["mine"])
        XCTAssertEqual(InboxModel.visible(conversations, assignedToMeOnly: false).count, 3)
    }

    // MARK: - The sheet

    /// ⛔ NO VIEWER IS OFFERED, and the current owner keeps a row even when the roster no
    /// longer lists them.
    func testTheSheetOffersEveryoneButViewersAndKeepsTheCurrentOwner() async {
        let transport = ParityTransport()
        transport.on(.get, "/workspace/members", 200, Self.roster)
        let sheet = model(transport, current: "former@contract.test")

        await sheet.load()

        guard case let .ready(emails) = sheet.members else { return XCTFail("\(sheet.members)") }
        XCTAssertEqual(emails, ["owner@contract.test", "teammate@contract.test", "former@contract.test"])
    }

    func testAssigningPostsTheAddressAndUnassigningPostsNull() async {
        let transport = ParityTransport()
        transport.on(.post, "/conversations/assign", 200, Self.assigned)
        let sheet = model(transport)

        let assigned = await sheet.assign("teammate@contract.test")
        let unassigned = await sheet.assign(nil)

        XCTAssertTrue(assigned)
        XCTAssertTrue(unassigned)
        let writes = transport.requests(to: "/conversations/assign")
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0].json["assigneeEmail"] as? String, "teammate@contract.test")
        XCTAssertEqual(writes[0].json["threadKey"] as? String, "contact:c_1")
        XCTAssertTrue(writes[1].json["assigneeEmail"] is NSNull, "unassign sends an explicit null")
    }

    /// ⛔ BOTH REFUSALS ARE SAID, in French from the catalog.
    func testTheViewerAndNonMemberRefusalsAreSaidInFrench() async {
        let cases = [
            (
                "assignee_is_viewer",
                "Un Lecteur peut consulter les conversations, mais aucune ne peut lui être assignée. "
                    + "Choisissez un membre qui a un autre rôle."
            ),
            (
                "assignee_not_member",
                "Cette personne n'est pas membre de cet espace de travail. Ajoutez-la d'abord à l'équipe."
            ),
        ]
        for (code, french) in cases {
            let transport = ParityTransport()
            transport.on(.post, "/conversations/assign", 400, #"{"error":"Refused.","code":"\#(code)"}"#)
            let sheet = model(transport)

            L10nRuntime.locale = .frCA
            let assigned = await sheet.assign("reader@contract.test")
            L10nRuntime.locale = .en

            XCTAssertFalse(assigned)
            XCTAssertEqual(sheet.failure?.message, french, code)
            XCTAssertFalse(sheet.saving)
        }
    }
}

/// App parity (2): the push declaration that goes with the Meta reads.
final class PushCapabilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PushCapabilityTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTheMemoryStoresAndForgetsTheDeclaration() {
        let memory = UserDefaultsPushTokenMemory(defaults: defaults)
        XCTAssertNil(memory.lastRegisteredCapabilities())

        memory.rememberRegisteredCapabilities("metaChannels")
        XCTAssertEqual(memory.lastRegisteredCapabilities(), "metaChannels")

        memory.forgetRegisteredCapabilities()
        XCTAssertNil(memory.lastRegisteredCapabilities())
    }

    /// ⛔ THE ALERT REGISTER DECLARES `metaChannels`, ONCE: an unchanged token with the
    /// same declaration is not sent again, and an install that registered before 8.2.0
    /// (token remembered, no declaration) registers exactly once more.
    func testTheRegisterDeclaresMetaChannelsOnce() async throws {
        let memory = UserDefaultsPushTokenMemory(defaults: defaults)
        memory.rememberRegisteredToken("apns-token")
        let transport = ParityTransport()
        transport.on(.post, "/devices/register", 200, #"{"success":true}"#)
        let pushTokens = InboxParity.pushTokens(client: ParityFixtures.client(transport), memory: memory)

        let first = await pushTokens.register(token: "apns-token")
        let second = await pushTokens.register(token: "apns-token")

        XCTAssertEqual(try first.get(), .registered)
        XCTAssertEqual(try second.get(), .alreadyRegistered)
        let registers = transport.requests(to: "/devices/register")
        XCTAssertEqual(registers.count, 1)
        XCTAssertEqual(registers.first?.json["capabilities"] as? [String], ["metaChannels"])
    }
}

/// The Inbox's guard against overlapping list reads (Seer, #99).
final class LatestReadTests: XCTestCase {
    /// ⛔ ONLY THE LATEST READ BEGUN MAY APPLY ITS ANSWER: a refresh begun before an
    /// assignment, answering after the re-read that followed it, is dropped.
    func testOnlyTheLatestReadAppliesItsAnswer() {
        var reads = LatestRead()
        let beforeAssigning = reads.begin()
        let afterAssigning = reads.begin()

        XCTAssertFalse(reads.isLatest(beforeAssigning))
        XCTAssertTrue(reads.isLatest(afterAssigning))
        XCTAssertTrue(reads.isLatest(reads.begin()), "each new read is the latest")
        XCTAssertFalse(reads.isLatest(afterAssigning))
    }
}
