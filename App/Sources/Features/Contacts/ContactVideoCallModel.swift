import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// Starting a video room with one contact and telling them how to get in.
///
/// ⛔ THREE STEPS AND ONLY ONE OF THEM CAN BE TAKEN BACK. It mints a room name, asks for a
/// token (which is what produces the shareable guest invite), and SENDS that invite to the
/// contact — a metered, non-idempotent carrier segment or Postmark send, capped at 30/min
/// per workspace. The room and the token cost nothing; the message is money and cannot be
/// recalled. So: one deliberate tap is one attempt, and ⛔ NOTHING HERE RETRIES. A timeout
/// on the send means the message may well have gone out, and a second attempt is a second
/// charge and a duplicate to a customer.
///
/// ⛔ THE ROOM IS MINTED BY ``RoomName/init(workspaceId:suffix:)`` AND BY NOTHING ELSE, so
/// this cannot produce a `video_` name. That prefix is one character from `meet_` in the
/// same `startsWith` chain server-side and silently starts a BILLABLE Tavus avatar whose
/// default concurrency ceiling is 1 — the first accidental one is both a charge and an
/// outage of the avatar feature for every other room. There is no code path from here to
/// one, structurally, and there must not be.
///
/// ⛔ AND AN AI-AVATAR ROOM IS OUT OF SCOPE ON PURPOSE, not merely unimplemented: it is
/// unmintable here (above), billable, and concurrency-capped at one across the service.
/// ⛔ SCREEN SHARE IS ALSO OUT, and for a different reason: it needs a Broadcast Upload
/// Extension and an App Group, which is a target and an entitlement rather than a feature
/// flag. Neither belongs in a contact screen; each is a piece of work of its own.
///
/// ⚠️ TWO TOKEN CALLS HAPPEN FOR ONE TAP AND THAT IS UNDERSTOOD RATHER THAN ACCIDENTAL.
/// This one exists to obtain the guest invite; ``ActiveRoomModel`` mints its own when the
/// operator actually joins, because a join needs a fresh 30-minute LiveKit token. Both are
/// for the same room, and only ONE invite ever leaves the device. ``RoomsRepository``'s ⛔
/// forbids calling the route on a REDRAW, which this does not: it is reached from a button.
@MainActor
@Observable
final class ContactVideoCallModel {
    /// Where one attempt has got to.
    ///
    /// ⛔ `sent` CARRIES THE ROOM SO THE VIEW CAN NAVIGATE, and the navigation is
    /// deliberately the LAST step. Going to the room first and sending afterwards would put
    /// the metered send on a screen the operator has left, with nowhere to report that it
    /// did not go out.
    enum Phase {
        case idle
        case starting
        case sent(RoomName)
        case failed(FailureText)
    }

    private(set) var phase: Phase = .idle

    /// Whether to OFFER the action at all.
    ///
    /// ⛔ TWO ROUTES BEHIND IT AND BOTH EXCLUDE `viewer`: `messages/send` refuses one
    /// outright, and `calls/token` withholds `guestPath` from one — so a viewer would reach
    /// a room with no invitation to share even if the send had worked. Fails closed on an
    /// unparseable role, like every other gate here.
    let canStart: Bool

    private let rooms: RoomsRepository
    private let inbox: InboxRepository
    private let workspaceId: String
    private let webOrigin: URL

    /// - Parameter webOrigin: ⚠️ THE ORIGIN A `guestPath` IS JOINED ONTO AND NOTHING ELSE,
    ///   defaulted the same way ``ActiveRoomModel`` defaults its own. It is not a
    ///   credential and nothing authenticates against it.
    init(
        container: AppContainer,
        workspaceId: String,
        role: WorkspaceRole?,
        webOrigin: URL = ApiClient.productionBaseURL
    ) {
        rooms = container.rooms
        inbox = container.inbox
        self.workspaceId = workspaceId
        self.webOrigin = webOrigin
        canStart = WorkspaceRole.allowsMutation(role)
    }

    /// Whether this contact can be told about a room at all.
    ///
    /// ⛔ THE PAIR IS CHOSEN IN ONE PLACE, WHICH IS WHAT ``ReplyTarget``'S OWN ⛔ ASKS FOR.
    /// It is derived from WHICH TYPED COLUMN HOLDS A VALUE — `phoneNumber` means SMS,
    /// `email` means email — and never from the SHAPE of an address, which is the thing that
    /// rule forbids: an email address on the `sms` channel reaches the carrier branch, which
    /// does no address validation at all.
    ///
    /// ⚠️ SMS FIRST, BECAUSE A VIDEO INVITATION IS TIME-SENSITIVE. A conversation thread
    /// orders these by the traffic it has actually seen (``ConversationSummary/replyTargets``);
    /// a contact record carries no such evidence, so the choice is made on the medium rather
    /// than on history.
    static func target(for contact: Contact) -> ReplyTarget? {
        if let phone = nonEmpty(contact.phoneNumber) {
            return ReplyTarget(to: phone, channel: MessageChannel.sms)
        }
        if let mailbox = Self.nonEmpty(contact.email) {
            return ReplyTarget(to: mailbox, channel: MessageChannel.email)
        }
        return nil
    }

