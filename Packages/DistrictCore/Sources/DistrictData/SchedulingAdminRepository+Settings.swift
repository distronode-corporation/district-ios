import DistrictModel
import DistrictNetwork
import Foundation

// The `me.*` and `settings.*` ops, as named methods.
//
// ⛔ THESE ARE CONVENIENCES OVER ``SchedulingAdminRepository/perform(_:workspaceId:params:as:)``
// AND THEY DO NOT NARROW IT. `perform` stays public and stays the boundary: the
// server owns the catalog, and nothing here re-implements a path, a verb or a
// params schema. What a named method buys is the ONE thing `perform` genuinely
// cannot check — that the op and the response type agree — which is a runtime
// ``SchedulingAdminError/decoding(_:)`` at the generic call site and a compile
// error here.
//
// ⚠️ `params` IS STILL BUILT THROUGH ``JSONValue/object(_:)``, WHICH DROPS NILS.
// That is what makes a sparse patch sparse: an omitted field is an absent key
// rather than an explicit null, and on `me.patch` the fork leaves an absent field
// alone. ⛔ `settings.branding.patch` is the exception and takes every field (see
// ``SchedulingBrandingUpdate``).

public extension SchedulingAdminRepository {
    // MARK: - The caller's own scheduler account

    /// `me.get` — the signed-in member, as the scheduler knows them.
    ///
    /// ⚠️ `viewer`-LEVEL AND SELF-SCOPED. It answers for whoever holds the
    /// session, so there is no id to pass and no way to ask about somebody else.
    func me(workspaceId: String) async throws -> SchedulingMe {
        try await perform(.meGet, workspaceId: workspaceId, params: .object([]), as: SchedulingMe.self)
    }

    /// `me.patch` — change some of the caller's own preferences.
    ///
    /// ⚠️ SPARSE, AND SPENDING THE **MEMBER** BUDGET RATHER THAN THE WORKSPACE'S.
    /// `me.*` writes come out of the 30-per-member-per-hour bucket, not the
    /// workspace's 120; a settings screen that saved on every keystroke would lock
    /// one person out for an hour without touching anyone else.
    func updateMe(workspaceId: String, _ update: SchedulingMeUpdate) async throws -> SchedulingMe {
        try await perform(.mePatch, workspaceId: workspaceId, params: update.params, as: SchedulingMe.self)
    }

    /// `me.avatar.delete` — remove the caller's own picture.
    ///
    /// ⚠️ ANSWERS NOTHING, so the branding/avatar URL a screen is holding is stale
    /// the moment this returns. Re-read ``me(workspaceId:)``.
    func deleteAvatar(workspaceId: String) async throws -> SchedulingNoContent {
        try await perform(
            .meAvatarDelete,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingNoContent.self
        )
    }

    // MARK: - Branding

    /// `settings.branding.get` — the public booking page's look.
    func branding(workspaceId: String) async throws -> SchedulingBranding {
        try await perform(
            .settingsBrandingGet,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingBranding.self
        )
    }

    /// `settings.branding.patch` — REPLACE the branding, every field at once.
    ///
    /// ⛔ NOT A SPARSE PATCH, WHICH IS WHY THE ARGUMENT IS A STRUCT WITH NO
    /// OPTIONALS. The fork decodes into non-pointer fields, so an omitted
    /// `privacy_url` CLEARS it — the catalog makes all seven required precisely so
    /// that cannot happen by accident, and a caller has to send back what the GET
    /// returned. See ``SchedulingBrandingUpdate``.
    func updateBranding(
        workspaceId: String,
        _ update: SchedulingBrandingUpdate
    ) async throws -> SchedulingBranding {
        try await perform(
            .settingsBrandingPatch,
            workspaceId: workspaceId,
            params: update.params,
            as: SchedulingBranding.self
        )
    }

    /// `settings.branding.logo.delete`.
    ///
    /// ⚠️ THE ONLY WAY TO CLEAR A LOGO. `logo_url` is absent from the patch
    /// schema, so sending an empty string for it is a 400 naming a field that does
    /// not exist rather than a clear.
    func deleteBrandingLogo(workspaceId: String) async throws -> SchedulingNoContent {
        try await perform(
            .settingsBrandingLogoDelete,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingNoContent.self
        )
    }

    /// `settings.branding.banner.delete`. See ``deleteBrandingLogo(workspaceId:)``.
    func deleteBrandingBanner(workspaceId: String) async throws -> SchedulingNoContent {
        try await perform(
            .settingsBrandingBannerDelete,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingNoContent.self
        )
    }

    // MARK: - Recording storage, the notetaker and the summariser

    /// `settings.storage.get`.
    func storageSettings(workspaceId: String) async throws -> SchedulingStorageSettings {
        try await perform(
            .settingsStorageGet,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingStorageSettings.self
        )
    }

