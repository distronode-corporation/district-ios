import DistrictModel
import DistrictNetwork
import Foundation

/// One message id, resolved into the thread it belongs to.
///
/// ⛔ A WRAPPER RATHER THAN THE RAW DTO, FOR THE REASON ``ConversationList`` IS ONE:
/// the answer has to be translated into the two vocabularies the rest of this
/// repository speaks — a ``ThreadSelector`` for the timeline and `mark-read`, and a
/// ``ReplyTarget`` for the send — and doing that ONCE here is what keeps a caller
/// from assembling either by hand. Both translations are one-line and both are the
/// kind of one-liner that gets written differently the second time.
///
/// ⛔ AND IT KEEPS THE WHOLE ``response`` rather than copying fields out, so a caller
/// that needs something not surfaced here reads it from the DTO instead of this type
/// growing a field per screen.
public struct ResolvedThread: Sendable, Equatable {
    public let response: MessageThreadResponse

    /// `contact:<id>` or `addr:<normalized>` — what `messages/drafts` accepts and
    /// what the Inbox threads on.
    public var threadKey: String {
        response.thread.threadKey
    }

    /// Which thread to READ or to mark read.
    ///
    /// ⛔ PREFERS THE CONTACT ID AND FALLS BACK TO THE COUNTERPART, NEVER TO
    /// ``threadKey``. `addr:<normalized>` sent whole as the address parameter
    /// matches nothing, so the write would succeed against zero rows and the badge
    /// would never clear. (The App's `ThreadTarget` reaches the same selector from a
    /// list or search row by stripping that prefix.)
    ///
    /// ⚠️ A PRESENT-BUT-BLANK `contactId` IS NOT A CONTACT ID. It would reach the
    /// route as `contactId=`, which is a different instruction from omitting it.
    public var selector: ThreadSelector {
        if let contactId = response.thread.contactId, !contactId.isEmpty {
            return .contact(contactId)
        }
        return .address(response.thread.counterpart)
    }

    /// Where a reply to this message goes, and on which channel.
    ///
    /// ⛔ NON-OPTIONAL, WHICH IS THE ROUTE'S GUARANTEE RATHER THAN AN ASSUMPTION
    /// HERE. A row whose counterpart does not normalise has no thread at all and is
    /// answered **409**, so a 200 always carries an addressable counterpart and a
    /// channel `messages/send` accepts. That is the opposite shape from
    /// ``ConversationSummary/replyTarget``, which is Optional because a thread can
    /// legitimately have nothing to reply on.
    ///
    /// ⛔ THE ADDRESS IS USED VERBATIM AND MUST NEVER BE RE-DERIVED. It is the
    /// UNWRAPPED form — the route ran `normalizeAddress` precisely so a
    /// display-name-wrapped `from` (`Paul <paul@example.com>`) cannot end up in `to`
    /// on a send. See the ⛔ on ``MessageThreadTarget/counterpart``.
    public var replyTarget: ReplyTarget {
        ReplyTarget(to: response.thread.counterpart, channel: response.thread.channel)
    }

    /// True when the workspace has already marked this message read.
    ///
    /// ⚠️ WHAT LETS A NOTIFICATION SHADE SKIP A "Mark read" THAT WOULD DO NOTHING.
    /// The inbox is workspace-level, so a colleague can have opened the thread
    /// between the push being sent and the notification being tapped. ⛔ It is not a
    /// guard: `mark-read` answers `{success, marked: 0}` for an already-read thread,
    /// which is a success, so acting on a stale value costs one harmless request.
    public var isRead: Bool {
        response.message.readAt != nil
    }
}

