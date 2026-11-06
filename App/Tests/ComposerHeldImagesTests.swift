@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The max review of #99 and #95, the composer's images: nothing is lost across a channel
/// switch, a text-only send keeps the held images, Send waits for an upload, and the held
/// chips say what they are and can be removed.
@MainActor
final class ComposerHeldImagesTests: XCTestCase {
    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    private static let roof = "https://www.distronode.test/api/media/media_parity_roof"
    private static let gutter = "https://www.distronode.test/api/media/media_parity_gutter"
    private static let sms = ReplyTarget(to: "+14165550177", channel: MessageChannel.sms)
    private static let whatsApp = ReplyTarget(to: "+14165550177", channel: MessageChannel.whatsapp)
    private static let png = Data([0x89, 0x50, 0x4E, 0x47])

    private static func uploaded(_ url: String) -> String {
        #"{"success":true,"media":{"id":"m","mimeType":"image/png","sizeBytes":4,"url":""# + url + #""}}"#
    }

    private static func draft(_ urls: [String], body: String = "On my way.") -> String {
        let list = urls.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"success":true,"draft":{"threadKey":"addr:14165550177","body":""# + body
            + #"","subject":null,"mediaUrls":["# + list + #"],"updatedAt":"2026-11-05T14:30:00.000Z"}}"#
    }

    // MARK: - An upload across a channel switch

    /// ⛔ AN UPLOAD THAT LANDS AFTER A SWITCH TO WHATSAPP IS HELD, NOT LOST (max review): it
    /// used to be staged on a channel that cannot carry it, drawn nowhere, and sent with nothing.
    func testAnUploadThatLandsAfterASwitchIsHeldAndComesBackOnSms() async {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/media", 200, Self.uploaded(Self.roof))
        let gate = transport.hold(.post, "/messages/media")
        let model = ParityFixtures.thread(transport, targets: [Self.sms, Self.whatsApp])
        await model.load()

        let upload = Task { await model.attach(Self.png, mimeType: "image/png") }
        await waitUntil { transport.requests(to: "/messages/media").count == 1 }
        model.selectReplyTarget(1)
        gate.open()
        await upload.value

        XCTAssertEqual(model.current?.attachments, [])
        XCTAssertEqual(model.current?.heldAttachments, [Self.roof])
        XCTAssertEqual(
            model.current?.channelNote,
            "The image stays in the draft: WhatsApp replies are text-only for now, so it will not be sent. "
                + "To send images, switch to SMS."
        )
        XCTAssertEqual(model.current?.attaching, false)

        model.selectReplyTarget(0)
        XCTAssertEqual(model.current?.attachments, [Self.roof], "SMS carries it again")
        XCTAssertEqual(model.current?.heldAttachments, [])
    }

    /// ⛔ A PHOTO READ AFTER THE SWITCH IS UPLOADED AND HELD (max review): the picker reads its
    /// bytes first, and a switch during that read used to drop the photo without a word.
    func testAPhotoHandedOverAfterTheSwitchIsHeldNotDropped() async {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/media", 200, Self.uploaded(Self.roof))
        let model = ParityFixtures.thread(transport, targets: [Self.sms, Self.whatsApp])
        await model.load()
        model.selectReplyTarget(1)

        await model.attach(Self.png, mimeType: "image/png")

        XCTAssertEqual(model.current?.heldAttachments, [Self.roof])
        XCTAssertEqual(transport.requests(to: "/messages/media").count, 1)
    }

    /// ⛔ A ROLE THAT CANNOT WRITE STILL UPLOADS NOTHING: the gate moved from the channel to the role.
    func testAViewerStillUploadsNothing() async {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        let model = ParityFixtures.thread(transport, role: .viewer, targets: [Self.sms])
        await model.load()

        await model.attach(Self.png, mimeType: "image/png")

        XCTAssertTrue(transport.requests(to: "/messages/media").isEmpty)
    }

    /// ⛔ AN UPLOAD THAT LANDS WHILE THE THREAD IS RE-READ IS PUT BACK BY THE RE-READ (max review):
    /// with no content on screen it used to be dropped.
    func testAnUploadThatLandsDuringAReReadIsKept() async {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        let model = ParityFixtures.thread(transport, targets: [Self.sms])
        await model.load()
        let reRead = transport.hold(.get, "/timeline")

        let load = Task { await model.load() }
        await waitUntil { transport.requests(to: "/timeline").count == 2 }
        XCTAssertNil(model.current)
        model.land(Self.roof)
        reRead.open()
        await load.value

        XCTAssertEqual(model.current?.attachments, [Self.roof])
    }

    // MARK: - Sending

    /// ⛔ A TEXT-ONLY SEND KEEPS THE HELD IMAGES (max review): the sentence says they stay, and
    /// the send used to throw them away with the draft. ⚠️ The text goes, so the stored draft is
    /// deleted (a blank draft is a DELETE); the images stay in the composer, sentence and all.
    func testATextOnlySendKeepsTheHeldImages() async throws {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.get, "/messages/drafts", 200, Self.draft([Self.roof]))
        transport.on(.post, "/messages/send", 200, ParityFixtures.sent)
        transport.on(.delete, "/messages/drafts", 200, #"{"success":true}"#)
        let model = ParityFixtures.thread(transport, targets: [Self.whatsApp, Self.sms])
        await model.open()
        XCTAssertEqual(model.current?.heldAttachments, [Self.roof])

        await model.send()

        let send = try XCTUnwrap(transport.requests(to: "/messages/send").first)
        XCTAssertTrue((send.json["mediaUrls"] as? [String] ?? []).isEmpty, "nothing held is sent")
        XCTAssertEqual(model.composerText, "")
        XCTAssertEqual(model.current?.heldAttachments, [Self.roof], "the held image stays")
        XCTAssertNotNil(model.current?.channelNote, "and so does its sentence")
        XCTAssertEqual(transport.requests(to: "/messages/drafts").filter { $0.method == .delete }.count, 1)

        model.selectReplyTarget(1)
        XCTAssertEqual(model.current?.attachments, [Self.roof], "SMS carries it")
    }

    /// ⛔ THE SEND ITSELF NEVER CARRIES IMAGES ON A CHANNEL THAT CANNOT (max review), whatever the
    /// staged list holds: the backstop behind the hold.
    func testASendOffSmsCarriesNoImagesEvenIfSomeAreStaged() async throws {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/send", 200, ParityFixtures.sent)
        transport.on(.delete, "/messages/drafts", 200, #"{"success":true}"#)
        let model = ParityFixtures.thread(transport, targets: [Self.whatsApp])
        await model.load()
        var content = try XCTUnwrap(model.current)
        content.attachments = [Self.roof]
        model.setContent(content)
        model.composerTextChanged("On my way.")

        await model.send()

        let send = try XCTUnwrap(transport.requests(to: "/messages/send").first)
        XCTAssertTrue((send.json["mediaUrls"] as? [String] ?? []).isEmpty)
    }

    /// ⛔ SEND WAITS FOR AN UPLOAD (max review): a send begun mid-upload took the list without the
    /// image, and the clear after it wiped the image when it landed.
    func testSendIsRefusedWhileAnImageUploads() async {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/media", 200, Self.uploaded(Self.roof))
        let gate = transport.hold(.post, "/messages/media")
        let model = ParityFixtures.thread(transport, targets: [Self.sms])
        await model.load()
        model.composerTextChanged("Here is the roof.")

        let upload = Task { await model.attach(Self.png, mimeType: "image/png") }
        await waitUntil { transport.requests(to: "/messages/media").count == 1 }
        await model.send()
        gate.open()
        await upload.value

        XCTAssertTrue(transport.requests(to: "/messages/send").isEmpty, "no send while attaching")
        XCTAssertEqual(model.current?.attachments, [Self.roof])
        XCTAssertEqual(model.composerText, "Here is the roof.")
    }

    /// ⛔ ONLY THE IMAGES THAT WENT OUT ARE CLEARED (max review): one that landed while the send
    /// was in flight stays staged for the next reply.
    func testAnImageThatLandsMidSendStaysStaged() async throws {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/media", 200, Self.uploaded(Self.roof))
        transport.on(.post, "/messages/media", 200, Self.uploaded(Self.gutter))
        transport.on(.delete, "/messages/drafts", 200, #"{"success":true}"#)
        let model = ParityFixtures.thread(transport, targets: [Self.sms])
        await model.load()
        await model.attach(Self.png, mimeType: "image/png")
        model.composerTextChanged("Here is the roof.")
        transport.on(.post, "/messages/send", 200, ParityFixtures.sent)
        let sending = transport.hold(.post, "/messages/send")

        let send = Task { await model.send() }
        await waitUntil { transport.requests(to: "/messages/send").count == 1 }
        await model.attach(Self.png, mimeType: "image/png")
        sending.open()
        await send.value

        let sent = try XCTUnwrap(transport.requests(to: "/messages/send").first)
        XCTAssertEqual(sent.json["mediaUrls"] as? [String], [Self.roof])
        XCTAssertEqual(model.current?.attachments, [Self.gutter], "the late image is kept")
    }

    // MARK: - The held chips

    /// ⛔ HELD IMAGES ARE NAMED FOR VOICEOVER WITH THE CHANNEL THEY ARE NOT SENT ON, in both
    /// languages, and Remove drops one, recounts the sentence and writes the draft (max review;
    /// Sean, "Dimmed chips with Remove"). On a thread with no SMS reply, too.
    func testAHeldChipIsNamedAndItsRemoveUpdatesTheDraft() async throws {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.get, "/messages/drafts", 200, Self.draft([Self.roof, Self.gutter]))
        transport.on(.put, "/messages/drafts", 200, Self.draft([Self.gutter]))
        let model = ParityFixtures.thread(transport, targets: [Self.whatsApp])
        await model.open()

        XCTAssertEqual(model.current?.heldAttachments, [Self.roof, Self.gutter])
        XCTAssertEqual(
            model.current?.channelNote,
            "2 images stay in the draft: WhatsApp replies are text-only for now, so they will not be sent."
        )
        XCTAssertEqual(InboxCopy.attachmentHeld, "Held")
        XCTAssertEqual(model.heldAttachmentLabel, "Image held, not sent on WhatsApp")
        XCTAssertEqual(french { InboxCopy.attachmentHeld }, "En attente")
        XCTAssertEqual(french { model.heldAttachmentLabel }, "Image en attente, non envoyée par WhatsApp")

        model.removeAttachment(Self.roof)

        XCTAssertEqual(model.current?.heldAttachments, [Self.gutter])
        XCTAssertEqual(
            model.current?.channelNote,
            "The image stays in the draft: WhatsApp replies are text-only for now, so it will not be sent."
        )
        XCTAssertNotNil(model.autosaveTask, "the removal arms the autosave")
        await model.flushDraft()
        let saved = try XCTUnwrap(transport.requests(to: "/messages/drafts").last { $0.method == .put })
        XCTAssertEqual(saved.json["mediaUrls"] as? [String], [Self.gutter])

        model.removeAttachment(Self.gutter)
        XCTAssertEqual(model.current?.heldAttachments, [])
        XCTAssertNil(model.current?.channelNote, "nothing held, nothing said")
    }

    /// ⛔ REMOVING AN IMAGE ON A BLANK BOX DELETES NO UNREAD DRAFT (Seer, #99, 4489056023): the
    /// draft read failed, so the server may hold a reply nobody has seen.
    func testRemovingAnImageAfterAFailedDraftReadDeletesNothing() async {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.get, "/messages/drafts", 500, #"{"error":"unavailable"}"#)
        transport.on(.post, "/messages/media", 200, Self.uploaded(Self.roof))
        transport.on(.delete, "/messages/drafts", 200, #"{"success":true}"#)
        let model = ParityFixtures.thread(transport, targets: [Self.sms])
        await model.open()
        XCTAssertNotNil(model.current?.draftFailure, "the draft could not be read")
        await model.attach(Self.png, mimeType: "image/png")

        model.removeAttachment(Self.roof)
        await model.flushDraft()

        XCTAssertEqual(model.current?.attachments, [])
        XCTAssertTrue(transport.requests(to: "/messages/drafts").filter { $0.method == .delete }.isEmpty)
    }

    /// ⛔ A DRAFT RESTORED AFTER AN IMAGE WAS ATTACHED IS MERGED WITH IT, NOT PUT IN ITS PLACE
    /// (Seer, #99, 4489180780): deduplicated by URL, the operator's own image first.
    func testARestoredDraftsImagesAreMergedWithOnesAttachedMeanwhile() async {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.get, "/messages/drafts", 200, Self.draft([Self.roof, Self.gutter]))
        transport.on(.post, "/messages/media", 200, Self.uploaded(Self.gutter))
        let model = ParityFixtures.thread(transport, targets: [Self.sms])
        await model.load()
        let gate = transport.hold(.get, "/messages/drafts")

        let restore = Task { await model.restoreDraft() }
        await waitUntil { transport.requests(to: "/messages/drafts").count == 1 }
        await model.attach(Self.png, mimeType: "image/png")
        gate.open()
        await restore.value

        XCTAssertEqual(model.current?.attachments, [Self.gutter, Self.roof])
    }

    /// ⛔ AND ON A TEXT-ONLY CHANNEL THE MERGED IMAGES ARE HELD TOGETHER, counted in one sentence.
    func testARestoredDraftsImagesAreMergedWithHeldOnes() async throws {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.get, "/messages/drafts", 200, Self.draft([Self.roof]))
        let model = ParityFixtures.thread(transport, targets: [Self.whatsApp])
        await model.load()
        var content = try XCTUnwrap(model.current)
        content.heldAttachments = [Self.gutter]
        model.setContent(content)

        await model.restoreDraft()

        XCTAssertEqual(model.current?.heldAttachments, [Self.gutter, Self.roof])
        XCTAssertEqual(
            model.current?.channelNote,
            "2 images stay in the draft: WhatsApp replies are text-only for now, so they will not be sent."
        )
    }

    /// ⚠️ ON EMAIL THE CHIP SAYS "BY EMAIL", and French « par courriel », lower case.
    func testAHeldChipOnEmailSaysByEmail() {
        let model = ParityFixtures.thread(
            ParityTransport(),
            targets: [ReplyTarget(to: "maya@example.test", channel: MessageChannel.email)]
        )

        XCTAssertEqual(model.heldAttachmentLabel, "Image held, not sent by email")
        XCTAssertEqual(french { model.heldAttachmentLabel }, "Image en attente, non envoyée par courriel")
    }
}
