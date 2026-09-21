import Foundation

/// One blocked caller, as `GET /api/district/contacts/blocked` returns them.
///
/// ⛔ A SEPARATE TYPE FROM ``Contact`` RATHER THAN FOUR MORE FIELDS ON IT, AND THE
/// REASON IS THE CONTRACT GATE. Both contact reads answer the raw Prisma row and
/// `district-contacts.json` / `district-contact.json` pin those bodies byte for
/// byte through `StrictDecodeVerifier`, against fixtures the service generates and
/// this repository only copies. Adding a column to ``Contact`` would therefore red
/// the contract gate on a fixture this client cannot regenerate. The block state
/// arrives on its own route instead.
///
/// ⚠️ ``phoneNumber`` IS OPTIONAL BECAUSE CONTACTS ARE EMAIL-FIRST. A contact with
/// no number is legal and any number of them coexist in one workspace (see the ⚠️
/// on ``Contact/phoneNumber``), so a non-Optional here would fail to decode the row
/// for an email-only caller — which is a caller who can still be blocked. Optional
/// also absorbs both wire shapes: an explicit `null` and an omitted key.
///
/// ⚠️ ``blockedAt`` IS AN ISO-8601 STRING RATHER THAN AN INSTANT, like every other
/// timestamp in this module: one decoder strategy would have to be right for every
/// timestamp on the surface and they do not all agree.
public struct BlockedContact: Codable, Sendable, Equatable {
    public let contactId: String

    /// ⚠️ THE STORED NAME, WHICH MAY BE THE LITERAL "Unknown" OR THE NUMBER ITSELF.
    /// The voice agent writes "Unknown" for an unidentified caller and
    /// `ensureContactForPhone` creates with `name: phone`, so a screen must run it
    /// through the same fallback the contact list uses rather than printing it. See
    /// ``Contact/displayName``.
    public let name: String

    /// ⚠️ Nullable. See the type note on email-first contacts.
    public let phoneNumber: String?

    /// When the block was recorded, or nil for a row that is not blocked.
    ///
    /// ⛔ NIL IS NOT AN ERROR AND IS NOT IMPOSSIBLE ON THIS ROUTE EITHER. The write
    /// answers the same four fields with `blockedAt: null` after an UNBLOCK, so the
    /// nullability is load-bearing on ``ContactBlockResponse`` and is kept here so
    /// one shape serves both. ``isBlocked`` is the predicate; nothing may compare
    /// this to a literal.
    public let blockedAt: String?
}

public extension BlockedContact {
    /// Whether this row is blocked right now.
    ///
    /// ⛔ DERIVED FROM ``blockedAt`` RATHER THAN FROM A SEPARATE BOOLEAN, because
    /// the server sends one field and a second would be a value that could
    /// disagree with it. ⚠️ COMPUTED, so it is not encoded: synthesised `Codable`
    /// covers stored properties only, which keeps this from adding a key the
    /// server never sent.
    var isBlocked: Bool {
        blockedAt != nil
    }
}

/// `POST /api/district/contacts/block`.
///
/// ⛔ THE ANSWER IS THE RESULTING STATE, NOT AN ACKNOWLEDGEMENT, AND THAT IS WHY
/// THE CLIENT ADOPTS IT RATHER THAN THE VALUE IT SENT. A caller that blocked by
/// `phoneNumber` does not know the `contactId` until this body arrives — the server
/// upserts the contact — so the reply is the only place the identity of the row
/// that was just blocked exists. Assuming the request's own `blocked` flag would
/// also leave a UI badge and a database row free to disagree after a coerced write.
///
/// ⚠️ EVERY FIELD EXCEPT ``success`` MIRRORS ``BlockedContact``, deliberately, so a
/// screen can fold this straight into whatever it holds from the list read without
/// a second mapping. ⛔ It is NOT the same type: this one carries the envelope, and
/// a shared type would make `success` an Optional on the list rows.
public struct ContactBlockResponse: Codable, Sendable, Equatable {
    public let success: Bool
    public let contactId: String
    public let name: String
    /// ⚠️ Nullable. See ``BlockedContact/phoneNumber``.
    public let phoneNumber: String?
    /// ⚠️ NULL AFTER AN UNBLOCK, which is a success rather than a failure. See
    /// ``BlockedContact/blockedAt``.
    public let blockedAt: String?
}

public extension ContactBlockResponse {
    /// The state the contact is in now. See ``BlockedContact/isBlocked``.
    var isBlocked: Bool {
        blockedAt != nil
    }

    /// This reply as a list row, so a caller holds one shape.
    ///
    /// ⚠️ IT DROPS ``success`` ON PURPOSE. By the time anything calls this the
    /// envelope has been affirmed (see ``ResponseEnvelope``), so carrying the flag
    /// further would invite a second check that can only ever pass.
    var row: BlockedContact {
        BlockedContact(contactId: contactId, name: name, phoneNumber: phoneNumber, blockedAt: blockedAt)
    }
}

/// `GET /api/district/contacts/blocked?workspaceId=`.
///
/// ⛔ AN EMPTY ARRAY IS A LEGITIMATE ANSWER AND THE ENVELOPE CHECK IS WHAT KEEPS IT
/// DISTINGUISHABLE FROM A FAILURE. Most workspaces have blocked nobody, so "none"
/// is the ordinary reply — and a failed read rendered as "none" would show an
/// Unblock control to somebody who is still blocked and hide the badge that says
/// so. ``blocked`` is non-Optional because `findMany` always emits the array.
public struct BlockedContactsResponse: Codable, Sendable {
    public let success: Bool
    public let blocked: [BlockedContact]
}
