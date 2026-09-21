import Foundation

/// The CRM and the two District Global Intelligence writes.
///
/// ⛔ THE THREE CONTACT MUTATIONS USE THREE DIFFERENT HTTP CONVENTIONS — POST +
/// body, PATCH + body, DELETE + query — and all three exclude `viewer`
/// server-side.
public extension DistrictEndpoints {
    /// One page of the CRM, newest first.
    ///
    /// ⚠️ UNLIKE THE CALLS FEED, THE RESPONSE CARRIES A REAL `total`, so
    /// end-of-list is KNOWN rather than inferred. The server clamps `limit` to
    /// 100 and echoes what it actually applied.
    ///
    /// ⚠️ Ordering is `createdAt desc` with `id` as a tie-break, which matters: a
    /// bulk import writes hundreds of rows sharing one createdAt, and without the
    /// second key offset paging would skip or repeat rows.
    static func contacts(workspaceId: String, limit: Int, offset: Int) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .contacts,
            .get,
            DistrictPaths.contacts,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("limit", String(limit)),
                ApiQueryItem("offset", String(offset)),
            ]
        )
    }

    /// One contact, in exactly the shape a list row has.
    ///
    /// ⚠️ THE ID IS A QUERY PARAMETER HERE, NOT A PATH SEGMENT — this route
    /// predates the `/calls/{id}` style and was not changed. `contacts/{id}` 404s.
    static func contact(workspaceId: String, contactId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .contact,
            .get,
            DistrictPaths.contacts + ["get"],
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("contactId", contactId),
            ]
        )
    }

    /// Create a contact.
    ///
    /// ⚠️ A CONTACT NEEDS A PHONE NUMBER **OR** AN EMAIL — contacts became
    /// email-first. (`bulk-create` disagrees and requires a phone per row,
    /// silently counting an email-only row as invalid; that inconsistency is
    /// server-side and is not smoothed over here. `bulk-create` is not ported at
    /// all: N permanent rows from one call, no row ceiling, and it queues
    /// enrichment for every row.)
    ///
    /// ⚠️ A DUPLICATE PHONE OR EMAIL ANSWERS **409**, not a validation error,
    /// because the database enforces one contact per phone and per lowercased
    /// email per workspace. Surface it as "this contact already exists", not as a
    /// server fault.
    static func createContact(
        workspaceId: String,
        name: String,
        phoneNumber: String?,
        email: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .createContact,
            .post,
            DistrictPaths.contacts + ["create"],
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("name", .string(name)),
                ("phoneNumber", .optional(phoneNumber)),
                ("email", .optional(email)),
            ]))
        )
    }

    /// Update a contact.
    ///
    /// ⛔ THE SERVER EXPECTS **PATCH**, AND THIS IS THE ONLY ROUTE IN THE ENTIRE
    /// API WHERE `workspaceId` IS MANDATORY — omitting it once made Prisma drop
    /// the tenant filter, so the route now validates it explicitly. This client
    /// therefore cannot apply one "the server can resolve the workspace" policy
    /// across the surface.
    ///
    /// ⛔ **PATCH IN NAME ONLY: THE HANDLER REPLACES EVERY COLUMN IT KNOWS ABOUT,
    /// SO AN ABSENT KEY CLEARS RATHER THAN PRESERVES.** The handler writes one
    /// literal `data` block on every call:
    /// `name || "Unknown"`, `phoneNumber`/`email` rebuilt from the body,
    /// `socialHandles: {linkedin: linkedin || ""}`,
    /// `latestContextSummary: contextSummary || "Manual edit update."`, and
    /// `budget`/`timeline`/`website` each `|| ""`. Nothing is conditional and
    /// nothing reads the stored row first.
    ///
    /// 🔑 So a caller must send the contact's CURRENT value for every field it
    /// does not mean to change. ``ContactUpdateFields`` names the whole set for
    /// exactly that reason; the web dashboard survives this route only because
    /// it posts its entire form.
    ///
    /// ⚠️ Nils are still DROPPED rather than sent as explicit nulls (see the ⛔
    /// on ``JSONValue``), which on this route is the same instruction: the
    /// handler's `|| ""` defaults absorb an absent key and an empty string
    /// identically. It matters on the other three routes that read a null as
    /// "clear this", so the rule stays uniform.
    static func updateContact(
        workspaceId: String,
        contactId: String,
        fields: ContactUpdateFields
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .updateContact,
            .patch,
            DistrictPaths.contacts + ["update"],
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("contactId", .string(contactId)),
                ("name", .optional(fields.name)),
                ("phoneNumber", .optional(fields.phoneNumber)),
                ("email", .optional(fields.email)),
                ("linkedin", .optional(fields.linkedin)),
                ("contextSummary", .optional(fields.contextSummary)),
                ("budget", .optional(fields.budget)),
                ("timeline", .optional(fields.timeline)),
                ("website", .optional(fields.website)),
            ]))
        )
    }

    /// Delete a contact.
    ///
    /// ⛔ **DELETE WITH QUERY PARAMETERS AND NO BODY** — a third convention within
    /// one section. Answers 404 when nothing matched, which for a delete means it
    /// was already gone.
    static func deleteContact(workspaceId: String, contactId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deleteContact,
            .delete,
            DistrictPaths.contacts + ["delete"],
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("contactId", contactId),
            ]
        )
    }

    /// Queue a DGI enrichment for one contact.
    ///
    /// ⛔ NOT IDEMPOTENT AND IT SPENDS MONEY. One request schedules one external
    /// crawl and one LLM synthesis. Nothing in this client may retry it — an
    /// enrichment that timed out may well have been queued, and re-sending spends
    /// a second model run on the same contact.
    ///
    /// ⛔ ANSWERS **403 WHEN THE WORKSPACE HAS NOT OPTED IN**, and the body of
    /// that 403 is the product rather than boilerplate: it names the exact
    /// settings page that turns the feature on. Show it VERBATIM.
    ///
    /// ⚠️ ANSWERS 200 WITH `status: "pending"` in under 100ms — it reports that
    /// work was SCHEDULED, never that a dossier exists. Poll ``contact(workspaceId:contactId:)``
    /// afterwards and read `dgiStatus`.
    static func enrichContact(workspaceId: String, contactId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .enrichContact,
            .post,
            DistrictPaths.contactsEnrich,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("contactId", .string(contactId)),
            ]))
        )
    }

    /// Clear a contact's dossier, keeping the contact.
    ///
    /// ⛔ A SEPARATE FUNCTION FROM ``enrichContact(workspaceId:contactId:)``
    /// DESPITE THE IDENTICAL BODY, for the reason the Kotlin client keeps two
    /// request types: one costs money and the other destroys data, and a single
    /// function taking a flag would make those one character apart.
    ///
    /// ⛔ THIS DELETES THE DOSSIER, NOT THE CONTACT, and it is not recoverable —
    /// the crawl has to be paid for again. ⛔ AND IT RESETS `dgiStatus` TO
    /// **NULL**, NOT "pending": nothing is re-queued, so a client that
    /// optimistically showed "pending" would spin forever against a job that does
    /// not exist.
    ///
    /// ⚠️ **POST, NOT DELETE**, even though this removes data — the route exports
    /// POST only. It is not deleting a RESOURCE; it is nulling four columns on
    /// one that stays.
    static func clearContactIntel(workspaceId: String, contactId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .clearContactIntel,
            .post,
            DistrictPaths.contactsClearIntel,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("contactId", .string(contactId)),
            ]))
        )
    }
}

