import Foundation

/// One CRM contact, as both `GET /api/district/contacts` and
/// `GET /api/district/contacts/get?contactId=` return it.
///
/// ⛔ BOTH ROUTES RETURN THE RAW PRISMA ROW, WHICH IS WHY ONE DTO SERVES BOTH
/// AND WHY SO MANY FIELDS ARRIVE AS EXPLICIT NULLS. The list route was written
/// to match `contacts/get` deliberately; the obvious alternative — reusing the
/// server's `getPaginatedContacts` helper — returns a MAPPED shape that silently
/// drops ``dgiStatus``, ``dgiError`` and ``visualMemory`` and converts absent
/// values to `undefined` instead of `null`. The detail screen needs `dgiStatus`,
/// so the mapper would have forced two contact shapes with different
/// nullability onto this client. The contract suite asserts the two responses
/// are equal.
///
/// ⚠️ EMAIL-FIRST: ``phoneNumber`` IS NULLABLE; a contact need not have a phone.
/// The database enforces one contact per phone per workspace,
/// but Postgres treats NULLs as distinct in a btree unique, so any number of
/// phone-less contacts coexist — that is required, not tolerated. Never key a
/// list or a lookup on the number; use ``id``.
public struct Contact: Codable, Sendable {
    public let id: String
    public let workspaceId: String
    /// ⚠️ NON-NULL SERVER-SIDE BUT NOT NECESSARILY USEFUL. The mapped helper
    /// substitutes "Unknown"; the raw row does not, and the voice agent writes
    /// that literal for an unidentified caller. See ``displayName``.
    public let name: String
    /// ⚠️ Nullable. See the type note on email-first contacts.
    public let phoneNumber: String?
    public let email: String?
    /// Arbitrary platform → handle pairs.
    ///
    /// ⛔ OPAQUE BECAUSE THE COLUMN IS `Json?` WITH NO SERVER-SIDE SHAPE. The lib
    /// casts it to `Record<string, unknown>`, so an object is the intended form
    /// and nothing enforces it. Read known keys defensively; do not invent a
    /// struct for a column nothing validates. See ``WireJSON``.
    public let socialHandles: WireJSON?
    /// Firmographics. The server casts this to `{name?, domain?, industry?}`, so
    /// those are the documented keys — but nothing enforces them, which is why
    /// every field of ``ContactCompany`` is Optional.
    public let company: ContactCompany?
    /// The DGI enrichment dossier.
    ///
    /// ⛔ UNSTRUCTURED BY DESIGN AND IT MUST STAY OPAQUE. Its contents come from
    /// a model and change with the prompt, so a schema pinned here would break
    /// on every prompt revision — and a typed model would DROP the dossier's
    /// unmodelled keys, which are the entire payload of the feature.
    public let intelligence: WireJSON?
    /// ⚠️ OPAQUE EVEN THOUGH THE SCHEMA COMMENT SAYS "array of strings". The
    /// column is `Json?`, so nothing prevents a row holding an object or a
    /// scalar — and a wrong TYPE is not rescued by a lenient parser the way an
    /// unknown KEY is. Inspect it before trusting its shape.
    public let visualMemory: WireJSON?
    public let latestContextSummary: String?
    /// DGI dossier state.
    ///
    /// ⛔ NULL AND `pending` ARE DIFFERENT THINGS. The column defaults to
    /// `pending`, but `contacts/clear-intel` resets it to NULL deliberately so
    /// nothing re-crawls the contact — so null means "no dossier, and none
    /// queued". Render it as an offer to enrich, never as a spinner for a job
    /// that will never complete. The vocabulary is ``DgiStatus``; ⛔ there is no
    /// `processing`, which is the web console's optimistic local state and is
    /// what a poll loop waits forever for.
    public let dgiStatus: String?
    /// Why the last enrichment failed. ⚠️ Explicitly null on a contact that has
    /// not failed, which is every row in both fixtures — hence the
    /// `allowedExplicitNulls` entries.
    public let dgiError: String?
    public let budget: String?
    public let timeline: String?
    public let website: String?
    /// ISO-8601 instant, or nil if never enriched.
    public let lastUpdated: String?
    /// ISO-8601 instant.
    public let createdAt: String
}

