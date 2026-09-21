import Foundation

// ⛔ NO PURCHASE DTO BELONGS IN THIS FILE OR ANY OTHER. `workspace/numbers/purchase`
// charges a setup fee AND opens a recurring monthly charge for a service consumed
// inside the app, which is App Store Review Guideline 3.1.1: an in-app purchase or
// nothing. There is no request type, no response type, no ``EndpointID`` case and no
// path constant, so the route is unconstructible from outside `DistrictNetwork`
// rather than merely unmodelled — `EndpointSurfaceTests` pins that.
// ⛔ 3.1.1 COVERS STEERING TOO, so nothing here carries a URL to the web marketplace.
// The next reader will want to finish the set in good faith; this is the reason not
// to.
//
// ⚠️ THE READ PAIR IS IN `NumberResponses.swift` and stays there: ``AvailableNumber``,
// ``NumberSearchResponse``, ``ListedNumber`` and ``OwnedNumbersResponse`` are pinned
// by three shared contract fixtures. Nothing here has a fixture — the shared corpus
// mirrors the Android client and that client has no provisioning surface — so
// ⛔ `ContractManifest.expectedFixtureCount` MUST NOT MOVE. What pins these shapes is
// the route source, quoted per type below, and `NumberProvisioningRepositoryTests`.
//
// ⚠️ EVERY TIMESTAMP IS AN ISO-8601 **STRING**, not an instant, matching every other
// DTO in this module: `DistrictModel` owns no date parsing, and a `Date` here would
// need a decoding strategy the shipped lenient parser deliberately does not carry.

// MARK: - Which carriers are connected

/// One carrier's account, as `workspace/provider/status` reports it.
///
/// ⛔ A MANAGED PROVIDER REPORTS **CONNECTIVITY ONLY**, AND THAT IS A PRIVACY
/// PROPERTY RATHER THAN A GAP. `getAccountInfo` and `listOwnedNumbers` describe the
/// AUTHENTICATING carrier account; for a managed provider that is the platform's own
/// shared account, so its name, prepaid balance and total number count are
/// Distronode's figures plus every other managed tenant's — never this caller's. The
/// route short-circuits managed providers to `{connected: true, managed: true}`
/// before asking the carrier anything. ⚠️ It did NOT always: this route had no managed
/// short-circuit at all, unlike `provider/numbers`, which is what made the platform's
/// balance readable by any member of any workspace that had flipped itself to
/// "managed". So an entry carrying ``managed`` true and a ``balance`` is drift, not a
/// bonus.
///
/// ⛔ `connected: false` WITH AN ``error`` IS A **200**, NOT AN HTTP FAILURE. A carrier
/// that refuses its credentials is per-carrier content here — the response's own
/// top-level `connected` can still be true because another carrier answered. A screen
/// must render this per row rather than as a page-level failure.
///
/// ⚠️ EVERY FIELD BUT ``connected`` IS ABSENT RATHER THAN NULL ON SOME BRANCH, because
/// the route builds a different object literal per case and `JSON.stringify` drops an
/// undefined value entirely. ⚠️ ``balance`` IS A **STRING** on the wire — Twilio's own
/// spelling — and must not be modelled as a number.
public struct ProviderStatusEntry: Codable, Sendable {
    /// ⚠️ The only field present on every branch.
    public let connected: Bool
    /// ⛔ True means the line is on DISTRONODE's account, so nothing else in this
    /// entry will be populated. See the type doc.
    public let managed: Bool?
    /// ⚠️ Absent on a managed entry and on a refused one.
    public let accountName: String?
    /// ⚠️ The carrier account's status, not the connection's.
    public let status: String?
    /// ⚠️ A STRING, not a number. Absent on Sinch, which publishes none.
    public let balance: String?
    public let currency: String?
    /// ⚠️ The count on the CARRIER ACCOUNT, which for a BYOK workspace is theirs and
    /// for a managed one would be everybody's — hence absent there.
    public let numberCount: Int?
    /// ⚠️ Present exactly when ``connected`` is false. The route sends the literal
    /// "Invalid credentials" rather than the carrier's own text.
    public let error: String?
}

