import DistrictData
import DistrictModel
import Foundation

/// What the composer knows about a WhatsApp reply: the customer-service window, and
/// the approved templates a closed window allows (DistrictCore 8.2.0).
///
/// ⛔ THE WINDOW IS READ, NEVER COMPUTED. WhatsApp allows free text for 24 hours after
/// the customer's last message, and only the server holds that message's time on the
/// number they wrote to; `GET whatsapp/window` answers it and names that number
/// (`senderId`), which is the sender every reply and template here goes out on.
struct WhatsAppComposer {
    enum Window: Equatable {
        /// Not read, not a WhatsApp reply, or the read failed. Free text is offered,
        /// and the server's refusal is the answer if the window has closed.
        case unknown
        /// ⚠️ `expiresAt` IS THE SERVER'S ISO-8601 CLOSE, and the composer re-reads the window
        /// then (``ThreadModel/rereadWindowAtExpiry(now:)``).
        case open(to: String, senderId: String, expiresAt: String?)
        case closed(to: String, senderId: String)
    }

    enum Templates {
        case idle
        case loading
        /// ⛔ ONLY THE ONES THE SEND ROUTE ACCEPTS (``ThreadModel/offerable(_:senderId:)``).
        case ready([WhatsAppTemplate])
        case failed(FailureText)
    }

    var window: Window = .unknown
    var templates: Templates = .idle

    /// ⛔ WHICH WINDOW READ MAY APPLY ITS ANSWER: only the latest begun (max review, #99 and
    /// #95), as the Inbox list's reads (``LatestRead``).
    var windowReads = LatestRead()

    /// ⛔ THE TEMPLATE SEND'S SINGLE-FLIGHT GUARD. A template is billed by Meta per
    /// conversation, and two taps before a re-render must not send it twice.
    var sendingTemplate = false
    var templateFailure: FailureText?
}

extension ThreadModel {
    /// True when the selected reply is WhatsApp and its window is closed: the composer
    /// offers only a template.
    var whatsAppWindowClosed: Bool {
        guard canMutate, let recipient = target.replyTarget, recipient.channel == MessageChannel.whatsapp else {
            return false
        }
        guard case let .closed(to, _) = whatsApp.window else { return false }
        return to == recipient.to
    }

    /// Read the window for the selected reply, or forget it when that is not WhatsApp.
    ///
    /// ⚠️ CALLED WHENEVER THE SELECTED CHANNEL CHANGES (the composer's `.task(id:)`), after a
    /// template send, when an open window reaches its close, and when a send is refused for a
    /// closed one. ⛔ A RESULT FOR AN ADDRESS NO LONGER SELECTED IS DROPPED: the operator can
    /// switch channel while the read is in flight.
    ///
    /// ⛔ AND SO IS AN OLDER READ'S, OR A CANCELLED ONE'S (max review, #99 and #95). Two reads
    /// overlap (a switch away and back, a refused send beside the expiry re-read), and they
    /// answered in any order: an older "open" could put the box back over a newer "closed".
    func refreshWhatsAppWindow() async {
        let read = whatsApp.windowReads.begin()
        guard canMutate, let recipient = target.replyTarget, recipient.channel == MessageChannel.whatsapp else {
            whatsApp.window = .unknown
            return
        }
        let outcome = await inbox.whatsAppWindow(workspaceId: target.workspaceId, to: recipient.to)
        guard whatsApp.windowReads.isLatest(read), !Task.isCancelled, target.replyTarget == recipient else { return }
        switch outcome {
        case let .success(response):
            whatsApp.window = response.window.open
                ? .open(to: recipient.to, senderId: response.senderId, expiresAt: response.window.expiresAt)
                : .closed(to: recipient.to, senderId: response.senderId)
        case .failure:
            whatsApp.window = .unknown
        }
    }

