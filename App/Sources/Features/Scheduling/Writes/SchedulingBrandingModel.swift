import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The public booking page's look: seven fields, a logo and a banner.
///
/// ⛔ THE PATCH IS A REPLACEMENT, NOT A SPARSE PATCH, AND THAT IS WHY THIS MODEL
/// REFUSES TO EXIST WITHOUT A LOADED ``SchedulingBranding``. The fork decodes into
/// non-pointer fields, so an omitted `privacy_url` CLEARS the customer's privacy
/// link; the catalog makes all seven required precisely so that cannot happen by
/// accident, and ``SchedulingBrandingUpdate/init(from:)`` makes "send back what you
/// read" the only thing that compiles. A form seeded from nothing does not save
/// nothing — it deletes two legal links and a business name.
///
/// ⛔ AND THE TWO IMAGE URLs ARE NOT PART OF IT. `logo_url` and `banner_url` are
/// read-only on the patch: they are set by the multipart upload and cleared by
/// their own delete ops, so an empty string sent for either is a 400 naming a
/// field that does not exist rather than a clear.
///
/// ⚠️ THESE UPLOADS ARE `client`-LEVEL AND SPEND THE WORKSPACE'S 120-an-hour
/// bucket, unlike the avatar on ``SchedulingProfileModel``, which is `viewer` and
/// spends the member's 30. They are separate budgets on purpose.
@MainActor
@Observable
final class SchedulingBrandingModel {
    private(set) var state: SchedulingWritesBState = .idle
    private(set) var logoState: SchedulingWritesBState = .idle
    private(set) var bannerState: SchedulingWritesBState = .idle
    private(set) var branding: SchedulingBranding

    private(set) var businessName: String
    private(set) var logoHeight: Int
    private(set) var logoOpacity: Int
    private(set) var bannerOpacity: Int
    private(set) var privacyUrl: String
    private(set) var termsUrl: String
    private(set) var fallbackLocale: String
    private(set) var rejected: String?

    private let admin: SchedulingAdminRepository
    private let media: SchedulingAdminMediaRepository
    private let workspaceId: String
    private let onSaved: (SchedulingBranding) -> Void

    init(
        admin: SchedulingAdminRepository,
        media: SchedulingAdminMediaRepository,
        workspaceId: String,
        branding: SchedulingBranding,
        onSaved: @escaping (SchedulingBranding) -> Void
    ) {
        self.admin = admin
        self.media = media
        self.workspaceId = workspaceId
        self.branding = branding
        self.onSaved = onSaved
        businessName = branding.businessName
        logoHeight = branding.logoHeight
        logoOpacity = branding.logoOpacity
        bannerOpacity = branding.bannerOpacity
        privacyUrl = branding.privacyUrl
        termsUrl = branding.termsUrl
        fallbackLocale = branding.fallbackLocale
    }

    var busy: Bool {
        state.isWorking || logoState.isWorking || bannerState.isWorking
    }

    var logoUrl: String? {
        branding.logoUrl.isEmpty ? nil : branding.logoUrl
    }

    var bannerUrl: String? {
        branding.bannerUrl.isEmpty ? nil : branding.bannerUrl
    }

    /// ⚠️ THE OPTIONS COME FROM THE SERVER, not from a list held here. An absent
    /// `supported_locales` leaves the stored value as the only choice, which is the
    /// honest rendering of "we were not told what else is available".
    var localeOptions: [SchedulingLocaleOption] {
        branding.supportedLocales ?? []
    }

    func editBusinessName(_ value: String) {
        businessName = value
        clearRejection()
    }

    func editLogoHeight(_ value: Int) {
        logoHeight = value
        clearRejection()
    }

    func editLogoOpacity(_ value: Int) {
        logoOpacity = value
        clearRejection()
    }

    func editBannerOpacity(_ value: Int) {
        bannerOpacity = value
        clearRejection()
    }

    func editPrivacyUrl(_ value: String) {
        privacyUrl = value
        clearRejection()
    }

    func editTermsUrl(_ value: String) {
        termsUrl = value
        clearRejection()
    }

    func editFallbackLocale(_ value: String) {
        fallbackLocale = value
        clearRejection()
    }