/// `GET /api/district/workspace/provider/status`.
///
/// ⛔ **NO `success` FLAG AT ALL, AND TWO DIFFERENT KEY SETS ONE LETTER APART.** A
/// workspace whose credentials do not resolve answers `{connected: false, provider:
/// null}` — SINGULAR `provider`, always null. Everything else answers `{connected,
/// providers: {…}}` — PLURAL, a map keyed by carrier id. They are mutually exclusive
/// branches of one route, so a decoder that modelled only the plural would read a
/// perfectly ordinary disconnected workspace as contract drift, and one that modelled
/// only the singular would read a healthy workspace the same way.
///
/// ⛔ SO NOTHING MAY REACH FOR `ResponseEnvelope.affirm` ON THIS ROUTE. There is no
/// flag to affirm; the same trap the scheduling pair, `stripeBilling` and `meetings`
/// carry, arriving a fourth time. The required non-optional ``connected`` is what
/// rejects a `{}` body.
///
/// ⚠️ ``connected`` IS AN OR ACROSS THE MAP, not a claim about any one carrier: it is
/// true when ANY entry is connected, so a workspace with a working Twilio and a
/// refused Telnyx reports `connected: true` with an error inside. Read
/// ``connectedProviders`` rather than the flag alone when the question is "which
/// carrier can I use".
public struct ProviderStatusResponse: Codable, Sendable {
    /// ⚠️ True when ANY carrier answered. See the type doc.
    public let connected: Bool
    /// ⛔ ABSENT on the no-credentials branch, which is the branch most likely to be
    /// under test on a fresh workspace.
    public let providers: [String: ProviderStatusEntry]?
    /// ⛔ THE SINGULAR KEY, AND IT IS ALWAYS NULL WHEN PRESENT. It exists only on the
    /// no-credentials branch, where the route writes `{connected: false, provider:
    /// null}`. Modelled so the two branches are told apart in a capture; nothing
    /// should read it for a value.
    public let provider: String?

    /// The carrier ids that answered, sorted, or empty when none did.
    ///
    /// ⚠️ SORTED because a JSON object has no order and a screen drawing rows from it
    /// would otherwise reshuffle between reads. ⚠️ Computed, so it adds no key on
    /// re-encode.
    public var connectedProviders: [String] {
        (providers ?? [:]).filter(\.value.connected).keys.sorted()
    }

    /// The carrier ids that refused their credentials, sorted.
    ///
    /// ⛔ SEPARATE FROM ``connectedProviders`` RATHER THAN ITS COMPLEMENT, because a
    /// screen has two different things to say: "use this one" and "this one's keys
    /// stopped working". Collapsing them would turn a fixable configuration problem
    /// into an absence.
    public var refusedProviders: [String] {
        (providers ?? [:]).filter { !$0.value.connected }.keys.sorted()
    }
}

// MARK: - What a country's regulator asks for

/// One document that satisfies a requirement.
///
/// ⚠️ ANY **ONE** OF A REQUIREMENT'S ACCEPTED DOCUMENTS SATISFIES IT, not all of
/// them. A form that demanded every entry would ask a customer for four proofs of
/// the same fact.
public struct RegulatoryAcceptedDocument: Codable, Sendable {
    public let name: String
    /// ⚠️ The carrier's machine type, which is what
    /// ``RegulatoryRequirement/requirementName`` is matched against on upload.
    public let type: String
    /// Field names the document itself must carry.
    public let fields: [String]
}

/// One thing the regulator wants.
///
/// ⛔ ``kind`` DECIDES WHICH HALF OF THE FILING THIS BELONGS TO, and the two are
/// satisfied by entirely different actions. `end_user` requirements are FIELDS, sent
/// in the submit's `endUserAttributes`; `supporting_document` requirements are FILES,
/// uploaded one at a time against ``requirementName``. Treating one as the other
/// produces a bundle the carrier evaluates as noncompliant for a reason the customer
/// cannot see in their own form.
///
/// ⚠️ ``requirementName`` IS THE CARRIER'S MACHINE NAME
/// (`business_registration_number_info` and friends) and is the exact string the
/// upload has to send. Never a label we invented, and never the human ``name``.
public struct RegulatoryRequirement: Codable, Sendable {
    /// ⛔ `end_user` or `supporting_document`. See the type doc.
    public let kind: String
    /// The human label.
    public let name: String
    /// ⛔ The machine name the upload must carry.
    public let requirementName: String
    public let type: String
    /// ⚠️ For an `end_user` requirement these are the attribute keys the submit must
    /// supply; for a document they are the fields the document itself must show.
    public let fields: [String]
    /// ⚠️ Present for supporting documents only, and ANY ONE of them satisfies the
    /// requirement.
    public let acceptedDocuments: [RegulatoryAcceptedDocument]?
}

