@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// App parity (1) and (2), DistrictCore 8.2.0: a reply goes out on the channel the
/// server's `replyOptions` name, Messenger and Instagram threads are listed, labelled and
/// answered as text, and the SMS stopgap's refusal is said in the operator's language.
@MainActor
final class InboxReplyChannelTests: XCTestCase {
    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    // MARK: - The reads

    /// ⛔ META THREADS AND THE ASSIGNMENT KEYS ARE ASKED FOR TOGETHER, on every list read.
    func testTheListAsksForMetaChannelsAndAssignments() async {
        let transport = ParityTransport()
        transport.on(.get, "/conversations", 200, ParityFixtures.conversations([]))

        _ = await ParityFixtures.inbox(transport).conversations(workspaceId: "ws_1")

        let read = transport.requests(to: "/conversations").first
        XCTAssertEqual(read?.query("metaChannels"), "1")
        XCTAssertEqual(read?.query("assignments"), "1")
    }

    // MARK: - (1) WhatsApp replies on the right channel

    /// ⛔ THE BUG THIS FIXES: `canSms` is true for a WhatsApp-only customer, so the old
    /// default answered them by SMS, which the server now refuses.
    func testAWhatsAppOnlyCustomerIsAnsweredOnWhatsAppNotSms() async throws {
        let row = ParityFixtures.row(
            threadKey: "addr:14165550177", counterpart: "+14165550177", channels: ["whatsapp"],
            canSms: true, replyOptions: #"[{"channel":"whatsapp","to":"+14165550177"}]"#
        )
        let summaries = await ParityFixtures.summaries([row])
        let conversation = try XCTUnwrap(summaries.first)
        let model = ParityFixtures.thread(ParityTransport(), targets: conversation.replyTargets)

        XCTAssertEqual(conversation.replyTargets.map(\.channel), [MessageChannel.whatsapp])
        XCTAssertEqual(model.channelName, "WhatsApp")
        XCTAssertTrue(model.canReply)
        XCTAssertFalse(model.canAttach, "WhatsApp sends are text-only")
    }

    /// The server's order is the composer's: its first option is the default, and the
    /// picker offers the rest.
    func testTheFirstReplyOptionIsTheDefaultAndThePickerOffersTheRest() async throws {
        let row = ParityFixtures.row(
            threadKey: "contact:c_1", counterpart: "+14165550177", channels: ["whatsapp", "sms"], canSms: true,
            replyOptions: #"[{"channel":"whatsapp","to":"+14165550177"},{"channel":"sms","to":"+14165550177"}]"#
        )
        let summaries = await ParityFixtures.summaries([row])
        let conversation = try XCTUnwrap(summaries.first)
        let model = ParityFixtures.thread(ParityTransport(), targets: conversation.replyTargets)

        XCTAssertEqual(model.replyTargets.map(\.channel), [MessageChannel.whatsapp, MessageChannel.sms])
        XCTAssertEqual(model.selectedReplyIndex, 0)
        XCTAssertEqual(model.channelName, "WhatsApp")
    }

    /// ⛔ `[]` IS NO REPLY BOX, whatever `canSms` says.
    func testNoReplyOptionsMeansNoReplyBox() async throws {
        let row = ParityFixtures.row(
            threadKey: "addr:14165550177", counterpart: "+14165550177", channels: ["sms"],
            canSms: true, replyOptions: "[]"
        )
        let summaries = await ParityFixtures.summaries([row])
        let conversation = try XCTUnwrap(summaries.first)
        let model = ParityFixtures.thread(ParityTransport(), targets: conversation.replyTargets)

        XCTAssertTrue(conversation.replyTargets.isEmpty)
        XCTAssertFalse(model.canReply)
        XCTAssertNil(model.channelName)
    }

    /// ⛔ A CHANNEL THIS BUILD DOES NOT KNOW IS SKIPPED, never offered.
    func testAnUnknownReplyChannelIsSkipped() async throws {
        let row = ParityFixtures.row(
            threadKey: "addr:fb:5550101", counterpart: "fb:5550101", channels: ["messenger"],
            replyOptions: #"[{"channel":"carrier_pigeon","to":"x"},{"channel":"messenger","to":"fb:5550101"}]"#
        )
        let summaries = await ParityFixtures.summaries([row])
        let conversation = try XCTUnwrap(summaries.first)

        XCTAssertEqual(conversation.replyTargets, [ReplyTarget(to: "fb:5550101", channel: MessageChannel.messenger)])
    }

