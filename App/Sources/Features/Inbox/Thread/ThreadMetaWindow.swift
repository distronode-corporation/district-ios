import DistrictData
import DistrictModel
import Foundation

/// What the composer knows about a Messenger or Instagram reply: Meta's reply window
/// (DistrictCore 8.3.0), read the way the website's composer reads it.
///
/// ⛔ THE WINDOW IS READ, NEVER COMPUTED, like WhatsApp's (``WhatsAppComposer``): only the
/// server holds the customer's last message and whether the page has Meta's human agent tag
/// turned on. ⚠️ NO COUNTDOWN: the website shows none for Meta, so `until` is not drawn.
struct MetaWindowComposer {
    enum Window: Equatable {
        /// Not read, not a Messenger or Instagram reply, the read failed, or a state this
        /// build does not know. ⛔ BLOCKS NOTHING: the send is the gate.
        case unknown
        case open(to: String)
        /// Meta's 7-day human agent window: the reply goes tagged as a person's, so the
        /// composer says so and does not offer the AI draft.
        case humanAgent(to: String)
        /// No reply goes until the customer writes again: the warning, and Send disabled.
        case closed(to: String)
    }

    var window: Window = .unknown

    /// ⛔ WHICH WINDOW READ MAY APPLY ITS ANSWER: only the latest begun, as the WhatsApp
    /// window's (max review, #99 and #95).
    var reads = LatestRead()
}

extension ThreadModel {
    /// True when the selected reply is Messenger or Instagram and its window is closed: the
    /// warning shows and Send is disabled.
    var metaWindowClosed: Bool {
        guard let recipient = selectedMetaReply, case let .closed(to) = meta.window else { return false }
        return to == recipient.to
    }

    /// True when the selected reply is in Meta's human agent window: the badge shows and the
    /// AI draft is not offered.
    var metaHumanAgent: Bool {
        guard let recipient = selectedMetaReply, case let .humanAgent(to) = meta.window else { return false }
        return to == recipient.to
    }

    /// Read the window for the selected reply, or forget it when that is not Messenger or
    /// Instagram.
    ///
    /// ⚠️ CALLED WHEREVER THE WHATSAPP WINDOW IS: the composer's `.task(id:)` on the selected
    /// channel (a switch, and the composer coming back after a reload), and after a send.
    /// ⛔ AN OLDER READ'S ANSWER, A CANCELLED ONE'S, AND ONE FOR AN ADDRESS NO LONGER SELECTED
    /// ARE DROPPED, the same three guards as ``refreshWhatsAppWindow()``.
    /// ⛔ AND A CANCELLED CALLER BEGINS NO READ AT ALL (Seer, #105): the composer's task awaits
    /// the WhatsApp read first, and a task cancelled by a channel switch that went on to begin
    /// here would make the newer task's read stale, leaving the window unknown.
    func refreshMetaWindow() async {
        guard !Task.isCancelled else { return }
        let read = meta.reads.begin()
        guard let recipient = selectedMetaReply else {
            meta.window = .unknown
            return
        }
        let outcome = await inbox.metaWindow(
            workspaceId: target.workspaceId,
            channel: recipient.channel,
            to: recipient.to
        )
        guard meta.reads.isLatest(read), !Task.isCancelled, target.replyTarget == recipient else { return }
        switch outcome {
        case let .success(window):
            meta.window = Self.composerWindow(window.state, to: recipient.to)
        case .failure:
            meta.window = .unknown
        }
    }

    /// A sent Messenger or Instagram reply reads the window again, as the website does after
    /// a Meta send. Any other channel's leaves it alone.
    func noteMetaSend(to recipient: ReplyTarget) async {
        guard Self.isMetaChannel(recipient.channel) else { return }
        await refreshMetaWindow()
    }

    /// A send refused for a closed window closes it.
    ///
    /// ⛔ 409 `messenger_window_closed` IS THE SERVER SAYING THE WINDOW SHUT (Instagram answers
    /// the same code): the composer shows it closed at once, as the website's `markClosed`
    /// does, and a read still in flight can no longer reopen it. Any other refusal, or another
    /// channel's, leaves the window alone.
    func noteMetaWindowRefusal(_ error: ApiError, for recipient: ReplyTarget) {
        guard Self.isMetaChannel(recipient.channel), error.code == ApiErrorCode.messengerWindowClosed else {
            return
        }
        _ = meta.reads.begin()
        guard target.replyTarget == recipient else { return }
        meta.window = .closed(to: recipient.to)
    }

    /// The window the composer draws for the server's state.
    static func composerWindow(_ state: MetaWindowState, to: String) -> MetaWindowComposer.Window {
        switch state {
        case .open: .open(to: to)
        case .humanAgent: .humanAgent(to: to)
        case .closed: .closed(to: to)
        case .unknown: .unknown
        }
    }

    static func isMetaChannel(_ channel: String) -> Bool {
        channel == MessageChannel.messenger || channel == MessageChannel.instagram
    }

    /// The selected reply when it is Messenger or Instagram and this role may reply.
    private var selectedMetaReply: ReplyTarget? {
        guard canMutate, let recipient = target.replyTarget, Self.isMetaChannel(recipient.channel) else { return nil }
        return recipient
    }
}