public extension Contact {
    /// A label to show when the name is unhelpful.
    ///
    /// ⚠️ THE "Unknown" LITERAL IS THE POINT. The raw row's ``name`` is non-null
    /// but the voice agent writes that exact string for an unidentified caller,
    /// so a blank check alone leaves a contact list full of rows all called
    /// Unknown. nil here means "fall back to the number or the address".
    var displayName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == ContactNames.unknown ? nil : name
    }
}

/// Literals the server writes into a contact row.
public enum ContactNames {
    /// What the voice agent stores for a caller it could not identify.
    public static let unknown = "Unknown"
}

/// The `company` blob's documented keys.
///
/// ⚠️ Every field Optional, for the same reason ``CallAnalysis``'s are: the
/// column is `Json?` and nothing in the database enforces the shape, so a row
/// written by an earlier pipeline may carry fewer keys. Drift in the other
/// direction — a NEW key — is caught by the strict gate, while the shipped
/// parser stays lenient.
public struct ContactCompany: Codable, Sendable {
    public let name: String?
    public let domain: String?
    public let industry: String?
}

/// `GET /api/district/contacts?workspaceId=&limit=&offset=`
///
/// ⚠️ UNLIKE THE CALLS FEED, THIS ONE CARRIES A REAL ``total``. The calls
/// endpoint is a bare array with no total and no `hasMore`, so its pager infers
/// end-of-list from a short page; here the count is authoritative and paging can
/// know how far it goes.
public struct ContactListResponse: Codable, Sendable {
    public let success: Bool
    public let contacts: [Contact]
    /// Total contacts in the workspace, not just this page.
    public let total: Int
    /// ⚠️ THE LIMIT AND OFFSET THE SERVER ACTUALLY APPLIED. It clamps: a limit
    /// above 100, non-numeric or non-positive is replaced rather than honoured.
    /// Page arithmetic uses these, not the values that were requested.
    public let limit: Int
    public let offset: Int
}

/// `GET /api/district/contacts/get?workspaceId=&contactId=` — the same row,
/// singly.
///
/// ⚠️ THE ID IS A QUERY PARAMETER ON THIS ROUTE, not a path segment.
public struct ContactDetailResponse: Codable, Sendable {
    public let success: Bool
    /// nil only on a malformed response. A genuinely missing contact is a 404.
    public let contact: Contact?
    /// The contact's number, described. ⛔ A SIBLING OF ``contact``, NOT A
    /// FIELD OF IT: ``Contact`` is the raw row and must decode identically from
    /// the list and from this route. nil for a phone-less contact, a number
    /// that does not parse, or a server older than the field.
    public let phoneIntel: PhoneIntel?
}

/// `POST /api/district/contacts/create`.
///
/// ⛔ ITS OWN TYPE RATHER THAN THE KOTLIN CLIENT'S `ContactMutationResponse`,
/// WHICH IS THE UNION OF ALL THREE MUTATIONS AND THEREFORE MAKES ``id``
/// OPTIONAL. Only `create` carries an id; `update` and `delete` answer a bare
/// `{success}` and decode as ``SuccessResponse``. A shared union type would put
/// an Optional on the ONE field the create path exists to obtain, so the
/// "created but we cannot say what" case would have to be handled at every call
/// site instead of once here.
///
/// ⚠️ NO FIXTURE PINS THIS SHAPE. There is no `district-contact-create.json` in
/// the corpus, so it is modelled from the route's own 200 branch
/// (`NextResponse.json({ success: true, id: newContact.id })`, which writes both
/// keys as literals with no conditional spread) rather than from a committed
/// document. ⛔ Do not "fix" that by adding a fixture: the corpus is owned by
/// the Android side and a fixture added here would fail
/// ``ContractManifest/expectedFixtureCount`` on both clients.
///
/// ⚠️ A **409** MEANS THE CONTACT ALREADY EXISTS, not that the request was
/// malformed: the database enforces one contact per phone and per lowercased
/// email per workspace, and the route's own sentence names which of the two
/// collided. It never reaches this type — ``ApiClient/send(_:as:)`` maps a
/// non-2xx to ``ApiError`` — but the wording matters where it lands.
public struct ContactCreateResponse: Codable, Sendable {
    public let success: Bool
    /// The new contact's id.
    public let id: String
}