    /// Re-read an open window when it closes.
    ///
    /// ⛔ THE WINDOW CLOSES WHILE THE THREAD IS OPEN (xhigh review, #99 and #95): read once, an
    /// open window stayed open on screen past its `expiresAt`, and the box offered free text
    /// the server refuses. The composer runs this in a `.task(id:)` on the window, so a new
    /// answer or a closed screen cancels the wait; the website re-reads its clock the same way.
    ///
    /// ⛔ IT RE-ARMS WHILE THE ANSWER IS STILL OPEN AND ALREADY PAST ITS CLOSE HERE (max review,
    /// #99 and #95): a device clock ahead of the server's. The same answer leaves the
    /// `.task(id:)` as it was, so the re-read fired once and never again; it now backs off from
    /// `backoff` to ``windowRereadCeiling`` until the window closes or the answer moves.
    func rereadWindowAtExpiry(now: () -> Date = { .now }, backoff: Duration = windowRereadBackoff) async {
        guard case let .open(_, _, expiresAt) = whatsApp.window,
              let delay = Self.untilWindowCloses(expiresAt, now: now()) else { return }
        try? await Task.sleep(for: delay)
        var wait = backoff
        while !Task.isCancelled {
            await refreshWhatsAppWindow()
            guard !Task.isCancelled, case let .open(_, _, again) = whatsApp.window,
                  Self.untilWindowCloses(again, now: now()) == .zero else { return }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, Self.windowRereadCeiling)
        }
    }

    /// The first wait before re-reading a window whose answer is already past its close.
    static let windowRereadBackoff: Duration = .seconds(5)

    /// The longest wait between those re-reads.
    static let windowRereadCeiling: Duration = .seconds(60)

    /// How long until `expiresAt`, zero once it has passed; nil when there is no instant to
    /// wait for (none sent, or one this client cannot read), which leaves the window as read.
    static func untilWindowCloses(_ expiresAt: String?, now: Date) -> Duration? {
        guard let expiresAt, let closes = WireInstant.parse(expiresAt) else { return nil }
        return .milliseconds(max(0, Int((closes.timeIntervalSince(now) * 1000).rounded(.up))))
    }

    /// A send refused for a closed window re-reads it.
    ///
    /// ⛔ 409 `whatsapp_window_closed` IS THE SERVER SAYING THE WINDOW SHUT (xhigh review): the
    /// re-read puts the template button where the box was, as the website's `markClosed` does.
    /// Any other refusal, or another channel's, leaves the window alone.
    func noteWindowRefusal(_ error: ApiError, for recipient: ReplyTarget) async {
        guard recipient.channel == MessageChannel.whatsapp, error.code == Self.windowClosedCode else { return }
        await refreshWhatsAppWindow()
    }

    /// The send route's code for free text refused by a closed window.
    static let windowClosedCode = "whatsapp_window_closed"

    /// Send the composer's text on the selected channel.
    ///
    /// ⚠️ A WHATSAPP REPLY NAMES ITS SENDER when the window read gave one: the number the
    /// customer wrote to, which the web's composer sends on too. Without one the plain
    /// send lets the server choose, as before 8.2.0.
    func sendReply(to recipient: ReplyTarget, body: String, media: [String]) async -> Result<SentMessage, ApiError> {
        if let senderId = openWindowSender(for: recipient) {
            let workspaceId = target.workspaceId
            return await inbox.sendWhatsApp(workspaceId: workspaceId, to: recipient.to, body: body, senderId: senderId)
        }
        return await inbox.send(
            workspaceId: target.workspaceId,
            target: recipient,
            body: body,
            subject: outgoingSubject,
            mediaUrls: media
        )
    }

    /// The open window's sender when `recipient` is the WhatsApp reply it was read for.
    private func openWindowSender(for recipient: ReplyTarget) -> String? {
        guard recipient.channel == MessageChannel.whatsapp, case let .open(to, senderId, _) = whatsApp.window else {
            return nil
        }
        return to == recipient.to ? senderId : nil
    }

    /// Read the sender's approved templates, for the template sheet.
    ///
    /// ⚠️ THE LAST SEND'S REFUSAL GOES WITH IT: the sheet opening is a new attempt, and a
    /// failure left on the model would sit on a form it was never about (Seer, #99).
    func loadWhatsAppTemplates() async {
        guard case let .closed(_, senderId) = whatsApp.window else { return }
        whatsApp.templateFailure = nil
        whatsApp.templates = .loading
        switch await inbox.whatsAppTemplates(workspaceId: target.workspaceId, senderId: senderId) {
        case let .success(templates):
            whatsApp.templates = .ready(templates.filter { Self.offerable($0, senderId: senderId) })
        case let .failure(error):
            whatsApp.templates = .failed(FailureText.from(error))
        }
    }

    /// A template was chosen: the refusal of a send on another one is not this form's.
    func clearTemplateFailure() {
        whatsApp.templateFailure = nil
    }

    /// Send one template with its variables. True when the server affirmed it.
    ///
    /// ⛔ REFUSED HERE WITH A VARIABLE MISSING OR BLANK: the route checks them against the
    /// template's placeholders and answers 400, and the sheet keeps Send disabled until
    /// every one is filled. The values go out trimmed, as the web's do.
    func sendWhatsAppTemplate(_ template: WhatsAppTemplate, variables: [String]) async -> Bool {
        guard canMutate, !whatsApp.sendingTemplate else { return false }
        guard case let .closed(to, senderId) = whatsApp.window, target.replyTarget?.to == to else { return false }
        guard Self.offerable(template, senderId: senderId) else { return false }
        let count = Self.templateVariableCount(template)
        let values = variables.prefix(count).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Self.templateComplete(template, values) else { return false }

        whatsApp.sendingTemplate = true
        // ⛔ HELD UNTIL THE WHOLE SEND IS DONE, THE RE-READ INCLUDED (Seer, #95): Send must not come
        // back while the thread is re-read, or a second tap sends a second billed template.
        defer { whatsApp.sendingTemplate = false }
        whatsApp.templateFailure = nil
        let outcome = await inbox.sendWhatsAppTemplate(
            workspaceId: target.workspaceId,
            to: to,
            senderId: senderId,
            template: template,
            variables: values
        )
        switch outcome {
        case .success:
            // ⛔ THE TEMPLATE DID NOT GO OUT THROUGH THE COMPOSER, SO THE COMPOSER'S IMAGES STAY
            // (Seer, #99 and #95): the re-read puts them back (``ThreadModel/composerMedia``),
            // and so does a later retry when this re-read fails.
            await load()
            await refreshWhatsAppWindow()
            return true
        case let .failure(error):
            whatsApp.templateFailure = FailureText.from(error)
            return false
        }
    }

    /// True when the send route would accept this template from `senderId`.
    ///
    /// ⛔ THE WEBSITE'S RULE (`sendableWhatsAppTemplates`), AND THE SERVER'S (xhigh review): approved,
    /// tied to no sender or to this one, a non-blank body, and numbered placeholders. A nil
    /// `variableCount` is a body the server cannot fill (named placeholders, or unreadable),
    /// and `loadWhatsAppTemplateRef` refuses every send of it, so it is never offered.
    static func offerable(_ template: WhatsAppTemplate, senderId: String) -> Bool {
        guard template.isSendable, let count = template.variableCount, count >= 0 else { return false }
        guard !isBlank(template.body) else { return false }
        return template.senderId == nil || template.senderId == senderId
    }

    /// How many variables a template takes: the server's count. ⚠️ Only an
    /// ``offerable(_:senderId:)`` template reaches the sheet, so the count is always set there.
    static func templateVariableCount(_ template: WhatsAppTemplate) -> Int {
        max(template.variableCount ?? 0, 0)
    }

    /// True when every variable the template takes has a non-blank value.
    static func templateComplete(_ template: WhatsAppTemplate, _ values: [String]) -> Bool {
        let count = templateVariableCount(template)
        guard values.count >= count else { return false }
        return values.prefix(count).allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
