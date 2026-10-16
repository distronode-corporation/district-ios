import DistrictData
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The reply box: text, attachments, the AI draft, and send.
///
/// ⛔ THE FIELD, THEN ONE ROW OF CONTROLS (3.0.1 visual QA). The field takes the whole width;
/// under it the photo, file and AI draft controls are borderless SF Symbol buttons that name
/// themselves to VoiceOver (and on hover with a pointer), and Send closes the row. Before, the
/// four sat in a column beside the field in four different styles and the field was squeezed
/// to a few words. The same layout as District AI for Mac 3.0.1.
///
/// ⛔ SEND IS A PRESS, OR COMMAND-RETURN ON A HARDWARE KEYBOARD, AND NEVER RETURN. Return in
/// the field is a new line: a reply is billed carrier segments to a customer, and a stray
/// Return must not send half of one. So the field has no `onSubmit` and Send carries
/// `.keyboardShortcut(.return, modifiers: .command)`, never `.defaultAction`.
///
/// ⛔ TWO OF THESE FOUR CONTROLS SPEND MONEY AND BOTH ARE DISABLED WHILE IN FLIGHT.
/// A send is billable carrier segments capped at 30/min per workspace; an AI draft
/// is a Vertex generation capped at 20/min. A double tap on either must not become
/// two of them.
///
/// ⛔ THE TEXT IS BOUND THROUGH ``ThreadModel/composerTextChanged(_:)``, NOT THROUGH
/// `@Bindable`. That method is the only thing that arms an autosave, and a plain
/// binding would let the AI draft's own write, and the restore's, each arm one — the
/// restore's would immediately save back the exact bytes it had just read. There must
/// be no second copy of this text: a `@State` here means the box shows one thing and
/// the server stores another.
struct ComposerBar: View {
    let model: ThreadModel
    let content: ThreadContent

    /// ⚠️ CLEARED AS SOON AS IT IS READ, so picking the SAME photo twice in a row
    /// still fires. A `PhotosPickerItem` that stays selected is equal to itself and
    /// `onChange` would not run a second time.
    @State private var picked: PhotosPickerItem?

