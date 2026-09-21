import Foundation

// The scheduling admin's SELF and SETTINGS rows: `me.*`, `settings.branding.*`,
// `settings.storage.*`, `settings.notetaker.*` and `settings.llm.*`.
//
// ⛔ IN `DistrictModel` RATHER THAN BESIDE THE REPOSITORY, for the reason
// `SchedulingOverrideCreated.swift` states: `ContractFixtureTests` depends on
// `ContractGateSupport` and `DistrictModel` and nothing else, so a wire type that
// is not here is a wire type `StrictDecodeVerifier` cannot pin.
//
// ⚠️ SNAKE_CASE ON THE WIRE. These rows come from the scheduler fork through our
// RPC, not from a Distronode route, so every key is spelled out in `CodingKeys`.
// ⛔ Do not reach for `.convertFromSnakeCase` on the shared decoder: ``ApiClient``
// uses a plain `JSONDecoder` for every route in the client, and changing it would
// re-map the whole District surface to chase these.
//
// ⚠️ `Codable`, NOT `Decodable`. Nothing in the app encodes one; the gate does,
// because its unknown-key check IS a re-encode.
//
// ⛔ THE SHAPES HERE ARE THE CATALOG'S ALLOWLIST, NOT THE FORK'S RESPONSE, AND
// THE DIFFERENCE IS THE WHOLE POINT OF THREE OF THESE FIVE TYPES. `admin-ops.ts`
// re-declares each body as a zod schema and the route parses through it, so a
// field the fork sends and the schema omits never reaches this client at all.
// Adding a property here to "match the fork" would model a key that is stripped
// one hop away, and the strict gate would fail on the added key rather than the
// intent — which is the correct outcome and worth knowing before making the edit.

/// The signed-in member, as the scheduler knows them (`me.get`, `me.patch`).
///
/// ⚠️ A SECOND IDENTITY FOR THE SAME PERSON, AND IT IS NOT THE DISTRICT ACCOUNT.
/// ``id`` is the scheduler's user id, minted by `ensureSchedulerIdentity` on first
/// use; ``role`` is the SCHEDULER's role word and is not a ``WorkspaceRole``. A
/// screen that mixed the two would gate a District control on a fork's vocabulary.
///
/// ⛔ `is_admin` AND `is_owner` ARE THE FORK'S OWN FLAGS AND NEITHER IS THIS
/// APP'S AUTHORISATION. Every op's real gate is `minRole` in the catalog, checked
/// server-side against the District workspace role — see
/// ``SchedulingAdminOp/minRole``. These two are worth rendering (an owner cannot
/// be archived, and it explains why a control is missing) and must never be the
/// reason a request is or is not sent.
///
/// ⚠️ `timezone` IS THE WIRE FIELD AND `iana_timezone` IS THE COLUMN. The handler
/// decodes `timezone`; sending the column name on a patch is silently ignored,
/// which leaves every window this member publishes on whatever zone the SSO
/// hand-off inserted. The same name is therefore used on the way out — see
/// ``SchedulingMeUpdate``.
public struct SchedulingMe: Codable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let name: String
    /// An IANA zone name (`America/Toronto`). ⚠️ Not validated here: the fork owns
    /// the list, and a zone this client cannot resolve is a label to show rather
    /// than a response to reject.
    public let timezone: String
    /// `12h` or `24h`. ⚠️ A `String` rather than an enum, unlike
    /// ``SchedulingTenantStatus``: the RESPONSE schema types it `z.string()` and
    /// only the PATCH schema constrains it, so the fork may answer a third value
    /// and a throwing enum here would take out the whole settings screen over a
    /// preference.
    public let timeFormat: String
    /// 0 (Sunday) to 6. ⚠️ The fork's own numbering, not `Calendar`'s.
    public let weekStart: Int
    /// `dmy`, `mdy` or `ymd`. A `String` for ``timeFormat``'s reason.
    public let dateFormat: String
    /// ⛔ A FLAG TO RENDER, NEVER A GATE. See the type note.
    public let isAdmin: Bool
    /// ⛔ A FLAG TO RENDER, NEVER A GATE. See the type note.
    public let isOwner: Bool
    /// The scheduler's role word. ⛔ NOT a ``WorkspaceRole``.
    public let role: String
    /// Send the booker a confirmation.
    public let notifyConfirmation: Bool
    public let notifyCancellation: Bool
    public let notifyReschedule: Bool
    public let notifyReminder: Bool
    /// Tell the HOST a booking was made. ⚠️ The four `notifyHost*` flags are about
    /// mail to this member; the four above are about mail to their bookers, and
    /// the two sets are independently switchable.
    public let notifyHostBooking: Bool
    public let notifyHostCancel: Bool
    public let notifyHostReschedule: Bool
    /// ⚠️ ABSENT, NOT NULL, WHEN UNSET. The fork omits the key entirely for a
    /// member who has never uploaded a picture (`avatar_url: z.string().optional()`),
    /// so this Optional means "no key arrived" and the fixture's explicit-null
    /// register has nothing to say about it.
    public let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case timezone
        case timeFormat = "time_format"
        case weekStart = "week_start"
        case dateFormat = "date_format"
        case isAdmin = "is_admin"
        case isOwner = "is_owner"
        case role
        case notifyConfirmation = "notify_confirmation"
        case notifyCancellation = "notify_cancellation"
        case notifyReschedule = "notify_reschedule"
        case notifyReminder = "notify_reminder"
        case notifyHostBooking = "notify_host_booking"
        case notifyHostCancel = "notify_host_cancel"
        case notifyHostReschedule = "notify_host_reschedule"
        case avatarUrl = "avatar_url"
    }
}