/// A country's published regulation for one number type and end-user type.
public struct CountryRequirements: Codable, Sendable {
    public let isoCountry: String
    /// ⚠️ Twilio's vocabulary, which spells the toll-free case with a SPACE
    /// (`toll free`) — a different vocabulary from the marketplace search's
    /// `tollFree`.
    public let numberType: String
    public let endUserType: String
    /// ⚠️ Carried through to the created draft so a submit files against the same
    /// regulation the form was drawn from.
    public let regulationSid: String
    public let friendlyName: String
    public let requirements: [RegulatoryRequirement]
}

/// `GET /api/district/workspace/numbers/requirements`.
///
/// ⛔ ``purchasable`` AND ``requirements`` ANSWER DIFFERENT QUESTIONS AND NEITHER MAY
/// BE INFERRED FROM THE OTHER. The route's own header says so in terms: `purchasable`
/// is "can I buy one today", `requirements` is "what would it take". A country can
/// publish perfectly readable rules and still not be sellable here, because the
/// purchase path also has to attach the resulting bundle and the number has to be
/// routable to a bridge that serves it.
///
/// ⛔ A NULL ``requirements`` IS NOT A FAILED LOOKUP. It means the country publishes no
/// regulation for that number type, i.e. NO REGISTRATION IS REQUIRED — a real and
/// common answer. A failed lookup throws and arrives as a 500, so the two stay
/// distinguishable; collapsing them tells a customer to file paperwork that does not
/// exist, or that none is needed when we simply could not ask.
///
/// ⚠️ ``country`` AND ``numberType`` ARE ECHOED AS THE SERVER RESOLVED THEM — country
/// uppercased, number type defaulted to `local` — so a screen should label its answer
/// from these rather than from what it asked for.
public struct NumberRequirementsResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ Uppercased server-side.
    public let country: String
    /// ⚠️ Defaulted to `local` server-side.
    public let numberType: String
    /// ⛔ The honest answer to "can I buy one today", and NOT derivable from
    /// ``requirements``. See the type doc.
    public let purchasable: Bool
    /// ⛔ Null means no registration is required, NOT that the lookup failed.
    public let requirements: CountryRequirements?
}

// MARK: - The workspace's own filings

/// One document on a registration, as the list reports it.
///
/// ⛔ NO `storageKey` AND NO `documentSid`, DELIBERATELY. The key points at an
/// identity document and is only ever read through a server-minted presigned URL;
/// handing either to a client would make them look like addressable identifiers and
/// invite one. Presence is the question a screen actually has, so presence is what it
/// gets.
///
/// ⛔ THE TWO BOOLEANS ARE NOT THE SAME FACT AND A SCREEN NEEDS BOTH. ``stored`` means
/// we hold the bytes; ``submitted`` means the CARRIER holds a copy, which is only ever
/// true after a submit. A replacement upload clears the carrier's pointer, so a
/// document can be stored and unsubmitted again after being both.
///
/// ⛔ AND THIS IS **NOT** THE SHAPE THE UPLOAD ANSWERS. The POST answers
/// ``RegistrationDocumentResponse``'s narrower row — `createdAt` instead of
/// `updatedAt`, and neither boolean — so a list row cannot be built from an upload's
/// reply. Re-read the list.
public struct RegistrationDocument: Codable, Sendable {
    public let id: String
    /// ⛔ The carrier's machine name, which is what a re-upload must match to replace
    /// this row rather than add a second one.
    public let requirementName: String
    /// ⚠️ The SNIFFED type, not the declared one: the route decides it from the bytes.
    public let mimeType: String
    public let sizeBytes: Int
    /// ⛔ We hold the bytes. See the type doc.
    public let stored: Bool
    /// ⛔ The carrier holds a copy. See the type doc.
    public let submitted: Bool
    public let updatedAt: String
}