/// Every column `contacts/update` rewrites, in one value.
///
/// ⛔ A STRUCT RATHER THAN EIGHT MORE PARAMETERS, AND THE SHAPE IS THE WARNING.
/// The route replaces all eight on every call (see
/// ``DistrictEndpoints/updateContact(workspaceId:contactId:fields:)``), so
/// naming them together is what stops a caller thinking of this as a patch and
/// sending three of them. SwiftLint's `function_parameter_count` caps a `func`
/// at five and does not count an initialiser's, so the flat version could not
/// have been written anyway, but the reason to prefer this one is the first
/// sentence, not the linter.
///
/// ⛔ NO DEFAULT VALUES, DELIBERATELY. A `= nil` on any of these would let a
/// caller omit a field at the call site and silently blank the column, which is
/// the precise defect this type exists to close: a rename path that sends only
/// name, phone and email wipes Budget, Timeline, Website and the LinkedIn handle
/// and overwrites the latest-context summary with "Manual edit update.". Spelling out `nil` is cheap; discovering
/// a cleared column on a customer record is not.
///
/// ⚠️ `nil` AND `""` REACH THE SAME STORED VALUE HERE and neither can write a
/// SQL NULL. The handler's `|| ""` (and `|| "Manual edit update."` for the
/// summary) turns both into the empty string, so a contact whose `budget` was
/// NULL comes back as `""` after any update. That is the route's behaviour and
/// no body this client can send avoids it; prefer `nil` so the request carries
/// only fields the contact actually has.
public struct ContactUpdateFields: Sendable {
    /// ⚠️ Blank or absent stores the literal "Unknown", the same string the
    /// voice agent writes for an unidentified caller.
    public let name: String?
    /// The contact's CURRENT number, not a new one, unless this is the edit.
    public let phoneNumber: String?
    /// Likewise the current address. ⛔ Both this and `phoneNumber` ending up
    /// empty is a **400** before any row is touched.
    public let email: String?
    /// Written into `socialHandles` as `{linkedin: value}`. ⚠️ The whole blob is
    /// replaced by that one-key object, so any other platform stored on the
    /// contact is lost on every update. Server-side, and not fixable from here.
    public let linkedin: String?
    public let contextSummary: String?
    public let budget: String?
    public let timeline: String?
    public let website: String?

    public init(
        name: String?,
        phoneNumber: String?,
        email: String?,
        linkedin: String?,
        contextSummary: String?,
        budget: String?,
        timeline: String?,
        website: String?
    ) {
        self.name = name
        self.phoneNumber = phoneNumber
        self.email = email
        self.linkedin = linkedin
        self.contextSummary = contextSummary
        self.budget = budget
        self.timeline = timeline
        self.website = website
    }
}