    /// ⚠️ THE WEB'S ORDER AND THE WEB'S SENTENCES.
    ///
    /// ⚠️ THE THREE LOCALS ARE NOT STYLE. A wrapped multi-line `if` condition makes
    /// SwiftFormat put the opening brace on its own line and SwiftLint's
    /// `opening_brace` then refuses it — the same unsatisfiable pair the
    /// `trailing_comma` note in `.swiftlint.yml` describes. Keeping every condition
    /// on one line is what keeps both gates green without configuring either off.
    var validationFailure: String? {
        let name = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        let heights = SchedulingSettingsWriteCopy.logoHeightRange
        let opacities = SchedulingSettingsWriteCopy.opacityRange
        if name.count > SchedulingSettingsWriteCopy.businessNameLimit {
            return SchedulingSettingsWriteCopy.businessNameTooLong
        }
        if !heights.contains(logoHeight) {
            return SchedulingSettingsWriteCopy.wholeNumberBetween(heights.lowerBound, heights.upperBound)
        }
        if !opacities.contains(logoOpacity) || !opacities.contains(bannerOpacity) {
            return SchedulingSettingsWriteCopy.wholeNumberBetween(opacities.lowerBound, opacities.upperBound)
        }
        if let failure = Self.urlFailure(privacyUrl) ?? Self.urlFailure(termsUrl) {
            return failure
        }
        if fallbackLocale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SchedulingSettingsWriteCopy.fallbackLocaleRequired
        }
        return nil
    }

    func save() async {
        guard !busy else { return }
        if let failure = validationFailure {
            rejected = failure
            return
        }
        let update = SchedulingBrandingUpdate(
            businessName: businessName.trimmingCharacters(in: .whitespacesAndNewlines),
            logoHeight: logoHeight,
            logoOpacity: logoOpacity,
            bannerOpacity: bannerOpacity,
            privacyUrl: privacyUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            termsUrl: termsUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            fallbackLocale: fallbackLocale
        )
        state = .working
        do {
            try await adopt(admin.updateBranding(workspaceId: workspaceId, update))
            state = .done(SchedulingSettingsWriteCopy.brandingDone)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    func upload(bytes: Data, mimeType: String, target: SchedulingAdminUploadTarget) async {
        guard !busy, target != .avatar else { return }
        let file = SchedulingWritesBImage.file(bytes: bytes, mimeType: mimeType, target: target)
        if let rejection = SchedulingWritesBImage.rejection(for: file) {
            set(.failed(FailureText(message: rejection, action: .none)), for: target)
            return
        }
        set(.working, for: target)
        do {
            _ = try await media.upload(workspaceId: workspaceId, target: target, file: file)
            // ⛔ RE-READS RATHER THAN TRUSTING THE ANSWER'S URL. The upload's one
            // key can legitimately be `""` — "uploaded, address unreadable" — and
            // ``SchedulingBranding`` is a wire DTO this module cannot rebuild with
            // one field changed, so `settings.branding.get` is the only way to hold
            // a consistent row.
            await reread()
            set(.done(SchedulingSettingsWriteCopy.imageUploaded(Self.label(target))), for: target)
        } catch {
            set(.failed(SchedulingWritesBFailure.text(for: error)), for: target)
        }
    }

    /// ⚠️ A THIRD ANSWER, distinct from a rejected type and a rejected size. See
    /// ``SchedulingProfileModel/reportUnreadableAvatar()``.
    func reportUnreadable(_ target: SchedulingAdminUploadTarget) {
        guard target != .avatar else { return }
        set(
            .failed(FailureText(message: SchedulingSettingsWriteCopy.imageUnreadable, action: .none)),
            for: target
        )
    }

    /// ⚠️ THE ONLY WAY TO CLEAR EITHER IMAGE. `logo_url` is absent from the patch
    /// schema, so sending an empty string for it is a 400 naming a field that does
    /// not exist rather than a clear.
    func removeImage(_ target: SchedulingAdminUploadTarget) async {
        guard !busy, target != .avatar else { return }
        set(.working, for: target)
        do {
            if target == .logo {
                _ = try await admin.deleteBrandingLogo(workspaceId: workspaceId)
            } else {
                _ = try await admin.deleteBrandingBanner(workspaceId: workspaceId)
            }
            await reread()
            set(.done(SchedulingSettingsWriteCopy.imageRemoved(Self.label(target))), for: target)
        } catch {
            set(.failed(SchedulingWritesBFailure.text(for: error)), for: target)
        }
    }

    /// ⚠️ A FAILED RE-READ AFTER A WRITE THAT LANDED LEAVES THE OLD ROW ALONE. The
    /// image IS changed; only this copy is stale.
    private func reread() async {
        guard let fresh = try? await admin.branding(workspaceId: workspaceId) else { return }
        adopt(fresh)
    }

    /// ⛔ THE DRAFTS ARE **NOT** RESEEDED. An image upload answers the whole
    /// branding row, and adopting its seven text fields over a form the operator is
    /// part-way through editing would silently discard their typing. Only
    /// ``branding`` moves; the drafts are theirs until they save.
    private func adopt(_ fresh: SchedulingBranding) {
        branding = fresh
        onSaved(fresh)
    }

    private func set(_ next: SchedulingWritesBState, for target: SchedulingAdminUploadTarget) {
        if target == .logo {
            logoState = next
        } else {
            bannerState = next
        }
    }

    private static func label(_ target: SchedulingAdminUploadTarget) -> String {
        target == .logo ? SchedulingSettingsWriteCopy.logoLabel : SchedulingSettingsWriteCopy.bannerLabel
    }

    /// ⚠️ EMPTY IS THE LEGITIMATE "NO LINK" VALUE and is not a failure; the server
    /// validates any NON-empty string as a public URL. ⛔ `URL(string:)` alone is
    /// not that check — it accepts a bare `example.com` — so the scheme is tested
    /// explicitly, which is what makes the sentence "starting with https://" true.
    static func urlFailure(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        if trimmed.count > SchedulingSettingsWriteCopy.legalUrlLimit {
            return SchedulingSettingsWriteCopy.urlTooLong
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else {
            return SchedulingSettingsWriteCopy.urlNotAbsolute
        }
        return nil
    }

    private func clearRejection() {
        rejected = nil
        if case .failed = state {
            state = .idle
        }
    }
}