    /// `settings.storage.patch` — the one field it accepts.
    ///
    /// ⚠️ TURNING THIS ON DOES NOT MAKE RECORDING WORK. Read
    /// ``SchedulingStorageSettings/recordingsStorageReady`` back: an instance with
    /// no object storage records meetings that then have nowhere to upload to,
    /// and nothing about this call's success says which case a workspace is in.
    func setRecordingsEnabled(workspaceId: String, _ enabled: Bool) async throws -> SchedulingStorageSettings {
        try await perform(
            .settingsStoragePatch,
            workspaceId: workspaceId,
            params: .object([("recordings_enabled", .bool(enabled))]),
            as: SchedulingStorageSettings.self
        )
    }

    /// `settings.notetaker.get`.
    func notetakerSettings(workspaceId: String) async throws -> SchedulingNotetakerSettings {
        try await perform(
            .settingsNotetakerGet,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingNotetakerSettings.self
        )
    }

    /// `settings.notetaker.patch`.
    ///
    /// ⛔ ONE FIELD, AND THE SCHEMA IS `z.strictObject`. Anything else in the body
    /// — `stt_api_key` above all — is a **400 naming the field**, which is the
    /// intended behaviour: silently accepting a credential a customer believes
    /// they set is the worse of the two failures.
    func setNotetakerEnabled(workspaceId: String, _ enabled: Bool) async throws -> SchedulingNotetakerSettings {
        try await perform(
            .settingsNotetakerPatch,
            workspaceId: workspaceId,
            params: .object([("enabled", .bool(enabled))]),
            as: SchedulingNotetakerSettings.self
        )
    }

    /// `settings.llm.get`.
    func llmSettings(workspaceId: String) async throws -> SchedulingLLMSettings {
        try await perform(
            .settingsLlmGet,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingLLMSettings.self
        )
    }

    /// `settings.llm.patch` — both fields optional, `z.strictObject` again.
    ///
    /// ⚠️ PASSING NEITHER SENDS `{}`, WHICH IS A VALID NO-OP AND NOT AN ERROR. The
    /// schema marks both fields optional, so the request is accepted and changes
    /// nothing; it still spends a write from the workspace's budget, so a caller
    /// should decide not to send it rather than relying on the server to ignore it.
    ///
    /// - Parameter extraInstructions: capped at 4000 characters server-side.
    ///   ⚠️ `""` CLEARS IT and nil LEAVES IT ALONE — the difference is an absent
    ///   key, which ``JSONValue/object(_:)`` produces by dropping the nil.
    func updateLLMSettings(
        workspaceId: String,
        enabled: Bool? = nil,
        extraInstructions: String? = nil
    ) async throws -> SchedulingLLMSettings {
        try await perform(
            .settingsLlmPatch,
            workspaceId: workspaceId,
            params: .object([
                ("enabled", enabled.map(JSONValue.bool)),
                ("extra_instructions", JSONValue.optional(extraInstructions)),
            ]),
            as: SchedulingLLMSettings.self
        )
    }
}

/// The fields `me.patch` accepts, all optional.
///
/// ⛔ A STRUCT RATHER THAN TWELVE PARAMETERS, AND NOT ONLY FOR SwiftLint'S
/// `function_parameter_count`. Twelve same-typed optionals at a call site is a
/// shape where two arguments can be transposed silently — `notifyHostCancel` and
/// `notifyCancellation` are one word apart and mean mail to two different people —
/// and the compiler cannot object. Labelled properties make the transposition
/// visible at the place it would be written.
///
/// ⚠️ EVERY nil IS AN OMITTED KEY, NOT A CLEARED FIELD. ``JSONValue/object(_:)``
/// drops nil pairs, and the fork's `me.patch` handler leaves an absent field
/// alone — so a screen may send only what the user touched.
public struct SchedulingMeUpdate: Equatable, Sendable {
    public var name: String?
    /// ⛔ THE WIRE FIELD IS `timezone` AND THE COLUMN IS `iana_timezone`. Sending
    /// the column name is silently ignored, which leaves every window this member
    /// publishes on whatever zone the SSO hand-off inserted.
    public var timezone: String?
    /// `12h` or `24h`. ⚠️ Validated server-side by a `z.enum`; anything else is a
    /// **400 `invalid_params`** naming the field.
    public var timeFormat: String?
    /// 0-6, the fork's own numbering.
    public var weekStart: Int?
    /// `dmy`, `mdy` or `ymd`.
    public var dateFormat: String?
    public var notifyConfirmation: Bool?
    public var notifyCancellation: Bool?
    public var notifyReschedule: Bool?
    public var notifyReminder: Bool?
    public var notifyHostBooking: Bool?
    public var notifyHostCancel: Bool?
    public var notifyHostReschedule: Bool?