    /// Mint a room, send its guest link to the contact, and hand the room back.
    ///
    /// ⛔ IT WILL NOT START A SECOND ATTEMPT WHILE ONE IS IN FLIGHT. The send is metered and
    /// unrecallable; a double tap must not be two messages.
    func start(with contact: Contact) async {
        guard canStart, case .idle = phase else { return }
        guard let target = Self.target(for: contact) else {
            phase = .failed(FailureText(message: ContactVideoCopy.noAddress, action: .none))
            return
        }
        guard let room = RoomName(workspaceId: workspaceId, suffix: Self.suffix()) else {
            // Unreachable with a non-blank workspace id and this suffix; refused rather than
            // force-unwrapped, because the alternative is a crash on a contact screen.
            phase = .failed(FailureText(message: ContactVideoCopy.couldNotStart, action: .none))
            return
        }
        phase = .starting
        switch await rooms.token(roomName: room) {
        case let .success(credential):
            await invite(contact: contact, target: target, room: room, credential: credential)
        case let .failure(error):
            // ⚠️ NOTHING WAS SENT AND NOTHING WAS SPENT. A room that was never joined leaves
            // no trace, so this is the one failure here that is honestly retryable.
            phase = .failed(FailureText.from(error))
        }
    }

    /// Clear a failure so the button comes back.
    func reset() {
        phase = .idle
    }

    // MARK: - Internals

    /// Send the invite, then report the room.
    ///
    /// ⛔ THE LINK IS THE SERVER'S `guestPath` JOINED ONTO THE ORIGIN, NEVER REBUILT. The
    /// signature is computed over that exact encoding, so a hand-assembled link is one
    /// `/api/meet/token` will refuse — and it would look, to the person who shared it,
    /// exactly like a working invitation until their guest could not join.
    ///
    /// ⛔ A MISSING `guestPath` IS A REFUSAL, NOT A SILENT PLAIN-ROOM INVITE. The route
    /// withholds it from a viewer by design; without it there is nothing an unauthenticated
    /// contact can join with, and sending them a bare room name would be an invitation that
    /// cannot be accepted.
    private func invite(
        contact: Contact,
        target: ReplyTarget,
        room: RoomName,
        credential: RoomTokenResponse
    ) async {
        guard let path = credential.guestPath,
              let link = URL(string: path, relativeTo: webOrigin)?.absoluteURL
        else {
            phase = .failed(FailureText(message: ContactVideoCopy.noInvite, action: .none))
            return
        }
        let outcome = await inbox.send(
            workspaceId: workspaceId,
            target: target,
            body: ContactVideoCopy.invitation(link: link.absoluteString),
            // ⚠️ ONLY THE EMAIL BRANCH NEEDS ONE, and the server substitutes a literal
            // ("Message from District") when a client sends nothing — which is how every
            // reply this app ever sent came to share one subject line in the customer's
            // inbox. See ``ReplySubject``.
            subject: target.channel == MessageChannel.email ? ContactVideoCopy.emailSubject : nil
        )
        switch outcome {
        case .success:
            phase = .sent(room)
        case let .failure(error):
            // ⛔ NOT RETRYABLE FROM HERE. The action is stripped rather than trusted to
            // ``FailureText``: a timeout means the message may already have reached the
            // customer, and the room still exists, so the operator can join it and share
            // the link another way. Offering "try again" would invite a second charge and a
            // duplicate message.
            phase = .failed(FailureText(message: error.message ?? ContactVideoCopy.sendFailed, action: .none))
        }
    }

    /// A room suffix nobody has to type.
    ///
    /// ⚠️ NOT DERIVED FROM THE CONTACT. A suffix built from a name or a number would put a
    /// customer's identity into a room name that is low-entropy, human-readable, and shared
    /// as a link — and room names are explicitly NOT secrets. A timestamp says nothing about
    /// anyone. ⛔ ``RoomName/normalizeSuffix(_:)`` runs over it inside the initialiser, so
    /// the value is `[a-z0-9-]` regardless of what this produces.
    private static func suffix() -> String {
        "call-" + String(Int(Date().timeIntervalSince1970))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Every sentence the video-call action says.
enum ContactVideoCopy {
    static let action = "Video call"

    static let starting = "Setting up…"

    /// ⛔ THE MESSAGE SAYS WHAT THE LINK IS AND THAT IT EXPIRES. A bare URL from an unknown
    /// number reads as spam, and the invite really is time-limited — twelve hours,
    /// server-minted — so a recipient who opens it tomorrow needs to know why it refused
    /// them rather than concluding the product is broken.
    static func invitation(link: String) -> String {
        "Join me on a video call: \(link) (the link works for the next 12 hours)"
    }

    /// ⚠️ A REAL SUBJECT, BECAUSE THE SERVER SUBSTITUTES "Message from District" WHEN A
    /// CLIENT SENDS NONE — and the customer's mail client threads on it, so every reply the
    /// workspace ever sent would collapse into one conversation. See ``ReplySubject``.
    static let emailSubject = "Video call invitation"

    /// ⛔ NOT A FAILURE OF ANYTHING. The contact has neither a phone number nor an email
    /// address, which is legal, so there is nowhere to send an invitation.
    static let noAddress = "This contact has no phone number or email address, so there is nowhere to "
        + "send a video call link."

    /// ⛔ THE ROOM EXISTS AND THE INVITATION DOES NOT. `calls/token` withholds the guest
    /// invite from a read-only seat, so this is what a viewer would see if the gate above
    /// were ever loosened.
    static let noInvite = "That room was created without a shareable link, so the contact cannot be "
        + "invited to it."

    static let couldNotStart = "Could not start a video call for this workspace."

    static let sendFailed = "The room is ready but the invitation could not be sent."
}