/// One regulatory filing.
///
/// ⛔ ``status`` IS THE GATE ON EVERYTHING ELSE, AND `draft` IS THE ONLY EDITABLE ONE.
/// Documents may be added or removed only while a filing is `draft`, and only a
/// `draft` may be submitted; every other value means it is already filed and the
/// route answers **409** rather than 403, because the request is well-formed and will
/// be valid again if the filing comes back rejected. The values seen are `draft`,
/// `pending-review`, `in-review`, `twilio-approved` and `twilio-rejected`. ⚠️ Typed as
/// a plain `String` rather than an enum: it is written from the carrier's own reply,
/// so an unrecognised value must degrade to "shown as-is" rather than failing the
/// decode of a whole list.
///
/// ⛔ ``rejectionReasons`` IS ALREADY HUMAN-READABLE AND IS THE ONLY PLACE A REFUSAL'S
/// DETAIL SURVIVES. The submit's 422 carries `failures` and `reasons` that
/// ``ApiError`` does not keep, and the route stores the carrier's structured failures
/// verbatim on the row — so re-reading the list after a refusal is how a screen shows
/// the customer what to fix. ⚠️ Empty unless the filing was actually refused.
///
/// ⚠️ A STATUS MAY BE STALE AND THE RESPONSE CANNOT SAY SO. The list refreshes
/// in-review bundles on read and DEGRADES rather than fails: missing carrier
/// credentials or a bad carrier minute return the STORED status, logged and
/// unmarked. Do not present one as live-as-of-now.
public struct NumberRegistration: Codable, Sendable {
    public let id: String
    public let isoCountry: String
    /// ⚠️ Twilio's vocabulary, `toll free` with a space.
    public let numberType: String
    /// `business` or `individual`.
    public let endUserType: String
    /// ⚠️ Ours to choose, and Twilio shows it in the CUSTOMER'S own console. Null when
    /// the operator left it blank.
    public let friendlyName: String?
    /// ⛔ The gate on everything else. See the type doc.
    public let status: String
    /// ⛔ Lines a person can read, and the only surviving detail of a refusal.
    public let rejectionReasons: [String]
    /// ⚠️ Null on a draft.
    public let submittedAt: String?
    /// ⚠️ Stamped only on a TERMINAL verdict. `pending-review` → `in-review` is the
    /// review STARTING and deliberately leaves it alone, so a non-null value here
    /// always means approved or rejected.
    public let reviewedAt: String?
    public let createdAt: String
    public let documents: [RegistrationDocument]
}

/// `GET /api/district/workspace/numbers/registrations`.
///
/// ⛔ THE TWO COUNTRY LISTS ARE NOT THE SAME THING AND A GATE NEEDS BOTH.
/// ``approvedCountries`` is where THIS workspace's own filings have been approved;
/// ``platformCountries`` is where a number can be bought against DISTRONODE's own
/// approved registration, with no filing by the tenant at all. A screen offering only
/// the first would hide every country the platform already covers; only the second
/// would offer a country the tenant has not been approved for.
///
/// ⛔ THEY LIVE ON THIS RESPONSE AND NOT ON `numbers/search` FOR A CONTRACT REASON
/// RATHER THAN A FILING ONE. The search response is byte-frozen by an Android contract
/// fixture and that client decodes with `ignoreUnknownKeys = false`, so adding a field
/// there is a breaking change. The route's own comment says so.
///
/// ⚠️ AN EMPTY ``registrations`` IS A REAL ANSWER (nothing filed yet) and a failed read
/// is not one. The envelope is what keeps them apart.
public struct NumberRegistrationsResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ Newest first.
    public let registrations: [NumberRegistration]
    /// ⛔ Where THIS workspace is approved. See the type doc.
    public let approvedCountries: [String]
    /// ⛔ Where the PLATFORM's registration covers a purchase. See the type doc.
    public let platformCountries: [String]
}

/// `POST /api/district/workspace/numbers/registrations` — the created draft.
///
/// ⚠️ ANSWERS **201**, and echoes the whole row, so the created filing can be adopted
/// without a re-read.
///
/// ⛔ A DRAFT IS A LOCAL ROW AND NOTHING AT THE CARRIER. No EndUser, no Bundle:
/// assembly happens once, at submit. So a screen must not describe a created draft as
/// "filed" or "submitted", which is the word the customer will otherwise use back at
/// us.
public struct NumberRegistrationCreatedResponse: Codable, Sendable {
    public let success: Bool
    public let registration: NumberRegistration
}

