import DistrictModel
import DistrictNetwork
import Foundation

/// The CRM.
public struct ContactsRepository: Sendable {
    /// ⚠️ INTERNAL RATHER THAN `private`, FOR THE REASON ``NumbersRepository/client``
    /// GIVES. `private` is FILE scope in Swift, so the extension in
    /// `ContactsRepository+Blocking.swift` could not reach it — and the alternative
    /// was a second repository type over the same contact rows, which
    /// `AppContainer`'s own ⚠️ warns is how a second `ApiClient`, and therefore a
    /// second `TokenRefreshCoordinator`, gets written by accident. Still
    /// module-internal, so nothing outside `DistrictData` can borrow the client.
    let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// A pager over the contact list, newest first.
    ///
    /// ⚠️ UNLIKE THE CALL LOG, THIS ENDPOINT REPORTS A REAL `total`, so the end is
    /// KNOWN rather than inferred and the pager stops without a wasted request.
    /// That difference is exactly what ``OffsetPage/total`` carries.
    ///
    /// ⛔ DEDUPLICATION MATTERS MORE HERE THAN ANYWHERE ELSE. `bulk-create`
    /// inserts an entire import in one statement, so a window's worth of rows can
    /// shift between two page loads — and the ordering is `createdAt desc` with
    /// `id` as a tie-break precisely because hundreds of rows share one
    /// `createdAt`.
    ///
    /// ⚠️ THE SERVER ECHOES the limit and offset it actually applied (it clamps
    /// a limit above 100, and replaces a non-positive one with its default). They
    /// are not read here, because the pager advances by rows RECEIVED — which is
    /// the same number by construction and stays right if the clamp ever changes.
    public func pager(workspaceId: String) -> OffsetPager<Contact> {
        let client = client
        return OffsetPager(
            identify: { $0.id },
            fetch: { limit, offset in
                let descriptor = DistrictEndpoints.contacts(
                    workspaceId: workspaceId,
                    limit: limit,
                    offset: offset
                )
                return await client.send(descriptor, as: ContactListResponse.self)
                    .flatMap { ResponseEnvelope.affirm("ContactListResponse", $0.success, $0) }
                    .map { OffsetPage(items: $0.contacts, total: $0.total) }
            }
        )
    }