    /// The single-target paths (a push, a notification reply, a new conversation) take
    /// the message's own channel, and one `messages/send` cannot use draws no box.
    func testASingleTargetOnAChannelNobodyCanSendOnIsDropped() {
        XCTAssertNil(InboxParity.replyable(ReplyTarget(to: "+14165550177", channel: "voicemail")))
        XCTAssertEqual(
            InboxParity.replyable([
                ReplyTarget(to: "ig:5550102", channel: MessageChannel.instagram),
                ReplyTarget(to: "x", channel: "fax"),
            ]),
            [ReplyTarget(to: "ig:5550102", channel: MessageChannel.instagram)]
        )
    }

    /// ⛔ THE STOPGAP'S 409 IS SAID, in English as the server wrote it and in French from
    /// the catalog, and nothing is re-sent.
    func testTheSmsStopgapRefusalIsSaidInBothLanguages() async {
        let english = "This customer writes on WhatsApp, Messenger or Instagram and has never texted this number."
        let refusal = #"{"error":"\#(english)","code":"sms_reply_not_customer_channel"}"#
        for (locale, expected) in [
            (L10nLocale.en, english),
            (
                L10nLocale.frCA,
                "Ce client écrit sur WhatsApp, Messenger ou Instagram et n'a jamais envoyé de texto à ce numéro. "
                    + "Répondez-lui sur son canal à partir de la notification, de la boîte de réception Web "
                    + "ou d'une version à jour de l'application."
            ),
        ] {
            let transport = ParityTransport()
            transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
            transport.on(.post, "/messages/send", 409, refusal)
            let model = ParityFixtures.thread(
                transport,
                targets: [ReplyTarget(to: "+14165550177", channel: MessageChannel.sms)]
            )
            await model.load()
            model.composerTextChanged("On my way.")

            L10nRuntime.locale = locale
            await model.send()
            L10nRuntime.locale = .en

            XCTAssertEqual(model.current?.sendFailure?.message, expected, "\(locale)")
            XCTAssertEqual(transport.requests(to: "/messages/send").count, 1, "never re-sent")
        }
    }

    // MARK: - (2) Messenger and Instagram

    /// ⛔ TEXT ONLY, ON MESSENGER, TO THE `fb:` ADDRESS, with no subject and no images.
    func testAMessengerReplyGoesOutOnMessengerAsText() async throws {
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.post, "/messages/send", 200, ParityFixtures.sent)
        let model = ParityFixtures.thread(
            transport,
            threadKey: "addr:fb:5550101",
            targets: [ReplyTarget(to: "fb:5550101", channel: MessageChannel.messenger)]
        )
        await model.load()
        model.composerTextChanged("We are open Saturday.")

        XCTAssertFalse(model.canAttach)
        XCTAssertFalse(model.requiresSubject)
        await model.send()