    public init(
        name: String? = nil,
        timezone: String? = nil,
        timeFormat: String? = nil,
        weekStart: Int? = nil,
        dateFormat: String? = nil,
        notifyConfirmation: Bool? = nil,
        notifyCancellation: Bool? = nil,
        notifyReschedule: Bool? = nil,
        notifyReminder: Bool? = nil,
        notifyHostBooking: Bool? = nil,
        notifyHostCancel: Bool? = nil,
        notifyHostReschedule: Bool? = nil
    ) {
        self.name = name
        self.timezone = timezone
        self.timeFormat = timeFormat
        self.weekStart = weekStart
        self.dateFormat = dateFormat
        self.notifyConfirmation = notifyConfirmation
        self.notifyCancellation = notifyCancellation
        self.notifyReschedule = notifyReschedule
        self.notifyReminder = notifyReminder
        self.notifyHostBooking = notifyHostBooking
        self.notifyHostCancel = notifyHostCancel
        self.notifyHostReschedule = notifyHostReschedule
    }

    /// ⚠️ THE KEYS ARE THE FORK'S SNAKE_CASE, SPELLED OUT. There is no encoder
    /// convention doing this: ``ApiClient`` encodes a plain ``JSONValue``, so a
    /// property renamed here without its string is a field the server never sees
    /// and never complains about.
    var params: JSONValue {
        .object([
            ("name", JSONValue.optional(name)),
            ("timezone", JSONValue.optional(timezone)),
            ("time_format", JSONValue.optional(timeFormat)),
            ("week_start", weekStart.map(JSONValue.integer)),
            ("date_format", JSONValue.optional(dateFormat)),
            ("notify_confirmation", notifyConfirmation.map(JSONValue.bool)),
            ("notify_cancellation", notifyCancellation.map(JSONValue.bool)),
            ("notify_reschedule", notifyReschedule.map(JSONValue.bool)),
            ("notify_reminder", notifyReminder.map(JSONValue.bool)),
            ("notify_host_booking", notifyHostBooking.map(JSONValue.bool)),
            ("notify_host_cancel", notifyHostCancel.map(JSONValue.bool)),
            ("notify_host_reschedule", notifyHostReschedule.map(JSONValue.bool)),
        ])
    }
}

/// The seven fields `settings.branding.patch` requires.
///
/// ⛔ NOTHING HERE IS OPTIONAL, AND THAT IS THE SHAPE OF THE FAR END RATHER THAN
/// STRICTNESS FOR ITS OWN SAKE. The fork's handler decodes into a struct of
/// non-pointer fields, so an omitted `privacy_url` CLEARS the customer's privacy
/// link. The catalog makes all seven required so the clear cannot happen by
/// accident, and this type makes "send back what you read" the only thing that
/// compiles.
///
/// ⛔ AND THE TWO IMAGE URLs ARE NOT HERE. `logo_url` and `banner_url` are
/// read-only on this op: they are set by the multipart upload and cleared by
/// their own delete ops.
public struct SchedulingBrandingUpdate: Equatable, Sendable {
    public var businessName: String
    public var logoHeight: Int
    /// 0-100, an integer percentage rather than a fraction.
    public var logoOpacity: Int
    public var bannerOpacity: Int
    /// ⚠️ `""` is the legitimate "no link" value; the server validates any
    /// non-empty string as a public URL.
    public var privacyUrl: String
    public var termsUrl: String
    public var fallbackLocale: String

    public init(
        businessName: String,
        logoHeight: Int,
        logoOpacity: Int,
        bannerOpacity: Int,
        privacyUrl: String,
        termsUrl: String,
        fallbackLocale: String
    ) {
        self.businessName = businessName
        self.logoHeight = logoHeight
        self.logoOpacity = logoOpacity
        self.bannerOpacity = bannerOpacity
        self.privacyUrl = privacyUrl
        self.termsUrl = termsUrl
        self.fallbackLocale = fallbackLocale
    }

    /// Everything the GET answered, minus what the patch may not carry.
    ///
    /// ⚠️ A CONVENIENCE THAT MAKES THE ROUND TRIP THE DEFAULT. The correct way to
    /// change one branding field is to read, edit and send the whole thing back;
    /// building the update by hand from a screen's state is how a field nobody
    /// edited gets cleared.
    public init(from branding: SchedulingBranding) {
        self.init(
            businessName: branding.businessName,
            logoHeight: branding.logoHeight,
            logoOpacity: branding.logoOpacity,
            bannerOpacity: branding.bannerOpacity,
            privacyUrl: branding.privacyUrl,
            termsUrl: branding.termsUrl,
            fallbackLocale: branding.fallbackLocale
        )
    }

    var params: JSONValue {
        .object([
            ("business_name", .string(businessName)),
            ("logo_height", .integer(logoHeight)),
            ("logo_opacity", .integer(logoOpacity)),
            ("banner_opacity", .integer(bannerOpacity)),
            ("privacy_url", .string(privacyUrl)),
            ("terms_url", .string(termsUrl)),
            ("fallback_locale", .string(fallbackLocale)),
        ])
    }
}