    /// The Files picker for an image saved as a file rather than in the photo library.
    @State private var choosingFile = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            channelStrip
            channelNoteStrip
            draftStrip
            draftNoticeStrip
            failureStrip
            subjectField
            attachmentStrip
            field
            // ⚠️ ONE ROW AT EVERY TEXT SIZE: the three controls are icons, so only Send's
            // word grows, and the field above keeps the whole width it needs at AX5.
            HStack(spacing: DistrictSpacing.row) {
                attachControl
                draftControl
                Spacer(minLength: DistrictSpacing.tight)
                sendControl
            }
            .imageScale(.large)
        }
        .padding(.horizontal, DistrictSpacing.gutter)
        .padding(.vertical, DistrictSpacing.row)
        .background(colors.surface)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task { await read(item) }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            Task { await readFile(result) }
        }
    }

    // MARK: - Pieces

    /// Which channel this reply goes out on, and to which address.
    ///
    /// ⛔ THE COMPOSER NAMES BOTH, BECAUSE SILENCE HERE IS A BUG. `canSms` is true for
    /// any thread whose contact has a number on file, INCLUDING one the customer has
    /// only ever emailed, so an unlabelled reply could leave as a billable SMS to a
    /// customer who had only ever written — with nothing on screen to say so, and no
    /// way to tell afterwards except the thread itself.
    ///
    /// ⛔ AND IT OFFERS RATHER THAN MERELY STATING. `Route.thread` carries the whole
    /// `[ReplyTarget]` set rather than one `(to, channel)` pair, so the alternative
    /// address is in this process and the picker below is the switch.
    ///
    /// ⚠️ THE PICKER DRAWS ONLY FOR TWO OR MORE TARGETS, AND ONE TARGET KEEPS THE
    /// STATIC BADGE. A control offering a single option invites the operator to hunt
    /// for the other one, and the badge is still the thing that stops the channel
    /// being hidden.
    ///
    /// ⚠️ WHATSAPP CANNOT APPEAR HERE AT ALL, AND THAT IS A WIRE GAP RATHER THAN AN
    /// OMISSION IN THIS PICKER. `conversations` publishes no `canWhatsapp`, so
    /// ``ConversationSummary/replyTargets`` can never produce a WhatsApp target and a
    /// WhatsApp-only thread arrives marked `canSms: true` — it goes out as SMS. Fixing
    /// it needs a server field, not a client rule.
    @ViewBuilder
    private var channelStrip: some View {
        if model.replyTargets.count > 1 {
            channelPicker
        } else if let channel = model.channelName {
            staticChannel(channel)
        }
    }

    /// ⛔ A SEGMENTED PICKER RATHER THAN A MENU, BECAUSE THE CHOICE DECIDES WHETHER
    /// THE MESSAGE COSTS MONEY. Both options are visible at rest, so the operator can
    /// see which one is armed without opening anything — a collapsed menu shows the
    /// current value and hides that there was a decision.
    ///
    /// ⚠️ THE LABELS ARE THE CHANNEL NAMES AND THE ADDRESS SITS UNDER THEM, not inside
    /// the segments. Two full email addresses in one segmented control are unreadable
    /// at any width a phone has.
    ///
    /// ⛔ THE BINDING GOES THROUGH ``ThreadModel/selectReplyTarget(_:)`` AND IS A
    /// CLOSURE LITERAL, NEVER A BARE METHOD REFERENCE. That method is the only thing
    /// that drops staged images and writes the note about it; and a bare
    /// MainActor-isolated method as a `Binding` setter aborts the compiler in IRGen
    /// under Swift 6 (see the custom lint rule in `.swiftlint.yml`).
    private var channelPicker: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            DistrictEyebrow(text: InboxCopy.sendOn)
            Picker(InboxCopy.sendOn, selection: selectedChannel) {
                // ⚠️ ITERATED BY INDEX, NOT BY `enumerated()`. A `ForEach` over
                // `Array(x.enumerated())` needs a closure taking one LABELLED TUPLE, and
                // Swift dropped implicit tuple splat in Swift 3 — the two-parameter form
                // that reads naturally does not compile under the Swift 6 mode this
                // target uses. The index is also what `.tag` needs, so nothing is lost.
                ForEach(model.replyTargets.indices, id: \.self) { index in
                    Text(ThreadChannelName.of(model.replyTargets[index].channel)).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .disabled(content.sending)
            if let recipient = model.recipientName {
                recipientLine(recipient)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ THE SINGLE-TARGET CASE, UNCHANGED. It states rather than offers because
    /// there is nothing to offer, and refusing to hide which channel is in use is the
    /// part that was always load-bearing.
    private func staticChannel(_ channel: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DistrictSpacing.hairline))
            : AnyLayout(HStackLayout(spacing: DistrictSpacing.tight))
        return layout {
            DistrictBadge(text: channel, tone: .info)
            if let recipient = model.recipientName {
                recipientLine(recipient)
            }
        }
    }

    /// ⚠️ THE ADDRESS IS TRUNCATED IN THE MIDDLE, never at the end: the tail of an
    /// email address is the half that says which person it is.
    private func recipientLine(_ recipient: String) -> some View {
        Text(recipient)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.middle)
    }

    /// What a channel switch cost, said out loud.
    ///
    /// ⛔ MUTED INK AND NO DISMISS, WHICH IS WHAT SEPARATES IT FROM ``failureStrip``.
    /// Nothing went wrong: the operator moved a reply to email and the images could not
    /// come, because the email branch of `messages/send` ignores `mediaUrls`. It has no
    /// Dismiss for the reason ``draftStrip`` has none — it must not be dismissable at
    /// exactly the moment it matters, which is while the message is being composed
    /// under the belief that it still carries pictures.
    @ViewBuilder
    private var channelNoteStrip: some View {
        if let note = content.channelNote {
            Text(note)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The email subject line.
    ///
    /// ⛔ A REQUIRED FIELD ON AN EMAIL THREAD, WHICH IS WHY IT IS A CONTROL AND NOT A
    /// CAPTION. `messages/send` substitutes "Message from District" for an absent or
    /// blank subject and delivers, so this is the last place a missing one can be
    /// caught — and the send button is disabled until it holds something. It is hidden
    /// entirely on SMS, where the channel has no subject to carry.
    ///
    /// ⚠️ SEEDED WITH `Re: <the thread's newest subject>` WHERE ONE EXISTS AND LEFT
    /// EMPTY WHERE IT DOES NOT. This client does not invent a topic; see
    /// ``ReplySubject``.
    @ViewBuilder
    private var subjectField: some View {
        if model.requiresSubject {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                DistrictEyebrow(text: InboxCopy.subject)
                TextField(InboxCopy.subject, text: subject, prompt: .noPlaceholder)
                    .disabled(content.sending)
                    .districtField()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The saved reply this screen could not read.
    ///
    /// ⛔ ITS OWN STRIP, ABOVE THE OTHER ONE, AND NOT A FOURTH TENANT OF
    /// ``ThreadContent/sendFailure``. That slot is cleared by the next send, attach or
    /// generate and by its own Dismiss, so this sentence would disappear at exactly the
    /// moment it matters: while the operator is typing the reply that overwrites the
    /// one they cannot see. It has no Dismiss for the same reason.
    ///
    /// ⛔ AND THE OFFER COMES FROM THE MAPPING, NEVER FROM HERE, matching
    /// ``FailureView``. A decode failure produces the identical nothing on a second
    /// read, so ``FailureText/Action/none`` draws the sentence and no button.
    @ViewBuilder
    private var draftStrip: some View {
        if let failure = content.draftFailure {
            HStack(alignment: .top, spacing: DistrictSpacing.tight) {
                Text(failure.message)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .retry = failure.action {
                    Button(InboxCopy.tryAgain) { Task { await model.restoreDraft() } }
                        .buttonStyle(.districtGhost)
                }
            }
        }
    }

    /// A draft write that did not land. See ``ThreadModel/draftNotice``.
    ///
    /// ⚠️ MUTED INK AND NO DISMISS, like ``channelNoteStrip``. Nothing the operator
    /// typed is lost, and the next write that lands takes the sentence back down.
    @ViewBuilder
    private var draftNoticeStrip: some View {
        if let notice = model.draftNotice {
            Text(notice)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ⚠️ ONE STRIP FOR SEND, ATTACH AND GENERATE. All three fail in the same place,
    /// and giving each its own slot would mean three dismiss controls in one spot.
    ///
    /// ⚠️ IT OFFERS DISMISS AND NEVER RETRY. The server's own refusals reach here
    /// verbatim (an unverified sender, an exhausted A2P registration, the workspace
    /// cap) and not one of them is fixed by pressing the same button again; a send in
    /// particular must never be re-sent by this client, because a timeout means it
    /// may well have landed.
    @ViewBuilder
    private var failureStrip: some View {
        if let failure = content.sendFailure {
            HStack(alignment: .top, spacing: DistrictSpacing.tight) {
                Text(failure.message)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(InboxCopy.dismiss) { model.dismissFailure() }
                    .buttonStyle(.districtGhost)
            }
        }
    }

    /// The images waiting to go out with the next send.
    ///
    /// ⚠️ ALREADY UPLOADED, so removing one costs nothing server-side and the send
    /// carries only URLs. Uploading at PICK time rather than at SEND time means an
    /// upload failure costs a retry of one image instead of failing a billable send
    /// that has already spent its rate-limit slot.
    @ViewBuilder
    private var attachmentStrip: some View {
        if !content.attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: DistrictSpacing.tight) {
                    ForEach(content.attachments, id: \.self) { url in
                        VStack(spacing: DistrictSpacing.hairline) {
                            ThreadMediaThumbnail(url: url)
                            Button(InboxCopy.remove) { model.removeAttachment(url) }
                                .buttonStyle(.districtGhost)
                                .accessibilityLabel(InboxCopy.removeAttachment)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// ⚠️ `axis: .vertical` SO THE BOX GROWS WITH THE REPLY, capped so it cannot eat
    /// the conversation it is a reply to.
    ///
    /// ⚠️ THE TITLE "Reply" IS THE PLACEHOLDER AND THE NAME VoiceOver READS, as in Mail and
    /// Messages. An eyebrow over the box said it a second time and cost a line (3.0.1).
    ///
    /// ⛔ NO `onSubmit`: with `axis: .vertical`, Return is a new line. See the ⛔ on the type.
    private var field: some View {
        TextField(InboxCopy.reply, text: text, axis: .vertical)
            .lineLimit(1 ... 5)
            .disabled(content.sending)
            .districtField()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⛔ ONE EXPLICIT TAP, BILLED, NEVER AUTOMATIC AND NEVER ON OPEN. Each press is one
    /// Vertex generation against the workspace's 20/min.
    private var draftControl: some View {
        let title = content.draftGenerating ? InboxCopy.drafting : InboxCopy.draftReply
        return Button {
            Task { await model.generateDraft() }
        } label: {
            ComposerIcon(title: title, systemImage: "sparkles")
        }
        .buttonStyle(.borderless)
        .help(title)
        .disabled(content.draftGenerating || content.sending)
    }

    /// ⚠️ HIDDEN, NOT DISABLED, WHEN THE CHANNEL CANNOT CARRY AN ATTACHMENT. A
    /// greyed-out button invites the operator to work out why; on an email thread the
    /// honest answer is that attachments are not a thing this channel does at all.
    ///
    /// ⛔ `preferredItemEncoding: .compatible` IS LOAD-BEARING, NOT A PREFERENCE. An
    /// iPhone photo is HEIC by default and `image/heic` is not on the route's
    /// allowlist, so without this the composer would refuse the ordinary case: the
    /// picker transcodes to a format the server accepts instead.
    @ViewBuilder
    private var attachControl: some View {
        if model.canAttach {
            // ⛔ THE LABEL IS READ OUT HERE, BEFORE THE CLOSURE, AND THE HOIST IS
            // LOAD-BEARING RATHER THAN STYLE. `PhotosPicker`'s label closure is
            // `@Sendable` and — unlike `.task`, which carries
            // `@_inheritActorContext` — it does NOT inherit this view's main-actor
            // isolation, so anything main-actor-isolated read inside it (`content`,
            // `colors`) is a Swift 6 concurrency diagnostic. `String` is `Sendable`, so
            // the captured value is fine. ⚠️ Do not inline it back into the closure.
            let label = content.attaching ? InboxCopy.attaching : InboxCopy.attachImage
            PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .compatible) {
                // ⚠️ THE SAME ICON VIEW AS THE OTHER TWO, so the row is one style; a
                // `PhotosPicker` is not documented to forward a button style to its label.
                ComposerIcon(title: label, systemImage: "photo")
            }
            .help(label)
            .disabled(content.attaching || content.sending)
            // ⚠️ AN IMAGE SAVED AS A FILE (Files, iCloud Drive, a USB drive on iPad) is not in
            // the photo library. Its bytes go through the same model call, so the type and
            // size rules are the same; unlike the picker it is not transcoded, so a HEIC file
            // is refused by the model with its own sentence rather than converted.
            let fileLabel = content.attaching ? InboxCopy.attaching : InboxCopy.attachFile
            Button {
                choosingFile = true
            } label: {
                ComposerIcon(title: fileLabel, systemImage: "paperclip")
            }
            .buttonStyle(.borderless)
            .help(fileLabel)
            .disabled(content.attaching || content.sending)
        }
    }

    /// ⛔ DISABLED WHILE A SEND IS IN FLIGHT, AND THAT GUARD IS ABOUT MONEY.
    ///
    /// ⛔ AND DISABLED ON BLANK TEXT EVEN WITH IMAGES ATTACHED. `messages/send` guards
    /// on `!body` BEFORE it looks at `mediaUrls`, so a picture with no caption is a
    /// 400 rather than a message: enabling the button would collect a send that could
    /// only fail.
    ///
    /// ⛔ AND ON AN EMAIL WITH NO SUBJECT, WHICH IS THE ONE THE SERVER WOULD ACCEPT.
    /// It substitutes "Message from District" and delivers, so nothing downstream can
    /// catch it; ``ThreadModel/canSendNow`` holds both rules so the button and the
    /// model can never disagree about them.
    private var sendControl: some View {
        Button(content.sending ? InboxCopy.sending : InboxCopy.send) {
            Task { await model.send() }
        }
        .buttonStyle(.districtPrimary)
        // ⛔ COMMAND-RETURN, NEVER RETURN. See the ⛔ on the type.
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(content.sending || !model.canSendNow)
        // ⛔ IT IS IN `UITestApp.forbiddenSurfaces`, AND THE REFUSAL IN
        // `UITestApp.tap(_:)` KEYS ON THIS IDENTIFIER. Without it that guard would
        // protect a string that appears nowhere in the app — a vacuous guard on the
        // one control that sends a real, billed message to a real customer from the
        // live workspace. Do not remove it: the `precondition` keys on the
        // identifier, so an unnamed control is an unprotected one.
        .accessibilityIdentifier(A11yID.Inbox.send)
    }

    // MARK: - Wiring

    private var text: Binding<String> {
        Binding(
            get: { model.composerText },
            set: { model.composerTextChanged($0) }
        )
    }

    /// ⚠️ THROUGH ``ThreadModel/subjectChanged(_:)`` FOR THE REASON ``text`` GOES
    /// THROUGH ``ThreadModel/composerTextChanged(_:)``: that method is the only one
    /// that arms an autosave, and there must be no second copy of this string.
    private var subject: Binding<String> {
        Binding(
            get: { model.composerSubject },
            set: { model.subjectChanged($0) }
        )
    }

    /// Which of the thread's channels the next send uses.
    ///
    /// ⛔ THROUGH ``ThreadModel/selectReplyTarget(_:)`` AND NOWHERE ELSE, for the same
    /// class of reason the two bindings above go through their own methods: that
    /// method is the only thing that drops staged images when the channel stops being
    /// able to carry them and writes the note saying so. A binding straight to the
    /// index would move the channel and leave the images attached to a send that
    /// silently ignores them.
    ///
    /// ⚠️ A CLOSURE LITERAL, NEVER A BARE METHOD REFERENCE. A bare
    /// MainActor-isolated method as a `Binding` setter aborts the compiler in IRGen
    /// under Swift 6 with no `error:` line; `.swiftlint.yml`'s one custom rule exists
    /// for exactly this.
    private var selectedChannel: Binding<Int> {
        Binding(
            get: { model.selectedReplyIndex },
            set: { model.selectReplyTarget($0) }
        )
    }

    /// Read the picked item's bytes and hand them to the model.
    ///
    /// ⛔ THE BYTES CROSS INTO THE MODEL THROUGH ONE `@MainActor` CALL and nothing
    /// else is carried across: `Data` is a value, the model owns every decision about
    /// it, and the type and size are refused there before a byte is uploaded.
    ///
    /// ⚠️ A NIL OR THROWING LOAD IS "COULD NOT BE READ", WHICH IS NOT THE SAME AS A
    /// REJECTED TYPE OR SIZE. Those three call for three different next actions from
    /// the operator, and collapsing them would leave them re-picking the same file.
    private func read(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.refuseAttachment(ThreadModel.unreadableAttachment)
            return
        }
        await model.attach(data, mimeType: item.preferredMIMEType(allowed: MediaUploadLimits.allowedMimeTypes))
    }

    /// Read a file chosen in the Files picker and hand it to the model, as ``read(_:)`` does.
    ///
    /// ⛔ THE SECURITY-SCOPED ACCESS IS OPENED AND CLOSED AROUND THE ONE READ. The picker
    /// grants this app the chosen file only, through the URL's scope; reading outside it fails
    /// as "could not be read".
    private func readFile(_ result: Result<URL, any Error>) async {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else {
            model.refuseAttachment(ThreadModel.unreadableAttachment)
            return
        }
        await model.attach(
            data,
            mimeType: AttachmentFile.mimeType(of: url, allowed: MediaUploadLimits.allowedMimeTypes)
        )
    }
}

/// One of the composer's icon controls: the symbol on screen, the title to VoiceOver.
///
/// ⚠️ 44 BY 44 POINTS, Apple's touch-target floor, whatever the symbol's own size.
private struct ComposerIcon: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}