        let send = try XCTUnwrap(transport.requests(to: "/messages/send").first)
        XCTAssertEqual(send.json["channel"] as? String, "messenger")
        XCTAssertEqual(send.json["to"] as? String, "fb:5550101")
        XCTAssertNil(send.json["subject"])
        XCTAssertTrue((send.json["mediaUrls"] as? [String] ?? []).isEmpty)
    }

    func testMessengerAndInstagramAreNamedInBothLanguages() {
        XCTAssertEqual(ThreadChannelName.of(MessageChannel.messenger), "Messenger")
        XCTAssertEqual(ThreadChannelName.of(MessageChannel.instagram), "Instagram")
        XCTAssertEqual(french { ThreadChannelName.of(MessageChannel.messenger) }, "Messenger")
        XCTAssertEqual(french { ThreadChannelName.of(MessageChannel.instagram) }, "Instagram")
    }

    /// ⛔ A SINGLE-CHANNEL META OR WHATSAPP ROW IS LABELLED; an SMS, email or voicemail
    /// one still is not.
    func testASingleChannelRowIsLabelledOnlyWhenItIsNotSmsEmailOrVoicemail() async {
        let rows = [
            ParityFixtures.row(threadKey: "a", counterpart: "fb:1", channels: ["messenger"], replyOptions: "[]"),
            ParityFixtures.row(threadKey: "b", counterpart: "ig:2", channels: ["instagram"], replyOptions: "[]"),
            ParityFixtures.row(threadKey: "c", counterpart: "+1416", channels: ["whatsapp"], replyOptions: "[]"),
            ParityFixtures.row(threadKey: "d", counterpart: "+1416", channels: ["sms"], replyOptions: "[]"),
            ParityFixtures.row(threadKey: "e", counterpart: "a@b.c", channels: ["email"], replyOptions: "[]"),
            ParityFixtures.row(threadKey: "f", counterpart: "+1416", channels: ["voicemail"], replyOptions: "[]"),
        ]
        let labels = await ParityFixtures.summaries(rows).map { ConversationDisplay($0).channelLabels }

        XCTAssertEqual(labels, [["MESSENGER"], ["INSTAGRAM"], ["WHATSAPP"], [], [], []])
    }

    /// ⛔ THE HELD IMAGES' SENTENCE NAMES THE CHANNEL, SAYS THEY ARE KEPT, AND OFFERS SMS ONLY
    /// WHERE THERE IS SMS (xhigh review): "removed" said they were gone, and "switch back to SMS"
    /// named a control a thread without SMS does not have.
    func testTheHeldImagesSentenceNamesTheChannelAndOffersSmsOnlyWhereThereIsSms() {
        XCTAssertEqual(
            ThreadModel.attachmentsHeld(count: 2, channel: MessageChannel.whatsapp, smsOffered: true),
            "2 images stay in the draft: WhatsApp replies are text-only for now, so they will not be sent. "
                + "To send images, switch to SMS."
        )
        XCTAssertEqual(
            ThreadModel.attachmentsHeld(count: 1, channel: MessageChannel.instagram, smsOffered: false),
            "The image stays in the draft: Messenger and Instagram replies are text-only for now, "
                + "so it will not be sent."
        )
        XCTAssertEqual(
            ThreadModel.attachmentsHeld(count: 1, channel: MessageChannel.email, smsOffered: false),
            "The image stays in the draft: email replies cannot carry attachments, so it will not be sent."
        )
        french {
            XCTAssertEqual(
                ThreadModel.attachmentsHeld(count: 1, channel: MessageChannel.whatsapp, smsOffered: true),
                "1 image reste dans le brouillon\u{00A0}: les réponses WhatsApp sont pour l'instant en texte "
                    + "seulement, elle ne sera donc pas envoyée. Pour envoyer des images, passez au texto."
            )
            XCTAssertEqual(
                ThreadModel.attachmentsHeld(count: 3, channel: MessageChannel.email, smsOffered: false),
                "3 images restent dans le brouillon\u{00A0}: les réponses par courriel n'acceptent pas les "
                    + "pièces jointes, elles ne seront donc pas envoyées."
            )
        }
    }

    /// ⛔ A DRAFT RESTORED WHILE THE THREAD CANNOT BE READ KEEPS ITS IMAGES FOR THE RETRY (xhigh
    /// review): the restore is latched, so it puts them on the model, and the retry's re-read
    /// shows them.
    func testADraftRestoredWhileTheThreadCannotBeReadKeepsItsImagesForTheRetry() async {
        let image = "https://www.distronode.test/api/media/media_parity_roof"
        let stored = #"{"success":true,"draft":{"threadKey":"addr:14165550177","body":"On my way.","#
            + #""subject":null,"mediaUrls":[""# + image + #""],"updatedAt":"2026-11-05T14:30:00.000Z"}}"#
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 500, #"{"error":"unavailable"}"#)
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.get, "/messages/drafts", 200, stored)
        let model = ParityFixtures.thread(
            transport,
            targets: [ReplyTarget(to: "+14165550177", channel: MessageChannel.sms)]
        )

        await model.open()
        XCTAssertNil(model.current, "the first read failed")
        XCTAssertEqual(model.composerText, "On my way.")
        await model.open()

        XCTAssertEqual(model.current?.attachments, [image])
        XCTAssertEqual(transport.requests(to: "/messages/drafts").count, 1, "the restore ran once")
    }

    /// ⛔ A SAVE WHILE THE THREAD CANNOT BE SHOWN KEEPS THE DRAFT'S IMAGES (Seer, #99): a re-read
    /// that fails leaves no content, and the autosave writes the images last shown.
    func testASaveAfterAFailedReReadKeepsTheDraftsImages() async {
        let image = "https://www.distronode.test/api/media/media_parity_roof"
        let stored = #"{"success":true,"draft":{"threadKey":"addr:14165550177","body":"On my way.","#
            + #""subject":null,"mediaUrls":[""# + image + #""],"updatedAt":"2026-11-05T14:30:00.000Z"}}"#
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.get, "/timeline", 500, #"{"error":"unavailable"}"#)
        transport.on(.get, "/messages/drafts", 200, stored)
        transport.on(.put, "/messages/drafts", 200, stored)
        let model = ParityFixtures.thread(
            transport,
            targets: [ReplyTarget(to: "+14165550177", channel: MessageChannel.sms)]
        )
        await model.load()
        await model.restoreDraft()
        await model.load()
        XCTAssertNil(model.current, "the re-read failed")

        await model.persistDraft("On my way.")
        let saved = transport.requests(to: "/messages/drafts").last { $0.method == .put }
        XCTAssertEqual(saved?.json["mediaUrls"] as? [String], [image])
    }

    /// ⛔ A DRAFT'S IMAGES ARE NEVER SENT ON A TEXT-ONLY CHANNEL, AND NEVER LOST (Seer, #95 and
    /// #99). Restored onto a WhatsApp default they are held with the channel's sentence; the
    /// autosave keeps them in the stored draft; a switch to SMS returns them as chips, and a
    /// switch back holds them again.
    func testARestoredDraftsImagesAreHeldOnATextOnlyChannelAndKeptInTheDraft() async {
        let image = "https://www.distronode.test/api/media/media_parity_roof"
        let stored = #"{"success":true,"draft":{"threadKey":"addr:14165550177","body":"On my way.","#
            + #""subject":null,"mediaUrls":[""# + image + #""],"updatedAt":"2026-11-05T14:30:00.000Z"}}"#
        let whatsAppSentence = "The image stays in the draft: WhatsApp replies are text-only for now, "
            + "so it will not be sent. To send images, switch to SMS."
        let transport = ParityTransport()
        transport.on(.get, "/timeline", 200, ParityFixtures.timeline)
        transport.on(.get, "/messages/drafts", 200, stored)
        transport.on(.put, "/messages/drafts", 200, stored)
        let model = ParityFixtures.thread(transport, targets: [
            ReplyTarget(to: "+14165550177", channel: MessageChannel.whatsapp),
            ReplyTarget(to: "+14165550177", channel: MessageChannel.sms),
        ])
        await model.load()
        await model.restoreDraft()

        XCTAssertEqual(model.composerText, "On my way.")
        XCTAssertEqual(model.current?.attachments, [])
        XCTAssertEqual(model.current?.heldAttachments, [image])
        XCTAssertEqual(model.current?.channelNote, whatsAppSentence)

        await model.persistDraft("On my way, see you at nine.")
        let saved = transport.requests(to: "/messages/drafts").last { $0.method == .put }
        XCTAssertEqual(saved?.json["mediaUrls"] as? [String], [image], "the autosave keeps the held image")

        model.selectReplyTarget(1)
        XCTAssertEqual(model.current?.attachments, [image], "SMS carries it again")
        XCTAssertEqual(model.current?.heldAttachments, [])
        XCTAssertNil(model.current?.channelNote)

        model.selectReplyTarget(0)
        XCTAssertEqual(model.current?.attachments, [])
        XCTAssertEqual(model.current?.heldAttachments, [image])
        XCTAssertEqual(model.current?.channelNote, whatsAppSentence)
    }

    // MARK: - The Watch

    /// ⛔ THE WATCH NEVER OFFERS A REPLY THE PHONE WOULD SEND ON THE WRONG CHANNEL. It
    /// reads the phone's snapshot, and the phone answers a wrist reply with the row's
    /// `replyTarget`: WhatsApp for a WhatsApp-only customer, and no reply at all for `[]`
    /// or only unknown channels.
    func testTheWatchRepliesOnTheRowsChannelOrNotAtAll() async {
        let rows = [
            ParityFixtures.row(
                threadKey: "wa", counterpart: "+14165550177", channels: ["whatsapp"], canSms: true,
                replyOptions: #"[{"channel":"whatsapp","to":"+14165550177"}]"#
            ),
            ParityFixtures.row(
                threadKey: "none", counterpart: "+14165550177", channels: ["sms"], canSms: true, replyOptions: "[]"
            ),
            ParityFixtures.row(
                threadKey: "unknown", counterpart: "x:1", channels: ["fax"],
                replyOptions: #"[{"channel":"fax","to":"x:1"}]"#
            ),
        ]
        let conversations = await ParityFixtures.summaries(rows)
        let snapshot: [WatchSnapshot.Conversation] = conversations.map {
            WatchSnapshotComposer.conversation($0, workspaceId: "ws_1")
        }

        XCTAssertEqual(conversations.first?.replyTarget?.channel, MessageChannel.whatsapp)
        XCTAssertEqual(snapshot.map(\.canReply), [true, false, false])
    }
}