/// One locale the public booking page offers.
public struct SchedulingLocaleOption: Codable, Equatable, Sendable {
    /// `en`, `fr`. ⚠️ The fork's own code, which is not guaranteed to be a BCP-47
    /// tag and must not be fed to `Locale(identifier:)` expecting a region.
    public let code: String
    /// The language's name IN THAT LANGUAGE (`Français`), which is how a language
    /// picker should read. ⛔ Not localisable from here and not meant to be.
    public let name: String
}

/// The workspace's public booking-page branding (`settings.branding.*`).
///
/// ⛔ THE PATCH IS REPLACE, NOT MERGE, AND THAT IS A PROPERTY OF THE FAR END
/// RATHER THAN OF THE SCHEMA. The fork's handler decodes into a struct of
/// non-pointer fields, so an omitted `privacy_url` CLEARS it. The catalog
/// therefore makes every field required on `settings.branding.patch`, and a UI
/// has to send back what the GET returned. See ``SchedulingBrandingUpdate``.
///
/// ⛔ `logoUrl` AND `bannerUrl` ARE READ-ONLY HERE AND ARE NOT ON THE PATCH. The
/// only way to change either is the multipart upload
/// (``SchedulingAdminUploadTarget``) or the matching delete op; a client that put
/// a URL in the patch body would get a 400 naming a field the schema does not
/// have.
///
/// ⚠️ `""` IS THE ORDINARY VALUE FOR AN UNSET LINK, NOT AN ERROR. `privacy_url`
/// is a required `z.string()` and the fixture carries it empty — so emptiness is
/// the "no link" test, and an Optional here would be a shape the server never
/// sends.
public struct SchedulingBranding: Codable, Equatable, Sendable {
    public let businessName: String
    /// ⛔ Set by upload, cleared by `settings.branding.logo.delete`. Never patched.
    public let logoUrl: String
    /// Points, as the booking page renders it.
    public let logoHeight: Int
    /// 0-100. ⚠️ A percentage as an integer, not a 0-1 fraction: a client that
    /// divided once too often renders an invisible logo and nothing errors.
    public let logoOpacity: Int
    /// ⛔ Set by upload, cleared by `settings.branding.banner.delete`.
    public let bannerUrl: String
    /// 0-100, like ``logoOpacity``.
    public let bannerOpacity: Int
    /// ⚠️ `""` when unset. See the type note.
    public let privacyUrl: String
    /// ⚠️ `""` when unset.
    public let termsUrl: String
    /// The locale a booker falls back to. ⚠️ Not guaranteed to appear in
    /// ``supportedLocales``, which is the fork's business and not something to
    /// "repair" client-side.
    public let fallbackLocale: String
    /// ⚠️ OPTIONAL AND MEANS "THE KEY DID NOT ARRIVE", which is a different fact
    /// from an empty list. A deployment with no locale table omits it; a tenancy
    /// that genuinely offers none would send `[]`.
    public let supportedLocales: [SchedulingLocaleOption]?

