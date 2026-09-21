import Foundation

/// Blocking a caller, and reading back who is blocked.
///
/// ⛔ THESE TWO EXIST FOR APP STORE REVIEW GUIDELINE 1.2, WHICH IS A SHIP GATE
/// RATHER THAN A FEATURE REQUEST. District AI carries user-generated content — a
/// caller writes the messages in an inbox thread and speaks the words in a
/// transcript — so the binary must offer a way to BLOCK the person producing it
/// and a way to REPORT what they produced. The report half rides the existing
/// support transport (`DistrictEndpoints+Support.swift`); this file is the block
/// half.
///
/// ⛔ THE CALLER IS THE "USER" AND THE CONTACT ROW IS THE IDENTITY. There is no
/// account to block: a caller is a phone number that the server upserts into a
/// `Contact` when it first rings. So a block is a column on that row, which is why
/// the write accepts a `contactId` OR a raw `phoneNumber` — a thread whose
/// counterpart never resolved to a contact has only the second, and refusing it
/// would leave exactly the threads a reviewer is most likely to try unblockable.
///
/// ⚠️ THE SERVER ALSO FILTERS. `conversations` stops returning threads for a
/// blocked contact, so the client's own removal is about IMMEDIACY (Apple asks
/// that blocking take the content out of view at once) and not about being the
/// only enforcement. ⛔ Nothing here may therefore treat a still-present thread
/// after a successful block as a failure: two reads can disagree for one refresh.
public extension DistrictEndpoints {
    /// Block or unblock one caller.
    ///
    /// ⛔ IDEMPOTENT, AND IT IS THE ONLY CONTACT MUTATION ON THIS CLIENT THAT IS.
    /// The body carries the desired STATE rather than an instruction to flip one,
    /// so a repeat after an ambiguous failure converges instead of undoing the
    /// first attempt. The five writes in `DistrictEndpoints+Contacts.swift` are all
    /// the other way round (`enrich` spends money, `clear-intel` destroys data,
    /// `update` replaces every column) and none of them may be retried.
    ///
    /// ⛔ EXACTLY ONE OF `contactId` AND `phoneNumber` SHOULD BE SENT, AND THIS
    /// FUNCTION DOES NOT ENFORCE IT — ``ContactsRepository`` does, before the
    /// request is built. The reason the enforcement is upstream rather than here is
    /// that a descriptor with no caller cannot report a refusal; it can only build
    /// a body the server will reject.
    ///
    /// ⚠️ NILS ARE DROPPED RATHER THAN SENT AS NULL (see the ⛔ on ``JSONValue``),
    /// which is what makes "block by id" and "block by number" two shapes of one
    /// body rather than two routes.
    ///
    /// - Parameter blocked: the state to leave the contact in. `false` unblocks.
    static func setContactBlocked(
        workspaceId: String,
        contactId: String?,
        phoneNumber: String?,
        blocked: Bool
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .setContactBlocked,
            .post,
            DistrictPaths.contactsBlock,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("contactId", .optional(contactId)),
                ("phoneNumber", .optional(phoneNumber)),
                ("blocked", .bool(blocked)),
            ]))
        )
    }

    /// Everyone this workspace has blocked.
    ///
    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND IS THE COMMON ONE. Most workspaces
    /// have never blocked anybody, so a caller that renders a failed read as "none
    /// blocked" would show an unblock control on somebody who is still blocked and
    /// hide the badge that says so. ``ContactsRepository/blocked(workspaceId:)``
    /// keeps the two apart through the envelope check.
    ///
    /// ⛔ THE SET IS NOT ON THE CONTACT ROW AND MUST NOT BE PUT THERE. Both contact
    /// reads return the raw Prisma row, and `district-contacts.json` /
    /// `district-contact.json` pin those bodies byte for byte through
    /// `StrictDecodeVerifier` — so a `blocked` field added to ``Contact`` would red
    /// the contract gate on a fixture this client may not regenerate (the corpus is
    /// owned by the Android side). A separate read is the only shape
    /// that does not make a UI badge into a two-repo change.
    ///
    /// ⚠️ NOT PAGED. The route answers the whole set; a workspace that has blocked
    /// hundreds of callers gets hundreds of rows. Acceptable because a block is a
    /// deliberate human act and the rows are four short fields, but do not assume a
    /// ceiling that the route does not state.
    static func blockedContacts(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .blockedContacts,
            .get,
            DistrictPaths.contactsBlocked,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }
}