/// The two calls that arrived with the notification surface: resolving a pushed
/// message into a thread, and clearing the whole workspace's badge.
///
/// ⛔ A SIBLING FILE BECAUSE `InboxRepository.swift` IS WITHIN A DOZEN LINES OF THE
/// 500 `swiftlint --strict` ALLOWS (`file_length` warns at 500 and every warning is
/// an error in CI). The same ceiling already split `ThreadModel` three ways in the
/// App target and `EndpointTable` six ways in the tests; the alternative here was
/// the two methods with none of the reasoning below, which is the trade this repo
/// does not make. ⚠️ THE SPLIT COST EXACTLY ONE ACCESS WIDENING, stated so it cannot
/// quietly grow: ``InboxRepository``'s `client` lost its `private`, because `private`
/// is file-scoped in Swift and neither method below could otherwise reach the one
/// ``ApiClient``. `DistrictData` is one module and there is no second reader.
public extension InboxRepository {
    /// Exchange a message id for the thread it belongs to.
    ///
    /// ⛔ THE ONE CALL THAT MAKES A MESSAGE PUSH ACTIONABLE. The payload carries a
    /// `messageId` and every other endpoint on this surface is addressed by THREAD,
    /// so without this a notification can only ever land on the inbox LIST and can
    /// offer neither Reply nor Mark read. ⛔ Widening the payload instead is the bug
    /// the route exists to prevent: `threadKey` is `addr:<address>` whenever the
    /// thread has no `Contact` row, which puts a customer's phone number or email
    /// address on a lock screen and in front of any installed
    /// notification-listener app.
    ///
    /// ⛔ EVERY FAILURE HERE IS ALLOWED TO DEGRADE TO "the inbox list", AND THE
    /// CALLER MUST WRITE THAT FALLBACK DELIBERATELY. A 404 (not this workspace, or
    /// no such message — the route answers both identically on purpose), a 409 (a
    /// row with no addressable counterpart), an offline handset and a 403 for a
    /// viewer are four different reasons for the same outcome, and none of them is a
    /// retry. The list is already on screen by then, which is what makes a silent
    /// degrade honest rather than a swallowed error.
    ///
    /// ⚠️ THE WORKSPACE IS THE PUSH'S OWN, NEVER THE SELECTED ONE. The route falls
    /// back to the caller's active workspace when the parameter is absent, which on
    /// a multi-tenant account resolves a DIFFERENT tenant and then 404s for a
    /// message that exists.
    ///
    /// ⚠️ ROLES ARE `["agency","client"]` — the narrow side of a disagreement inside
    /// the Inbox, where `timeline` admits `viewer`. Gate the call on
    /// ``WorkspaceRole/allowsMutation(_:)`` like the writes it exists to enable,
    /// rather than treating the 403 as a fault.
    func messageThread(
        workspaceId: String,
        messageId: String
    ) async -> Result<ResolvedThread, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.messageThread(workspaceId: workspaceId, id: messageId),
            as: MessageThreadResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("MessageThreadResponse", $0.success, $0) }
            .map { ResolvedThread(response: $0) }
    }

    /// Mark every unread inbound message in the workspace read.
    ///
    /// ⛔ WORKSPACE-WIDE SHARED STATE, NOT A LOCAL BADGE RESET. `readAt` on a
    /// `Message` row means "someone on the team has seen this", so this clears every
    /// colleague's unread count as well as this operator's. It belongs behind a
    /// deliberate control and must never be reached from a refresh, an appearance or
    /// a retry helper.
    ///
    /// ⛔ A SEPARATE METHOD FROM ``InboxRepository/markRead(workspaceId:selector:)``
    /// RATHER THAN A FLAG ON IT, AND THE ROUTE'S OWN SOURCE IS THE ARGUMENT. Its
    /// comment records that a selector which resolved to nothing usable must mark
    /// ZERO rows because "falling through to an empty filter would mark the ENTIRE
    /// workspace read". One method with `all: Bool = false` beside two optional
    /// selectors would leave that fall-through one defaulted argument from every
    /// call site.
    ///
    /// ⚠️ IT DELETES NOTHING AND THE CUSTOMER SEES NOTHING. A repeat marks zero rows
    /// and still answers success, so it is safe to press twice — which is why the
    /// count is returned rather than a Void: zero is the honest answer to "there was
    /// nothing left to clear", and the caller redraws from the list either way.
    ///
    /// ⛔ EXCLUDES `viewer`, like every other write on this repository. Gate it
    /// before calling, or a read-only seat gets an error on a control it can see.
    func markAllRead(workspaceId: String) async -> Result<Int, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.markAllRead(workspaceId: workspaceId),
            as: MarkReadResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("MarkReadResponse", $0.success, $0) }
            .map(\.marked)
    }
}