/// The row `POST …/registrations/documents` answers.
///
/// ⛔ NARROWER THAN ``RegistrationDocument`` AND WITH A DIFFERENT TIMESTAMP, WHICH IS
/// WHY IT IS ITS OWN TYPE. The upload answers `{id, requirementName, mimeType,
/// sizeBytes, createdAt}` — `createdAt`, not `updatedAt` — and carries neither
/// `stored` nor `submitted`. Reusing the list's type here would fail to decode a
/// perfectly good reply, and building a list row from this one would invent two
/// booleans. Re-read the list after an upload.
///
/// ⚠️ AND NO `storageKey`, for the reason on ``RegistrationDocument``.
public struct UploadedRegistrationDocument: Codable, Sendable {
    public let id: String
    public let requirementName: String
    /// ⚠️ The SNIFFED type. The declared one is used only to disagree with the bytes.
    public let mimeType: String
    public let sizeBytes: Int
    /// ⛔ `createdAt`, NOT `updatedAt`. See the type doc.
    public let createdAt: String
}

/// `POST /api/district/workspace/numbers/registrations/documents`.
public struct RegistrationDocumentResponse: Codable, Sendable {
    public let success: Bool
    public let document: UploadedRegistrationDocument
}

/// `DELETE /api/district/workspace/numbers/registrations/documents`.
///
/// ⚠️ IT ECHOES THE ID IT REMOVED, which is what lets a caller drop the right row
/// without re-reading — and is worth using rather than the id that was sent, since
/// the two agreeing is the server's confirmation rather than an assumption.
public struct RegistrationDocumentRemovalResponse: Codable, Sendable {
    public let success: Bool
    public let documentId: String
}

/// What a submitted filing looks like immediately afterwards.
///
/// ⚠️ THREE FIELDS ONLY, NOT A WHOLE ``NumberRegistration``. The submit answers `{id,
/// status, submittedAt}`, so a screen adopting this has to merge it into the row it
/// already holds rather than replacing it.
public struct SubmittedRegistration: Codable, Sendable {
    public let id: String
    /// ⚠️ The CARRIER's status for the freshly submitted bundle, typically
    /// `pending-review`.
    public let status: String
    public let submittedAt: String
}

/// `POST /api/district/workspace/numbers/registrations/submit`.
///
/// ⛔ THE 422's DETAIL IS NOT ON THIS TYPE AND CANNOT BE. An evaluated refusal is a
/// **422** with `{success: false, error, failures, reasons}` (or `missingFields` /
/// `missingRequirements`), which ``ApiError`` reduces to the sentence. That is
/// recoverable rather than lost: the route stores the carrier's structured failures
/// verbatim on the row, so re-reading ``NumberRegistrationsResponse`` returns them as
/// ``NumberRegistration/rejectionReasons``. A screen that showed only the sentence
/// would tell a customer their paperwork was refused without saying which part.
public struct NumberRegistrationSubmitResponse: Codable, Sendable {
    public let success: Bool
    public let registration: SubmittedRegistration
}

// MARK: - Releasing a number

/// `POST /api/district/workspace/numbers/release`.
///
/// ⛔ A **200 CARRYING `warnings` IS NOT A PARTIAL RELEASE, AND SWALLOWING THE ARRAY IS
/// THE EXPENSIVE MISTAKE.** The carrier has taken the number back — that part is done
/// and cannot be undone. What failed is a cleanup step AFTER it: the inbound trunk
/// still lists the number, or its `ManagedBillingItem` could not be moved to
/// `canceled`, which means THE WORKSPACE KEEPS BEING CHARGED FOR A NUMBER IT NO LONGER
/// HAS. A client that dropped the array would leave an operator believing they had
/// stopped a charge they had not.
///
/// ⛔ SO THIS IS A SUCCESS THAT MUST NOT ALWAYS BE DRAWN AS ONE. The route deliberately
/// does not answer 500 for these: telling the caller to retry a release that cannot
/// happen twice would send them into the ownership guard's 403, since the row it needs
/// has just been deleted.
///
/// ⚠️ THE KEY IS **ABSENT**, NOT AN EMPTY ARRAY, ON A CLEAN RELEASE — the route spreads
/// it conditionally — which is why it is Optional and why ``warningLines`` exists.
public struct NumberReleaseResponse: Codable, Sendable {
    public let success: Bool
    /// ⛔ ABSENT on a clean release. Present means the number is gone AND something
    /// after it did not finish. See the type doc; branch on ``warningLines``.
    public let warnings: [String]?

    /// The cleanup steps that did not finish, or empty when everything did.
    ///
    /// ⚠️ Computed, so it adds no key on re-encode, and it collapses absent and empty
    /// to one answer — which is safe here in a way it is not for
    /// ``OwnedNumbersResponse``, because there the flag and the names are two halves of
    /// one fact and here there is only the one.
    public var warningLines: [String] {
        warnings ?? []
    }
}
