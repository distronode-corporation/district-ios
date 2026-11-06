@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// App parity (5), DistrictCore 8.2.0: a closed WhatsApp window offers only approved
/// templates, with their variables and a preview, sent through `sendWhatsAppTemplate`.
@MainActor
final class WhatsAppTemplateTests: XCTestCase {
    private static let whatsApp = [ReplyTarget(to: "+14165550177", channel: MessageChannel.whatsapp)]

    private func closedThread(_ transport: ParityTransport, role: WorkspaceRole = .client) async -> ThreadModel {
        transport.on(.get, "/whatsapp/window", 200, ParityFixtures.windowClosed)
        transport.on(.get, "/whatsapp/templates", 200, ParityFixtures.templates)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        let model = ParityFixtures.thread(transport, role: role, targets: Self.whatsApp)
        await model.load()
        await model.refreshWhatsAppWindow()
        return model
    }

    /// ⛔ THE WINDOW IS READ FOR THE SELECTED ADDRESS, and a closed one replaces the box.
    func testAClosedWindowReplacesTheReplyBox() async throws {
        let transport = ParityTransport()
        let model = await closedThread(transport)

        XCTAssertTrue(model.whatsAppWindowClosed)
        let read = try XCTUnwrap(transport.requests(to: "/whatsapp/window").first)
        XCTAssertEqual(read.query("to"), "+14165550177")
        XCTAssertEqual(read.query("workspaceId"), "ws_1")
    }

    func testAnOpenWindowKeepsTheBoxAndTheReplyNamesItsSender() async throws {
        let transport = ParityTransport()
        transport.on(.get, "/whatsapp/window", 200, ParityFixtures.windowOpen)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/send", 200, ParityFixtures.sent)
        let model = ParityFixtures.thread(transport, targets: Self.whatsApp)
        await model.load()
        await model.refreshWhatsAppWindow()
        model.composerTextChanged("Yes, we do.")

        XCTAssertFalse(model.whatsAppWindowClosed)
        await model.send()

        let send = try XCTUnwrap(transport.requests(to: "/messages/send").first)
        XCTAssertEqual(send.json["channel"] as? String, "whatsapp")
        XCTAssertEqual(send.json["whatsappSenderId"] as? String, "wa_sender_1")
        XCTAssertEqual(send.json["body"] as? String, "Yes, we do.")
    }

    /// ⚠️ A FAILED READ OFFERS FREE TEXT: the server's own refusal is the answer then.
    func testAWindowThatCannotBeReadLeavesTheBox() async {
        let transport = ParityTransport()
        let model = ParityFixtures.thread(transport, targets: Self.whatsApp)

        await model.refreshWhatsAppWindow()

        XCTAssertEqual(model.whatsApp.window, .unknown)
        XCTAssertFalse(model.whatsAppWindowClosed)
    }

    /// ⛔ NOT A WHATSAPP REPLY, NO READ.
    func testAnSmsReplyReadsNoWindow() async {
        let transport = ParityTransport()
        let model = ParityFixtures.thread(transport, targets: [ReplyTarget(to: "+14165550177", channel: "sms")])

        await model.refreshWhatsAppWindow()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(model.whatsAppWindowClosed)
    }

    /// ⛔ A VIEWER READS NO WINDOW AND IS OFFERED NO TEMPLATE: the seat never sends.
    func testAViewerIsOfferedNoTemplate() async {
        let transport = ParityTransport()
        let model = await closedThread(transport, role: .viewer)

        XCTAssertFalse(model.whatsAppWindowClosed)
        XCTAssertTrue(transport.requests(to: "/whatsapp/window").isEmpty)
        XCTAssertFalse(model.canReply)
    }

    /// ⛔ ONLY APPROVED TEMPLATES ARE OFFERED; the fixture's pending one is not.
    func testOnlyApprovedTemplatesAreOffered() async {
        let transport = ParityTransport()
        let model = await closedThread(transport)

        await model.loadWhatsAppTemplates()

        guard case let .ready(templates) = model.whatsApp.templates else {
            return XCTFail("templates not ready: \(model.whatsApp.templates)")
        }
        XCTAssertEqual(templates.map(\.id), ["wa_tpl_reminder"])
        XCTAssertEqual(transport.requests(to: "/whatsapp/templates").first?.query("senderId"), "wa_sender_1")
    }

    /// ⛔ THE SEND CARRIES THE TEMPLATE, ITS VARIABLES TRIMMED, AND THE FILLED TEXT, from
    /// the number the customer wrote to; the thread and the window are then re-read.
    func testATemplateGoesOutWithItsVariablesAndTheFilledText() async throws {
        let transport = ParityTransport()
        transport.on(.post, "/messages/send", 200, ParityFixtures.sent)
        let model = await closedThread(transport)
        await model.loadWhatsAppTemplates()
        guard case let .ready(templates) = model.whatsApp.templates, let reminder = templates.first else {
            return XCTFail("no template")
        }

        let sent = await model.sendWhatsAppTemplate(reminder, variables: [" Ada ", "Friday"])

        XCTAssertTrue(sent)
        let send = try XCTUnwrap(transport.requests(to: "/messages/send").first)
        XCTAssertEqual(send.json["channel"] as? String, "whatsapp")
        XCTAssertEqual(send.json["templateId"] as? String, "wa_tpl_reminder")
        XCTAssertEqual(send.json["templateVariables"] as? [String], ["Ada", "Friday"])
        XCTAssertEqual(send.json["whatsappSenderId"] as? String, "wa_sender_1")
        XCTAssertEqual(send.json["body"] as? String, "Hi Ada, this is a reminder of your appointment on Friday.")
        XCTAssertEqual(transport.requests(to: "/whatsapp/window").count, 2, "the window is re-read after")
        XCTAssertFalse(model.whatsApp.sendingTemplate, "released once the re-read is done")
    }