    /// One contact.
    ///
    /// ⚠️ THE ID IS A QUERY PARAMETER ON THIS ROUTE, not a path segment — see
    /// ``DistrictEndpoints/contact(workspaceId:contactId:)``.
    ///
    /// ⚠️ POLL THIS AFTER AN ENRICHMENT. `contacts/enrich` answers 200 with
    /// `status: "pending"` in under 100ms and the dossier arrives on the contact
    /// ROW, so ``Contact/dgiStatus`` here is the only thing that reports
    /// completion. ⛔ And null is not `pending`: `clear-intel` resets the column
    /// to NULL deliberately so nothing re-crawls, which means a poll loop waiting
    /// on a null waits forever.
    public func detail(workspaceId: String, contactId: String) async -> Result<Contact, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.contact(workspaceId: workspaceId, contactId: contactId),
            as: ContactDetailResponse.self
        )
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("ContactDetailResponse", response.success, response).flatMap { affirmed in
                // ⚠️ Malformed, not absent. A genuinely missing contact is a 404.
                guard let contact = affirmed.contact else {
                    return .failure(.decoding("ContactDetailResponse success response carried no contact"))
                }
                return .success(contact)
            }
        }
    }

    // MARK: - Writes

    // ⚠️ EVERY ONE OF THESE EXCLUDES `viewer` SERVER-SIDE. Gate the controls on
    // ``WorkspaceRole/allowsMutation(_:)`` so a viewer is never offered an action
    // that can only 403 — the gate is an affordance, and the server stays the
    // authority.

    /// Create a contact, answering its new id.
    ///
    /// ⚠️ A CONTACT NEEDS A PHONE **OR** AN EMAIL, not both: contacts are
    /// email-first and the database deliberately admits any number of phone-less
    /// rows per workspace. Both absent is a 400 with the route's own sentence.
    ///
    /// ⚠️ A BLANK STRING IS NORMALISED TO AN ABSENT KEY. The route reads
    /// `typeof phoneNumber === "string" && phoneNumber.trim()`, so `""` is
    /// already "no phone" to it — but `normalizeAddress("")` and a blank phone
    /// take different branches, and sending the empty strings a text field
    /// produces would make the client's own validation and the server's disagree
    /// about what was asked for. Normalising once, here, keeps them the same
    /// question.
    ///
    /// ⚠️ A **409** IS A DUPLICATE, NOT A SERVER FAULT — one contact per phone
    /// and per lowercased email per workspace. Surface the route's sentence.
    public func create(
        workspaceId: String,
        name: String,
        phoneNumber: String?,
        email: String?
    ) async -> Result<String, ApiError> {
        let descriptor = DistrictEndpoints.createContact(
            workspaceId: workspaceId,
            name: name,
            phoneNumber: Self.present(phoneNumber),
            email: Self.present(email)
        )
        let outcome = await client.send(descriptor, as: ContactCreateResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("ContactCreateResponse", $0.success, $0) }
            .map(\.id)
    }

    /// Rename a contact, re-sending every other column it already has.
    ///
    /// ⛔ IT TAKES THE WHOLE LOADED CONTACT BECAUSE `contacts/update` IS A
    /// WHOLESALE REWRITE, NOT A PATCH. The server's update handler writes one
    /// unconditional `data` block, so every field this request
    /// omits is REPLACED, not preserved: `phoneNumber` and `email` are rebuilt
    /// from the body, `socialHandles` becomes `{linkedin: linkedin || ""}`,
    /// `latestContextSummary` becomes `contextSummary || "Manual edit update."`,
    /// and `budget`, `timeline` and `website` each become `|| ""`.
    ///
    /// 🔑 The server's own tests pin the address half ("returns 400 only when an
    /// edit would leave neither phone nor email", and "clears the phone when an
    /// edit supplies only an email"). A name-only rename cannot succeed at all:
    /// both addresses end up null and the route answers **400** before touching
    /// a row.
    ///
    /// ⛔ A SIGNATURE TAKING ONLY name, phone AND EMAIL would silently clear
    /// Budget, Timeline, Website and the LinkedIn handle on every rename and
    /// stamp "Manual edit update." over the latest-context summary. The fix is
    /// the argument: pass the contact that is on screen and the columns it
    /// carries go back unchanged.
    ///
    /// ⚠️ WHAT IT STILL CANNOT DO IS RESTORE A NULL. A column the contact holds
    /// as NULL comes back as `""` (or as "Manual edit update.") because the
    /// handler's `||` defaults absorb an absent key and an empty string alike.
    /// Sending `nil` rather than `""` is what keeps the stored value identical
    /// to what it would be anyway, and there is no body that does better.
    ///
    /// ⚠️ AND `socialHandles` KEEPS ONLY LinkedIn, server-side. The handler
    /// writes a fresh one-key object, so a handle on any other platform is lost
    /// on every update whatever this client sends.
    ///
    /// - Parameter contact: the contact AS LOADED, not a locally edited copy.
    ///   The only field this changes is the name, and it takes that separately.
    public func rename(
        workspaceId: String,
        contact: Contact,
        name: String
    ) async -> Result<Void, ApiError> {
        let descriptor = DistrictEndpoints.updateContact(
            workspaceId: workspaceId,
            contactId: contact.id,
            fields: ContactUpdateFields(
                name: name,
                phoneNumber: Self.present(contact.phoneNumber),
                email: Self.present(contact.email),
                linkedin: Self.present(Self.linkedin(in: contact.socialHandles)),
                contextSummary: Self.present(contact.latestContextSummary),
                budget: Self.present(contact.budget),
                timeline: Self.present(contact.timeline),
                website: Self.present(contact.website)
            )
        )
        let outcome = await client.send(descriptor, as: SuccessResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("ContactUpdateResponse", $0.success, $0) }
            .map { _ in }
    }

    /// Delete a contact.
    ///
    /// ⛔ A **404 IS A SUCCESS HERE**, and it is the one place on this surface
    /// where a failure status is folded into the happy path. The route answers
    /// 404 when its `deleteMany` matched no row, which for a delete means the
    /// contact is already gone — the outcome the caller asked for. Reporting it
    /// as a failure shows the operator an error they cannot act on beside a row
    /// that has, in fact, disappeared.
    ///
    /// ⚠️ DELIBERATELY NOT ENVELOPE-CHECKED ON THAT BRANCH. A 404 body is
    /// `{success:false, error}`, so running it through ``ResponseEnvelope`` would
    /// turn the "already gone" case straight back into a failure.
    ///
    /// ⚠️ `Call.contactId` IS A LOOSE REFERENCE WITH NO FOREIGN KEY, so deleting
    /// a contact orphans that reference rather than cascading. Nothing on this
    /// client has to clean up after it.
    public func delete(workspaceId: String, contactId: String) async -> Result<Void, ApiError> {
        let descriptor = DistrictEndpoints.deleteContact(workspaceId: workspaceId, contactId: contactId)
        switch await client.send(descriptor, as: SuccessResponse.self) {
        case let .success(response):
            return ResponseEnvelope.affirm("ContactDeleteResponse", response.success, response).map { _ in }
        case let .failure(error):
            guard error.httpStatus == 404 else { return .failure(error) }
            return .success(())
        }
    }

    /// Queue a District Global Intelligence dossier for one contact.
    ///
    /// ⛔ NOT IDEMPOTENT AND IT SPENDS MONEY. One call buys one external crawl
    /// and one LLM synthesis. Nothing above this layer may retry it, loop it or
    /// fire it automatically: an enrichment that timed out may well have been
    /// queued, and re-sending spends a second model run on the same contact. The
    /// server's own rate limit is Redis-backed and FAIL-OPEN, so it is not a
    /// backstop for any of that.
    ///
    /// ⛔ A **403 IS USUALLY THE WORKSPACE OPT-IN, NOT THE CALLER'S ROLE**, and
    /// the body of that 403 is the product rather than boilerplate: it names the
    /// settings page that turns the feature on. This method passes the error
    /// through UNTOUCHED so that sentence survives to the screen — replacing it
    /// with "you do not have permission" sends the operator hunting through their
    /// own account for a switch that lives on the workspace.
    ///
    /// ⚠️ SUCCESS MEANS SCHEDULED, NOT DONE. The 200 carries `status: "pending"`
    /// in under 100ms and the dossier lands on the CONTACT row later; poll
    /// ``detail(workspaceId:contactId:)`` and read ``Contact/dgiStatus``.
    public func enrich(workspaceId: String, contactId: String) async -> Result<EnrichResponse, ApiError> {
        let descriptor = DistrictEndpoints.enrichContact(workspaceId: workspaceId, contactId: contactId)
        let outcome = await client.send(descriptor, as: EnrichResponse.self)
        return outcome.flatMap { ResponseEnvelope.affirm("EnrichResponse", $0.success, $0) }
    }

    /// Clear a contact's dossier, keeping the contact.
    ///
    /// ⛔ THIS DESTROYS DATA AND IS NOT RECOVERABLE: getting the dossier back
    /// means paying for another crawl and another model run. Confirm it before
    /// calling.
    ///
    /// ⛔ AFTERWARDS `dgiStatus` IS **NULL** AND NOTHING IS QUEUED. Re-read the
    /// contact rather than optimistically stamping "pending" locally — that
    /// pending would never resolve, because there is no job.
    ///
    /// ⚠️ UNLIKE ``delete(workspaceId:contactId:)``, A 404 IS NOT FOLDED INTO
    /// SUCCESS. There the row being gone is what the caller wanted; here it means
    /// the contact could not be found at all, and reporting "cleared" for a
    /// contact nobody touched is a claim about data that was never read.
    public func clearIntel(workspaceId: String, contactId: String) async -> Result<Void, ApiError> {
        let descriptor = DistrictEndpoints.clearContactIntel(workspaceId: workspaceId, contactId: contactId)
        let outcome = await client.send(descriptor, as: SuccessResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("ClearIntelResponse", $0.success, $0) }
            .map { _ in }
    }

    /// A trimmed value, or nil when there is nothing left of it.
    ///
    /// ⚠️ NIL RATHER THAN `""`, because ``JSONValue/object(_:)`` drops a nil pair
    /// and keeps an empty string — and on `contacts/create` an empty phone takes
    /// a different branch from an absent one.
    private static func present(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The LinkedIn handle out of ``Contact/socialHandles``, or nil.
    ///
    /// ⛔ IT READS ONE KEY DEFENSIVELY AND NEVER ASSUMES A SHAPE. The column is
    /// `Json?` with nothing server-side enforcing it (the lib casts it to
    /// `Record<string, unknown>`), so the blob may be an array, a scalar, or an
    /// object whose `linkedin` is a number. ``WireJSON``'s subscript answers nil
    /// for a non-object and ``WireJSON/stringValue`` answers nil for a non-string,
    /// so every one of those becomes "no handle" rather than a crash or a junk
    /// value forwarded to a column under no validation.
    private static func linkedin(in handles: WireJSON?) -> String? {
        guard let handles else { return nil }
        return handles["linkedin"]?.stringValue
    }
}
