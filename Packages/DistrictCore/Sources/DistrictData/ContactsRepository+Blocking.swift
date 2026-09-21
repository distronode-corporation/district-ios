import DistrictModel
import DistrictNetwork
import Foundation

/// How a caller was named when a block was asked for.
///
/// ⛔ A CLOSED TWO-CASE VALUE RATHER THAN TWO OPTIONAL PARAMETERS, AND IT IS THE
/// REASON THE ROUTE CANNOT BE CALLED WRONG FROM THIS CLIENT. `POST
/// contacts/block` wants exactly ONE identity: both keys present is ambiguous and
/// neither is a 400, and a pair of `String?` parameters makes both of those
/// spellable at every call site. An enum makes them unspellable.
///
/// ⛔ THE ID IS PREFERRED WHEREVER ONE EXISTS AND THE NUMBER IS THE FALLBACK, not
/// the other way round. A contact id is exact and survives the number changing; a
/// number has to be re-normalised server-side and matches whatever row that
/// normalisation lands on. ⚠️ But the fallback is not optional: an inbox thread
/// whose counterpart never resolved to a `Contact` row has only an address, and
/// those are exactly the threads a reviewer is most likely to open.
public enum BlockSubject: Sendable, Equatable {
    /// The contact row's own id.
    case contact(String)

    /// A raw phone number. ⚠️ THE SERVER NORMALISES IT AND UPSERTS THE CONTACT, so
    /// the reply's `contactId` may name a row this caller had never seen.
    case phoneNumber(String)
}

extension BlockSubject {
    var contactId: String? {
        guard case let .contact(id) = self else { return nil }
        return id
    }

    var phone: String? {
        guard case let .phoneNumber(number) = self else { return nil }
        return number
    }
}

/// Blocking a caller, and reading back who is blocked.
///
/// ⛔ ON ``ContactsRepository`` RATHER THAN A `ModerationRepository`, BECAUSE THE
/// IDENTITY IS A CONTACT ROW. A block is a column on the same row `rename` and
/// `delete` write, reached through the same `workspaceId`, so a second repository
/// would be a second name for one surface — and `AppContainer`'s own ⚠️ says a
/// repository per feature is what makes two `ApiClient`s, and therefore two
/// `TokenRefreshCoordinator`s, easy to write by accident.
///
/// ⚠️ ITS OWN FILE because `ContactsRepository.swift` carries the five mutations
/// with their reasoning attached and is within sight of SwiftLint's 500-line
/// ceiling. Same split as `NumbersRepository+Provisioning.swift`.
public extension ContactsRepository {
    /// Block or unblock one caller, answering the state the server left them in.
    ///
    /// ⛔ THE ONE CONTACT MUTATION ON THIS CLIENT THAT MAY BE RETRIED. The body
    /// carries the desired STATE rather than an instruction to flip one, so a
    /// repeat after an ambiguous failure converges on the same row. Every other
    /// write on this surface is the opposite: `enrich` buys a crawl and an LLM run,
    /// `clear-intel` destroys data that costs money to rebuild, `update` replaces
    /// every column it knows about, and `create` mints a permanent row. ⚠️ That
    /// permission is a property of THIS route and does not generalise — do not
    /// wrap it in a loop either, because a caller holding the retry is what keeps
    /// it deliberate.
    ///
    /// ⛔ THE REPLY IS ADOPTED, NEVER INFERRED FROM THE REQUEST. A caller that
    /// blocked by number does not know the `contactId` until this body arrives, and
    /// a caller that assumed its own `blocked` flag would leave a badge and a row
    /// free to disagree. See the ⛔ on ``ContactBlockResponse``.
    ///
    /// ⚠️ A **404** IS NOT FOLDED INTO SUCCESS HERE, unlike
    /// ``ContactsRepository/delete(workspaceId:contactId:)``. There, "the row is
    /// already gone" is the outcome the caller asked for; here it means the contact
    /// could not be found at all, and reporting "blocked" for a row nobody wrote is
    /// a claim about moderation that did not happen — which is the one claim
    /// Guideline 1.2 is about.
    ///
    /// ⚠️ A **403** IS THE ROLE. Every contact mutation excludes `viewer`
    /// server-side, so gate the control on ``WorkspaceRole/allowsMutation(_:)``
    /// first; the gate is an affordance and the server stays the authority.
    func setBlocked(
        workspaceId: String,
        subject: BlockSubject,
        blocked: Bool
    ) async -> Result<ContactBlockResponse, ApiError> {
        let descriptor = DistrictEndpoints.setContactBlocked(
            workspaceId: workspaceId,
            contactId: subject.contactId,
            phoneNumber: subject.phone,
            blocked: blocked
        )
        let outcome = await client.send(descriptor, as: ContactBlockResponse.self)
        return outcome.flatMap { ResponseEnvelope.affirm("ContactBlockResponse", $0.success, $0) }
    }

    /// Everyone this workspace has blocked.
    ///
    /// ⛔ AN EMPTY ARRAY IS A REAL ANSWER AND IS THE COMMON ONE, so the envelope
    /// check is what keeps it apart from a failure. Reading a failed request as
    /// "nobody is blocked" would offer an Unblock control on somebody who is still
    /// blocked, and hide the badge that says they are — on the one surface whose
    /// whole purpose is telling an operator that a caller has been shut out.
    ///
    /// ⚠️ THE ROWS ARE RETURNED AS SENT, INCLUDING ANY WHOSE ``BlockedContact/blockedAt``
    /// IS NIL. Filtering here would make this method's answer disagree with the
    /// route's, and the route is the authority on which of its own rows count. A
    /// caller that wants only the live blocks filters on
    /// ``BlockedContact/isBlocked``.
    func blocked(workspaceId: String) async -> Result<[BlockedContact], ApiError> {
        let descriptor = DistrictEndpoints.blockedContacts(workspaceId: workspaceId)
        let outcome = await client.send(descriptor, as: BlockedContactsResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("BlockedContactsResponse", $0.success, $0) }
            .map(\.blocked)
    }
}
