@testable import DistrictAI
import DistrictModel
import XCTest

/// What an HQ voice screen report names for each place in the app: a page from the
/// service's table and, at most, one record id.
@MainActor
final class HQVoicePlaceTests: XCTestCase {
    func testEverySectionRootIsInTheServiceTable() {
        for item in SidebarItem.allCases {
            let id = HQVoicePlace.pageID(item)
            XCTAssertNotNil(HQVoicePage(id: id), "\(item) names \(id), which the service would refuse")
            XCTAssertEqual(HQVoicePlace.of(item, top: nil).page.id, id)
            XCTAssertNil(HQVoicePlace.of(item, top: nil).selected)
        }
        XCTAssertEqual(HQVoicePlace.pageID(.overview), "home")
        XCTAssertEqual(HQVoicePlace.pageID(.dialer), "phone")
    }

    func testARecordIsNamedByItsIdOnly() {
        let call = HQVoicePlace.of(.callDetail(workspaceId: "ws1", callId: "call_1"))
        XCTAssertEqual(call?.page, .calls)
        XCTAssertEqual(call?.selected, HQVoiceSelection(kind: .call, id: "call_1"))

        let contact = HQVoicePlace.of(.contactDetail(workspaceId: "ws1", role: .agency, contactId: "c_9"))
        XCTAssertEqual(contact?.page, .contacts)
        XCTAssertEqual(contact?.selected, HQVoiceSelection(kind: .contact, id: "c_9"))

        let supervise = HQVoicePlace.of(.superviseCall(workspaceId: "ws1", role: .agency, callId: "call_2"))
        XCTAssertEqual(supervise?.page.id, "live")
        XCTAssertEqual(supervise?.selected?.kind, .call)
    }

    func testAThreadNamesItsContactNeverItsAddressOrTitle() {
        let known = HQVoicePlace.of(thread("contact:c_maya", title: "Maya Chen"))
        XCTAssertEqual(known?.page, .inbox)
        XCTAssertEqual(known?.selected, HQVoiceSelection(kind: .conversation, id: "c_maya"))

        let address = HQVoicePlace.of(thread("addr:+15555550100", title: "+1 555 555 0100"))
        XCTAssertEqual(address?.page, .inbox)
        XCTAssertNil(address?.selected, "an address is never sent")
    }

    func testEveryPushedScreenIsInTheServiceTable() {
        let routes: [Route] = [
            .hq(workspaceId: "w", role: nil), .analytics(workspaceId: "w"), .marketplace(workspaceId: "w", role: nil),
            .billing(workspaceId: "w", role: nil), .workflows(workspaceId: "w", role: nil),
            .rooms(workspaceId: "w", role: nil), .activeRoom(workspaceId: "w", role: nil, roomName: "Weekly sync"),
            .dialer(workspaceId: "w", role: nil), .liveCalls(workspaceId: "w", role: nil),
            .support(workspaceId: "w", role: nil), .supportRequest(workspaceId: "w", role: nil, key: "k"),
            .desk(workspaceId: "w", role: nil), .deskTicket(workspaceId: "w", role: nil, ticketId: "t"), .devices,
        ]
        let expected = [
            "hq", "analytics", "marketplace", "billing", "workflows", "rooms", "meeting", "phone", "live", "support",
            "support", "desk", "desk", "account",
        ]
        XCTAssertEqual(routes.compactMap { HQVoicePlace.of($0)?.page.id }, expected)
        for route in routes {
            XCTAssertNil(HQVoicePlace.of(route)?.selected, "\(route) names no record")
        }
    }

    func testTheShellReportsTheTopScreenOfTheSelectedSection() {
        var paths = ShellPaths()
        paths.adopt("ws1")
        XCTAssertEqual(paths.hqVoicePlace, HQVoicePlace(.home))
        paths.compactTab = .contacts
        XCTAssertEqual(paths.hqVoicePlace, HQVoicePlace(.contacts))
        paths.setCompactPath([.contactDetail(workspaceId: "ws1", role: nil, contactId: "c_1")], for: .contacts)
        XCTAssertEqual(paths.hqVoicePlace.selected, HQVoiceSelection(kind: .contact, id: "c_1"))
        paths.setCompactPath([], for: .contacts)
        XCTAssertNil(paths.hqVoicePlace.selected)
    }

    private func thread(_ key: String, title: String) -> Route {
        .thread(workspaceId: "ws1", role: .agency, threadKey: key, replyTargets: [], title: title)
    }
}

/// The HQ voice settings screen's model: a read, an edit, and one save at a time.
@MainActor
final class HQVoiceSettingsModelTests: XCTestCase {
    private let settings = #"""
    {"success":true,"settings":{"voice":"Puck","length":"normal","pace":"normal","language":"portal","micMode":"open"}}
    """#

    func testLoadEditAndSave() async {
        let transport = HQVoiceTransport()
        transport.reply("voice-settings", 200, settings)
        let model = HQVoiceSettingsModel(hq: transport.repository, workspaceId: "ws1")
        await model.load()
        XCTAssertEqual(model.draft?.voice, "Puck")
        XCTAssertFalse(model.isDirty)

        model.edit { $0.micMode = "push" }
        model.edit { $0.voice = "Charon" }
        XCTAssertTrue(model.isDirty)
        transport.reply(
            "voice-settings",
            200,
            settings
                .replacingOccurrences(of: "Puck", with: "Charon")
                .replacingOccurrences(of: #""micMode":"open""#, with: #""micMode":"push""#)
        )
        await model.save()
        XCTAssertTrue(model.isSaved)
        XCTAssertFalse(model.isDirty)
        let put = transport.bodies("voice-settings").last ?? ""
        XCTAssertTrue(put.contains(#""micMode":"push""#), put)
        XCTAssertTrue(put.contains(#""voice":"Charon""#), put)
    }

    func testALoadFailureIsShownAndASaveFailureKeepsTheDraft() async {
        let transport = HQVoiceTransport()
        let model = HQVoiceSettingsModel(hq: transport.repository, workspaceId: "ws1")
        await model.load()
        XCTAssertNotNil(model.loadFailure)
        XCTAssertNil(model.draft)

        transport.reply("voice-settings", 200, settings)
        await model.load()
        model.edit { $0.pace = "faster" }
        transport.reply("voice-settings", 500, #"{"error":"down"}"#)
        await model.save()
        XCTAssertNotNil(model.saveFailure)
        XCTAssertEqual(model.draft?.pace, "faster")
        XCTAssertTrue(model.isDirty)
    }

    func testAValueThisBuildDoesNotKnowIsKept() {
        let options = HQVoiceOptions.including("Zephyr", in: HQVoiceOptions.voices)
        XCTAssertEqual(options.last, HQVoiceOption(value: "Zephyr", label: "Zephyr"))
        XCTAssertEqual(HQVoiceOptions.including("Puck", in: HQVoiceOptions.voices).count, 5)
        XCTAssertEqual(HQVoiceOptions.micModes.map(\.value), ["open", "push"])
        XCTAssertEqual(HQVoiceOptions.languages.map(\.value), ["portal", "en", "fr"])
    }
}
