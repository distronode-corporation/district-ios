import DistrictNetwork
import SwiftUI

/// The public booking page: seven fields plus a logo and a banner.
///
/// ⛔ THE SLIDERS ARE CLAMPED TO THE FORK'S OWN RANGES so a value the server
/// refuses cannot be produced at all. The validation behind them is still there
/// and is still checked before the request — a control cannot be the guarantee.
struct SchedulingBrandingSheet: View {
    @Bindable var model: SchedulingBrandingModel
    let onClose: () -> Void

    var body: some View {
        SchedulingWritesBSheet(
            title: SchedulingSettingsWriteCopy.brandingTitle,
            subtitle: nil,
            cancelLabel: SchedulingTeamWriteCopy.close,
            confirmLabel: SchedulingSettingsWriteCopy.brandingSave,
            confirmIdentifier: A11yID.SchedulingWritesB.brandingSave,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                fields
                images
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.save() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.brandingSheet)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            SettingsField(
                label: SchedulingSettingsWriteCopy.businessNameLabel,
                text: Binding(get: { model.businessName }, set: { model.editBusinessName($0) }),
                enabled: !model.busy
            )
            .accessibilityIdentifier(A11yID.SchedulingWritesB.brandingBusinessName)
            SchedulingWritesBHint(text: SchedulingSettingsWriteCopy.businessNameHint)
            slider(
                SchedulingSettingsWriteCopy.logoHeightLabel,
                SchedulingSettingsWriteCopy.logoHeightHint,
                model.logoHeight,
                SchedulingSettingsWriteCopy.logoHeightRange
            ) { model.editLogoHeight($0) }
            slider(
                SchedulingSettingsWriteCopy.logoOpacityLabel,
                SchedulingSettingsWriteCopy.opacityHint,
                model.logoOpacity,
                SchedulingSettingsWriteCopy.opacityRange
            ) { model.editLogoOpacity($0) }
            slider(
                SchedulingSettingsWriteCopy.bannerOpacityLabel,
                SchedulingSettingsWriteCopy.opacityHint,
                model.bannerOpacity,
                SchedulingSettingsWriteCopy.opacityRange
            ) { model.editBannerOpacity($0) }
            legalLinks
            locale
            SchedulingWritesBRejection(message: model.rejected)
        }
    }

    private var legalLinks: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            SettingsField(
                label: SchedulingSettingsWriteCopy.privacyUrlLabel,
                text: Binding(get: { model.privacyUrl }, set: { model.editPrivacyUrl($0) }),
                enabled: !model.busy
            )
            // ⛔ NO AUTOCAPITALISATION AND NO AUTOCORRECTION ON A URL FIELD. iOS
            // capitalises the first letter by default, which turns `https` into
            // `Https` and makes an address the server refuses.
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            SettingsField(
                label: SchedulingSettingsWriteCopy.termsUrlLabel,
                text: Binding(get: { model.termsUrl }, set: { model.editTermsUrl($0) }),
                enabled: !model.busy
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            SchedulingWritesBHint(text: SchedulingSettingsWriteCopy.legalUrlHint)
        }
    }

    /// ⚠️ THE OPTIONS COME FROM THE SERVER'S `supported_locales`. An empty list is
    /// rendered as a hint rather than an empty picker, because a picker with
    /// nothing in it reads as a broken control.
    @ViewBuilder
    private var locale: some View {
        if model.localeOptions.isEmpty {
            SchedulingWritesBHint(text: SchedulingSettingsWriteCopy.fallbackLocaleHint)
        } else {
            Picker(
                SchedulingSettingsWriteCopy.fallbackLocaleLabel,
                selection: Binding(get: { model.fallbackLocale }, set: { model.editFallbackLocale($0) })
            ) {
                ForEach(model.localeOptions, id: \.code) { option in
                    Text(option.name).tag(option.code)
                }
            }
            .disabled(model.busy)
            SchedulingWritesBHint(text: SchedulingSettingsWriteCopy.fallbackLocaleHint)
        }
    }

    /// ⚠️ THE VALUE IS AN `Int` ON THE WIRE AND A `Double` IN THE CONTROL, so the
    /// rounding happens in one place rather than at each read.
    private func slider(
        _ label: String,
        _ hint: String,
        _ value: Int,
        _ range: ClosedRange<Int>,
        _ onChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text("\(label): \(value)")
                .font(DistrictType.labelSmall)
            Slider(
                value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
                in: Double(range.lowerBound) ... Double(range.upperBound),
                step: 1
            )
            .disabled(model.busy)
            .accessibilityLabel(label)
            .accessibilityValue("\(value)")
            SchedulingWritesBHint(text: hint)
        }
    }

    private var images: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            SchedulingWritesBImageRow(
                label: SchedulingSettingsWriteCopy.logoLabel,
                publishedUrl: model.logoUrl,
                state: model.logoState,
                pickIdentifier: A11yID.SchedulingWritesB.brandingLogoPick,
                removeIdentifier: A11yID.SchedulingWritesB.brandingLogoRemove,
                onPicked: { bytes, mimeType in
                    Task { await model.upload(bytes: bytes, mimeType: mimeType, target: .logo) }
                },
                onRemove: { Task { await model.removeImage(.logo) } },
                onUnreadable: { model.reportUnreadable(.logo) }
            )
            SchedulingWritesBImageRow(
                label: SchedulingSettingsWriteCopy.bannerLabel,
                publishedUrl: model.bannerUrl,
                state: model.bannerState,
                pickIdentifier: A11yID.SchedulingWritesB.brandingBannerPick,
                removeIdentifier: A11yID.SchedulingWritesB.brandingBannerRemove,
                onPicked: { bytes, mimeType in
                    Task { await model.upload(bytes: bytes, mimeType: mimeType, target: .banner) }
                },
                onRemove: { Task { await model.removeImage(.banner) } },
                onUnreadable: { model.reportUnreadable(.banner) }
            )
        }
    }
}