    enum CodingKeys: String, CodingKey {
        case businessName = "business_name"
        case logoUrl = "logo_url"
        case logoHeight = "logo_height"
        case logoOpacity = "logo_opacity"
        case bannerUrl = "banner_url"
        case bannerOpacity = "banner_opacity"
        case privacyUrl = "privacy_url"
        case termsUrl = "terms_url"
        case fallbackLocale = "fallback_locale"
        case supportedLocales = "supported_locales"
    }
}

/// Recording storage, as much of it as a tenant may see (`settings.storage.*`).
///
/// ⛔ `backups_configured`, `backups_bucket` AND `backups_endpoint` ARE ABSENT
/// FROM THE CATALOG'S SCHEMA AND MUST NOT BE ADDED HERE. They describe the
/// INSTANCE's own object storage, which is ours and is shared: naming the bucket
/// to one tenant tells them where every other tenancy's recordings live. The
/// route strips them, so a property for one would model a key that cannot arrive.
public struct SchedulingStorageSettings: Codable, Equatable, Sendable {
    /// Whether meetings are recorded at all. The one field
    /// `settings.storage.patch` accepts.
    public let recordingsEnabled: Bool
    /// ⛔ "THE INSTANCE HAS SOMEWHERE TO PUT THEM", WHICH IS NOT THE SAME QUESTION
    /// AS ``recordingsEnabled`` AND IS NOT THE TENANT'S TO FIX. Recording switched
    /// on with storage unready produces meetings that record and then have nothing
    /// to upload to; a screen should say so rather than offering a retry.
    /// ⚠️ Optional: absent on a fork that predates the field.
    public let recordingsStorageReady: Bool?
    /// Where this tenancy's objects are keyed. ⚠️ A PREFIX, not a bucket — the
    /// bucket is deliberately not published. Optional for the same reason as above.
    public let recordingsPrefix: String?

    enum CodingKeys: String, CodingKey {
        case recordingsEnabled = "recordings_enabled"
        case recordingsStorageReady = "recordings_storage_ready"
        case recordingsPrefix = "recordings_prefix"
    }
}

/// The meeting notetaker's one switch (`settings.notetaker.*`).
///
/// ⛔ ONE FIELD, AND THE PATCH SCHEMA IS `z.strictObject` SO A SECOND ONE IS A
/// 400 NAMING IT. `stt_api_key` is the field that closure exists to refuse: the
/// fork would store a tenant-supplied speech-to-text credential on the INSTANCE,
/// which every other tenancy on that deployment then transcribes through.
/// `stt_base_url` is stripped from the response for the same reason. A tenant
/// needs to know the notetaker is on, not what powers it.
public struct SchedulingNotetakerSettings: Codable, Equatable, Sendable {
    public let enabled: Bool
}

/// The meeting summariser (`settings.llm.*`).
///
/// ⛔ THE ALLOWLIST'S SHARPEST CASE, AND THE ABSENCES ARE THE CONTRACT. The fork
/// also returns `endpoint`, `model`, `api_key_set`, `configured`, `active` and
/// `base_prompt`; the catalog publishes two fields. The first three name an
/// instance credential and the model this platform pays for — a tenant may turn
/// the summariser on and write instructions for it, and may not learn what it is.
/// ⚠️ So a settings screen genuinely cannot show "which model", and that is the
/// answer rather than a gap to fill.
///
/// ⚠️ `extraInstructions` IS REQUIRED AND `""` IS ITS EMPTY STATE. The schema
/// types it `z.string()`, not `.optional()`; an Optional here would be a shape
/// the server never sends.
public struct SchedulingLLMSettings: Codable, Equatable, Sendable {
    public let enabled: Bool
    /// The tenant's own prompt addendum, capped at 4000 characters by the patch
    /// schema. ⚠️ Free text written by a customer — never interpolate it into
    /// anything that executes, and never echo it into a log line.
    public let extraInstructions: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case extraInstructions = "extra_instructions"
    }
}
