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
        case open(to: String, senderId: String)
        case closed(to: String, senderId: String)
    }

    enum Templates {
        case idle
        case loading
        /// ⛔ ONLY `isSendable` ONES: Meta refuses a template it has not approved.
        case ready([WhatsAppTemplate])
        case failed(FailureText)
    }

    var window: Window = .unknown
    var templates: Templates = .idle

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
    /// ⚠️ CALLED WHENEVER THE SELECTED CHANNEL CHANGES (the composer's `.task(id:)`), and
    /// after a send. ⛔ A RESULT FOR AN ADDRESS NO LONGER SELECTED IS DROPPED: the
    /// operator can switch channel while the read is in flight.
    func refreshWhatsAppWindow() async {
        guard canMutate, let recipient = target.replyTarget, recipient.channel == MessageChannel.whatsapp else {
            whatsApp.window = .unknown
            return
        }
        let outcome = await inbox.whatsAppWindow(workspaceId: target.workspaceId, to: recipient.to)
        guard target.replyTarget == recipient else { return }
        switch outcome {
        case let .success(response):
            whatsApp.window = response.window.open
                ? .open(to: recipient.to, senderId: response.senderId)
                : .closed(to: recipient.to, senderId: response.senderId)
        case .failure:
            whatsApp.window = .unknown
        }
    }

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
        guard recipient.channel == MessageChannel.whatsapp, case let .open(to, senderId) = whatsApp.window else {
            return nil
        }
        return to == recipient.to ? senderId : nil
    }

    /// Read the sender's approved templates, for the template sheet.
    func loadWhatsAppTemplates() async {
        guard case let .closed(_, senderId) = whatsApp.window else { return }
        whatsApp.templates = .loading
        switch await inbox.whatsAppTemplates(workspaceId: target.workspaceId, senderId: senderId) {
        case let .success(templates):
            whatsApp.templates = .ready(templates.filter(\.isSendable))
        case let .failure(error):
            whatsApp.templates = .failed(FailureText.from(error))
        }
    }

    /// Send one template with its variables. True when the server affirmed it.
    ///
    /// ⛔ REFUSED HERE WITH A VARIABLE MISSING OR BLANK: the route checks them against the
    /// template's placeholders and answers 400, and the sheet keeps Send disabled until
    /// every one is filled. The values go out trimmed, as the web's do.
    func sendWhatsAppTemplate(_ template: WhatsAppTemplate, variables: [String]) async -> Bool {
        guard canMutate, !whatsApp.sendingTemplate, template.isSendable else { return false }
        guard case let .closed(to, senderId) = whatsApp.window, target.replyTarget?.to == to else { return false }
        let count = Self.templateVariableCount(template)
        let values = variables.prefix(count).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Self.templateComplete(template, values) else { return false }

        whatsApp.sendingTemplate = true
        whatsApp.templateFailure = nil
        let outcome = await inbox.sendWhatsAppTemplate(
            workspaceId: target.workspaceId,
            to: to,
            senderId: senderId,
            template: template,
            variables: values
        )
        whatsApp.sendingTemplate = false
        switch outcome {
        case .success:
            await load()
            await refreshWhatsAppWindow()
            return true
        case let .failure(error):
            whatsApp.templateFailure = FailureText.from(error)
            return false
        }
    }

    /// How many variables a template takes: the server's count, else the highest
    /// `{{n}}` in its body.
    static func templateVariableCount(_ template: WhatsAppTemplate) -> Int {
        if let count = template.variableCount {
            return max(count, 0)
        }
        var highest = 0
        var rest = template.body[...]
        while let open = rest.range(of: "{{") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}}") else { break }
            if let number = Int(rest[..<close.lowerBound]) {
                highest = max(highest, number)
            }
            rest = rest[close.upperBound...]
        }
        return highest
    }

    /// True when every variable the template takes has a non-blank value.
    static func templateComplete(_ template: WhatsAppTemplate, _ values: [String]) -> Bool {
        let count = templateVariableCount(template)
        guard values.count >= count else { return false }
        return values.prefix(count).allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
