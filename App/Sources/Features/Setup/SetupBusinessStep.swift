import SwiftUI

/// Step 1, "Find your business". See ``SetupBusinessModel``.
struct SetupBusinessStep: View {
    @State private var model: SetupBusinessModel
    private let baseURL: URL
    private let open: (URL) -> Void

    init(
        wizard: SetupWizardModel,
        container: AppContainer,
        open: @escaping (URL) -> Void,
        onRenamed: @escaping () -> Void
    ) {
        _model = State(initialValue: SetupBusinessModel(
            wizard: wizard,
            workspaces: container.workspaces,
            onRenamed: onRenamed
        ))
        baseURL = container.baseURL
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            website
            details
            email
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Setup.step("business"))
    }

    private var website: some View {
        SettingsCard(eyebrow: SetupCopy.businessWebsiteHeading) {
            SetupNote(text: SetupCopy.businessWebsiteLead)
            SetupField(
                label: SetupCopy.businessWebsiteLabel,
                text: $model.websiteUrl,
                placeholder: SetupCopy.businessWebsitePlaceholder,
                keyboard: .URL,
                content: .URL,
                identifier: A11yID.Setup.Business.website
            )
            Button(model.isReading ? SetupCopy.businessReading : SetupCopy.businessReadWebsite) {
                Task { await model.readWebsite() }
            }
            .buttonStyle(.districtSecondary)
            .disabled(model.isReading || model.websiteUrl.trimmed.isEmpty)
            .accessibilityIdentifier(A11yID.Setup.Business.readWebsite)
            notice
        }
    }

    @ViewBuilder
    private var notice: some View {
        switch model.notice {
        case let .found(text):
            SetupNote(text: text).accessibilityIdentifier(A11yID.Setup.Business.notice)
        case .nothing:
            SetupNote(text: SetupCopy.businessReadNothing).accessibilityIdentifier(A11yID.Setup.Business.notice)
        case let .failed(text):
            SetupErrorLine(text: text).accessibilityIdentifier(A11yID.Setup.Business.notice)
        case nil:
            EmptyView()
        }
    }

    private var details: some View {
        SettingsCard(eyebrow: SetupCopy.businessDetailsHeading) {
            SetupField(
                label: SetupCopy.businessNameLabel,
                text: $model.businessName,
                error: model.showErrors ? model.nameError : nil,
                content: .organizationName,
                identifier: A11yID.Setup.Business.name
            )
            SetupField(
                label: SetupCopy.businessWhatLabel,
                text: $model.what,
                placeholder: SetupCopy.businessWhatPlaceholder,
                identifier: A11yID.Setup.Business.what
            )
            place
            SetupField(
                label: SetupCopy.businessStreetLabel,
                text: $model.street,
                hint: SetupCopy.businessStreetHint,
                content: .streetAddressLine1,
                identifier: A11yID.Setup.Business.street
            )
            language
            timezone
            if let error = model.saveError {
                SetupErrorLine(text: error.message)
            }
            SetupPrimaryButton(
                title: SetupCopy.saveAndContinue,
                busy: model.isSaving,
                identifier: A11yID.Setup.Business.save
            ) {
                Task { await model.save() }
            }
        }
    }

    @ViewBuilder
    private var place: some View {
        SetupPicker(
            label: SetupCopy.businessCountryLabel,
            placeholder: SetupCopy.businessCountryPlaceholder,
            selection: model.country,
            options: SetupPlaces.countries.map { ($0, SetupPlaces.countryName($0)) },
            error: model.showErrors ? model.countryError : nil,
            identifier: A11yID.Setup.Business.country,
            choose: { model.choose(country: $0) }
        )
        if let list = model.subdivisions {
            SetupPicker(
                label: model.country == "CA" ? SetupCopy.businessSubdivisionLabelCa : SetupCopy
                    .businessSubdivisionLabelUs,
                placeholder: SetupCopy.businessSubdivisionPlaceholder,
                selection: model.subdivision,
                options: list.map { ($0.code, $0.name) },
                error: model.showErrors ? model.subdivisionError : nil,
                identifier: A11yID.Setup.Business.subdivision,
                choose: { model.subdivision = $0 }
            )
        } else if !model.country.isEmpty {
            SetupField(
                label: SetupCopy.businessSubdivisionLabelOther,
                text: $model.subdivision,
                identifier: A11yID.Setup.Business.subdivision
            )
        }
        SetupField(
            label: SetupCopy.businessCityLabel,
            text: $model.city,
            error: model.showErrors ? model.cityError : nil,
            content: .addressCity,
            identifier: A11yID.Setup.Business.city
        )
    }

    private var language: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            DistrictEyebrow(text: SetupCopy.businessLanguageLabel)
                .accessibilityAddTraits(.isHeader)
            ForEach(SetupLanguage.allCases, id: \.self) { language in
                SetupChoiceRow(
                    title: language == .fr ? SetupCopy.businessLanguageFr : SetupCopy.businessLanguageEn,
                    selected: model.language == language,
                    identifier: A11yID.Setup.choice("language", language.rawValue),
                    action: { model.language = language }
                )
            }
        }
    }

    private var timezone: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            DistrictEyebrow(text: SetupCopy.businessTimezoneLabel)
            SetupNote(text: zoneSentence)
        }
        .accessibilityElement(children: .combine)
    }

    private var zoneSentence: String {
        guard let zone = model.zone else { return SetupCopy.businessTimezoneUnknown }
        return zone.multiZone ? SetupCopy.businessTimezoneMulti(zone.timezone)
            : SetupCopy.businessTimezoneValue(zone.timezone)
    }

    private var email: some View {
        SettingsCard(eyebrow: SetupCopy.businessEmailHeading) {
            SetupNote(text: SetupCopy.businessEmailBody)
            SetupHandOffButton(
                title: SetupCopy.openSkills,
                page: .skills,
                baseURL: baseURL,
                identifier: A11yID.Setup.Business.openSkills,
                open: open
            )
        }
    }
}

/// A labelled menu of choices, with a placeholder while nothing is chosen.
///
/// ⚠️ A `Menu`, NOT A `Picker(.menu)`: a picker with no selection shows nothing at all, and an
/// owner who has not chosen a country yet needs the placeholder to know there is a choice.
struct SetupPicker: View {
    let label: String
    let placeholder: String
    let selection: String
    let options: [(value: String, title: String)]
    var error: String?
    let identifier: String
    let choose: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var shown: String? {
        options.first { $0.value == selection }?.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
                .accessibilityHidden(true)
            Menu {
                ForEach(options, id: \.value) { option in
                    Button(option.title) { choose(option.value) }
                }
            } label: {
                HStack {
                    Text(shown ?? placeholder)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(shown == nil ? colors.mutedForeground : colors.foreground)
                    Spacer(minLength: DistrictSpacing.tight)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(DistrictType.label)
                        .foregroundStyle(colors.mutedForeground)
                        .accessibilityHidden(true)
                }
                .padding(DistrictSpacing.tight)
                .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: DistrictRadius.control)
                        .strokeBorder(colors.fieldEdge, lineWidth: 1)
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(shown ?? placeholder)
            .accessibilityHint(error ?? "")
            .accessibilityIdentifier(identifier)
            if let error {
                SetupErrorLine(text: error)
                    .accessibilityHidden(true)
            }
        }
    }
}
