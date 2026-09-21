import Foundation

// The three phone-number requests that carry more than a couple of values, as TYPES.
//
// ⛔ A TYPE RATHER THAN LOOSE PARAMETERS, AND THE ARGUMENT COUNT IS THE SMALLER HALF OF THE
// REASON. `submitA2PRegistration` took NINE arguments of which eight were `String`, and
// `submitTollFreeVerification` took eight of which six were: at those shapes a transposition at
// a call site COMPILES and posts a website where a business name belongs, or an example message
// where a campaign description does. `MessagingAccountDraft` was extracted for exactly this and
// says so on its own ⛔; the Kotlin client keeps request types for the same reason.
// ⛔ AND EMPHATICALLY NOT A DICTIONARY. A `[String: String]` payload would satisfy the argument
// count and defeat the point of this whole surface: the typed-endpoint gate is what makes the
// set of expressible requests exactly ``EndpointID/allCases``, and an untyped bag reopens every
// field to a typo the compiler cannot see.
//
// ⚠️ THEY LIVE IN `DistrictNetwork` BESIDE THE DESCRIPTORS, NOT IN `DistrictModel`, matching
// ``MessagingAccountDraft`` and ``DeskTicketDraft``. `DistrictModel` holds what the server
// ANSWERS; a request draft is an argument list with a name, and putting it there would make the
// DTO layer a dependency of the request builders it deliberately is not.
//
// ⚠️ THEIR OWN FILE RATHER THAN THE HEAD OF EACH DESCRIPTOR FILE, which is SwiftLint's 500-line
// `file_length` and nothing deeper: `DistrictEndpoints+Numbers.swift` is at 456 lines and the
// per-route commentary is the point of it.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE: SwiftFormat's `docComments` rule rejects a doc
// comment attached to no declaration.

/// One supporting document, as the multipart upload takes it.
///
/// ⛔ THE WORKSPACE IS DELIBERATELY NOT A FIELD HERE. It travels in the QUERY on that route —
/// `formData()` buffers the whole body before anything can look at it, so an id carried in the
/// parts would force that buffering on unauthenticated callers — and holding it on this type
/// would invite exactly the copy-paste that leaves `requireWorkspaceRole` with null while the
/// URL reads perfectly correct. See ``DistrictPaths/numbersRegistrationDocuments``.
///
/// ⛔ `requirementName` IS THE CARRIER'S MACHINE NAME (`business_registration_number_info` and
/// friends), never a label we invented: it is read back when deciding which requirements are
/// still unsatisfied, so a friendly string files a document against nothing. Bounded
/// server-side to `/^[A-Za-z0-9_.-]{1,120}$/`.
///
/// ⚠️ `mimeType` IS USED FOR ONE THING ONLY: DISAGREEING WITH THE BYTES. The route sniffs the
/// real type and answers **415** naming both when they differ; the declared value never selects
/// a code path.
public struct RegulatoryDocumentUpload: Sendable, Equatable {
    /// The draft filing this document belongs to.
    public let bundleId: String
    /// ⛔ The carrier's machine name. See the type doc.
    public let requirementName: String
    /// ⚠️ Carried for the server's benefit, and omitting it makes the part a plain field rather
    /// than a file — at which point `file instanceof File` fails and the route answers 400.
    public let fileName: String
    /// ⚠️ `application/pdf`, `image/png` or `image/jpeg`. See the type doc.
    public let mimeType: String
    public let bytes: Data

    public init(bundleId: String, requirementName: String, fileName: String, mimeType: String, bytes: Data) {
        self.bundleId = bundleId
        self.requirementName = requirementName
        self.fileName = fileName
        self.mimeType = mimeType
        self.bytes = bytes
    }
}