    /// ⛔ A TEMPLATE SEND KEEPS THE DRAFT'S HELD IMAGES (Seer, #99 and #95): the thread is re-read
    /// after the send, but the composer was not what went out, so its images survive the
    /// re-read and the next autosave still stores them.
    func testATemplateSendKeepsTheDraftsHeldImages() async {
        let image = "https://www.distronode.test/api/media/media_parity_roof"
        let stored = #"{"success":true,"draft":{"threadKey":"addr:14165550177","body":"On my way.","#
            + #""subject":null,"mediaUrls":[""# + image + #""],"updatedAt":"2026-11-05T14:30:00.000Z"}}"#
        let transport = ParityTransport()
        transport.on(.get, "/messages/drafts", 200, stored)
        transport.on(.put, "/messages/drafts", 200, stored)
        transport.on(.post, "/messages/send", 200, ParityFixtures.sent)
        let model = await closedThread(transport)
        await model.restoreDraft()
        XCTAssertEqual(model.current?.heldAttachments, [image])
        await model.loadWhatsAppTemplates()
        guard case let .ready(templates) = model.whatsApp.templates, let reminder = templates.first else {
            return XCTFail("no template")
        }

        let sent = await model.sendWhatsAppTemplate(reminder, variables: ["Ada", "Friday"])

        XCTAssertTrue(sent)
        XCTAssertEqual(model.current?.heldAttachments, [image], "the re-read keeps the held image")
        await model.persistDraft("On my way.")
        let saved = transport.requests(to: "/messages/drafts").last { $0.method == .put }
        XCTAssertEqual(saved?.json["mediaUrls"] as? [String], [image])
    }

    /// ⛔ A BLANK VARIABLE SENDS NOTHING.
    func testABlankVariableSendsNothing() async {
        let transport = ParityTransport()
        let model = await closedThread(transport)
        await model.loadWhatsAppTemplates()
        guard case let .ready(templates) = model.whatsApp.templates, let reminder = templates.first else {
            return XCTFail("no template")
        }

        let sent = await model.sendWhatsAppTemplate(reminder, variables: ["Ada", "  "])

        XCTAssertFalse(sent)
        XCTAssertTrue(transport.requests(to: "/messages/send").isEmpty)
    }

    /// The server's refusal is said in the sheet, and the sheet stays.
    func testARefusedTemplateIsSaid() async {
        let transport = ParityTransport()
        transport.on(.post, "/messages/send", 400, #"{"error":"Template variables do not match."}"#)
        let model = await closedThread(transport)
        await model.loadWhatsAppTemplates()
        guard case let .ready(templates) = model.whatsApp.templates, let reminder = templates.first else {
            return XCTFail("no template")
        }

        let sent = await model.sendWhatsAppTemplate(reminder, variables: ["Ada", "Friday"])

        XCTAssertFalse(sent)
        XCTAssertEqual(model.whatsApp.templateFailure?.message, "Template variables do not match.")
        XCTAssertFalse(model.whatsApp.sendingTemplate)
    }

    /// ⛔ A REFUSAL BELONGS TO ITS SEND (Seer, #99): reopening the sheet or choosing another
    /// template starts clean instead of showing the last send's error on a new form.
    func testARefusalIsGoneWhenTheSheetReopensOrAnotherTemplateIsChosen() async {
        let transport = ParityTransport()
        transport.on(.post, "/messages/send", 400, #"{"error":"Template variables do not match."}"#)
        let model = await closedThread(transport)
        await model.loadWhatsAppTemplates()
        guard case let .ready(templates) = model.whatsApp.templates, let reminder = templates.first else {
            return XCTFail("no template")
        }

        _ = await model.sendWhatsAppTemplate(reminder, variables: ["Ada", "Friday"])
        XCTAssertNotNil(model.whatsApp.templateFailure)
        model.clearTemplateFailure()
        XCTAssertNil(model.whatsApp.templateFailure, "another template was chosen")

        _ = await model.sendWhatsAppTemplate(reminder, variables: ["Ada", "Friday"])
        XCTAssertNotNil(model.whatsApp.templateFailure)
        await model.loadWhatsAppTemplates()
        XCTAssertNil(model.whatsApp.templateFailure, "the sheet was opened again")
    }

    func testTheVariableCountIsTheServersElseTheHighestPlaceholder() throws {
        let counted = try Self.template(body: "Hi {{1}}", variableCount: 3)
        let uncounted = try Self.template(body: "Hi {{1}}, see you {{3}} at {{2}}.", variableCount: nil)
        let named = try Self.template(body: "Bonjour {{first_name}}", variableCount: nil)

        XCTAssertEqual(ThreadModel.templateVariableCount(counted), 3)
        XCTAssertEqual(ThreadModel.templateVariableCount(uncounted), 3)
        XCTAssertEqual(ThreadModel.templateVariableCount(named), 0)
        XCTAssertTrue(ThreadModel.templateComplete(uncounted, ["a", "b", "c"]))
        XCTAssertFalse(ThreadModel.templateComplete(uncounted, ["a", "b"]))
    }

    private static func template(body: String, variableCount: Int?) throws -> WhatsAppTemplate {
        let count = variableCount.map(String.init) ?? "null"
        let json = #"""
        {"id":"t","senderId":null,"name":"n","language":"en_US","category":"UTILITY","status":"approved",
         "body":"\#(body)","variableCount":\#(count)}
        """#
        return try JSONDecoder().decode(WhatsAppTemplate.self, from: Data(json.utf8))
    }
}