/// An A2P 10DLC registration, as the submission takes it.
///
/// ⛔ EIGHT FIELDS OF WHICH SEVEN ARE STRINGS, WHICH IS WHY THIS IS A TYPE. See the ⛔ at the
/// head of this file: at that shape a transposition compiles.
///
/// ⛔ `campaignType` DECIDES THE BRAND TYPE AND THE PRICE, so it is not an ordinary label.
/// `LOW_VOLUME` registers a `SOLE_PROPRIETOR` brand billed at $1.50/month; anything else
/// registers a `STANDARD` brand at $10.00. ⚠️ And the route's use-case map knows only
/// `LOW_VOLUME`, `CUSTOMER_CARE`, `MARKETING` and `2FA` — anything unrecognised falls through to
/// `MIXED` rather than being refused, so a typo files a campaign under the wrong use case
/// silently.
///
/// ⚠️ THE THREE OPTIONAL BUSINESS FIELDS ARE NOT DECORATION. Twilio's `brandRegistrations` API
/// does not accept them; they populate the TrustHub Customer Profile, which is a manual
/// per-account Console step, and the route PERSISTS them even on the refused path — which is
/// exactly when whoever builds that profile needs them.
public struct A2PRegistrationDraft: Sendable, Equatable {
    public let businessName: String
    /// ⚠️ Employer Identification Number or company number. Persisted for the manual TrustHub
    /// step, not forwarded to the brand registration.
    public let ein: String?
    public let website: String?
    public let vertical: String?
    /// ⛔ Decides the brand type and the price. See the type doc.
    public let campaignType: String
    /// ⚠️ Sent as BOTH the campaign description (truncated to 4096) and its message flow
    /// (truncated to 2048).
    public let campaignDescription: String
    public let sampleMessage1: String
    public let sampleMessage2: String

    public init(
        businessName: String,
        campaignType: String,
        campaignDescription: String,
        sampleMessage1: String,
        sampleMessage2: String,
        ein: String? = nil,
        website: String? = nil,
        vertical: String? = nil
    ) {
        self.businessName = businessName
        self.campaignType = campaignType
        self.campaignDescription = campaignDescription
        self.sampleMessage1 = sampleMessage1
        self.sampleMessage2 = sampleMessage2
        self.ein = ein
        self.website = website
        self.vertical = vertical
    }
}

/// A toll-free verification, as the submission takes it.
///
/// ⛔ `optInImageUrls` MUST BE NON-EMPTY AND MUST BE THE TENANT'S OWN EVIDENCE. Twilio's
/// reviewers open every URL by hand and reject the filing days later with error 30509 if one
/// does not load, so the route refuses an empty list up front — a 400 now beats losing days. ⛔
/// And a Distronode-owned asset could never satisfy it in principle: this is a BYOK flow, every
/// workspace is a different business, and the evidence has to demonstrate THAT business's
/// declared opt-in. The placeholder this route once hardcoded is rejected by pathname.
///
/// ⚠️ `useCase` IS MAPPED, NOT VALIDATED. `Customer Support`, `Marketing`, `Notifications` and
/// `2FA / OTP` map to the carrier's categories and anything else falls through to `OTHER`, so a
/// typo files under the wrong category rather than being refused.
///
/// ⚠️ TWO OF THE OPTIONALS HAVE SERVER-SIDE FALLBACKS THAT A REVIEWER WILL READ. An absent
/// `messageContent` becomes "Hi, thanks for contacting us. Reply STOP to opt out." and an absent
/// `optInFlow` becomes "Customer support and account notifications." Both are real text going
/// into a manual review, so leaving them blank is a choice rather than a no-op.
public struct TollFreeVerificationDraft: Sendable, Equatable {
    /// ⚠️ Must be a number this workspace owns AND that lives on the connected carrier account.
    /// Those are two different refusals — **404** and **400** — that read alike.
    public let phoneNumber: String
    public let businessName: String
    public let website: String?
    /// ⚠️ Mapped, not validated. See the type doc.
    public let useCase: String
    /// ⚠️ Has a server-side fallback a reviewer reads. See the type doc.
    public let messageContent: String?
    /// ⚠️ Becomes the carrier's `useCaseSummary`, with a fallback. See the type doc.
    public let optInFlow: String?
    /// ⛔ Required and non-empty. See the type doc.
    public let optInImageUrls: [String]

    public init(
        phoneNumber: String,
        businessName: String,
        useCase: String,
        optInImageUrls: [String],
        website: String? = nil,
        messageContent: String? = nil,
        optInFlow: String? = nil
    ) {
        self.phoneNumber = phoneNumber
        self.businessName = businessName
        self.useCase = useCase
        self.optInImageUrls = optInImageUrls
        self.website = website
        self.messageContent = messageContent
        self.optInFlow = optInFlow
    }
}
