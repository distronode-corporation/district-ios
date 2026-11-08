import SwiftUI

/// Step 4, "What callers should know". See ``SetupCallersModel``.
struct SetupCallersStep: View {
    @State private var model: SetupCallersModel

    init(wizard: SetupWizardModel) {
        _model = State(initialValue: SetupCallersModel(wizard: wizard))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            SetupNote(text: SetupCopy.callersIntro)
            if model.hasDrafts {
                SetupNote(text: SetupCopy.callersDraftNote)
            }
            timezoneCard
            SetupHoursCard(model: model)
            addressCard
            SetupServicesCard(model: model)
            SetupFaqsCard(model: model)
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Setup.step("callers"))
    }

    private var timezoneCard: some View {
        SettingsCard {
            SetupPicker(
                label: SetupCopy.businessTimezoneLabel,
                placeholder: SetupCopy.callersTimezonePlaceholder,
                selection: model.timezone,
                options: model.zones.map { ($0, $0) },
                identifier: A11yID.Setup.Callers.timezone,
                choose: { model.timezone = $0 }
            )
            SetupNote(text: SetupCopy.callersTimezoneDescription, font: DistrictType.caption)
        }
    }

    private var addressCard: some View {
        SettingsCard(eyebrow: SetupCopy.callersAddressHeader) {
            SetupField(label: SetupCopy.businessStreetLabel, text: $model.address.line1, content: .streetAddressLine1)
            SetupField(label: SetupCopy.businessCityLabel, text: $model.address.city, content: .addressCity)
            SetupField(label: SetupCopy.callersAddressRegion, text: $model.address.region, content: .addressState)
            SetupField(label: SetupCopy.callersAddressPostal, text: $model.address.postalCode, content: .postalCode)
            SetupField(
                label: SetupCopy.callersAddressCountry,
                text: $model.address.country,
                hint: SetupCopy.callersAddressCountryHint,
                error: model.showErrors && !SetupFacts.isValid(model.address) ? SetupCopy
                    .callersAddressIncomplete : nil,
                keyboard: .asciiCapable
            )
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            if let error = model.saveError {
                SetupErrorLine(text: error)
            } else if model.saved {
                SetupNote(text: SetupCopy.saved)
            }
            HStack(spacing: DistrictSpacing.tight) {
                Button(SetupCopy.save) { Task { await model.save() } }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.isSaving)
                    .accessibilityIdentifier(A11yID.Setup.Callers.save)
                SetupPrimaryButton(
                    title: SetupCopy.saveAndContinue,
                    busy: model.isSaving,
                    identifier: A11yID.Setup.Callers.saveAndContinue
                ) {
                    Task { await model.saveAndContinue() }
                }
            }
        }
    }
}

/// The week, one row per day: Not set, Closed or Open with up to four periods.
struct SetupHoursCard: View {
    @Bindable var model: SetupCallersModel

    var body: some View {
        SettingsCard(eyebrow: SetupCopy.callersHoursHeader) {
            SetupNote(text: SetupCopy.callersHoursDescription, font: DistrictType.caption)
            fromWebsite
            ForEach(SetupWeekday.allCases) { day in
                dayRow(day)
                if day != .sun {
                    DistrictRowDivider()
                }
            }
        }
    }

    @ViewBuilder
    private var fromWebsite: some View {
        if model.hoursDraftPending {
            SetupNote(text: SetupCopy.callersHoursDraftNote)
            HStack(spacing: DistrictSpacing.tight) {
                Button(SetupCopy.callersUseHours) { model.useDraftHours() }
                    .buttonStyle(.districtPrimary)
                    .accessibilityIdentifier(A11yID.Setup.Callers.useHours)
                Button(SetupCopy.callersDiscardHours) { model.discardDraftHours() }
                    .buttonStyle(.districtSecondary)
                    .accessibilityIdentifier(A11yID.Setup.Callers.discardHours)
            }
        } else {
            SetupField(
                label: SetupCopy.businessWebsiteLabel,
                text: $model.websiteUrl,
                placeholder: SetupCopy.businessWebsitePlaceholder,
                keyboard: .URL,
                content: .URL,
                identifier: A11yID.Setup.Callers.website
            )
            Button(model.isReading ? SetupCopy.businessReading : SetupCopy.callersFillFromWebsite) {
                Task { await model.fillHoursFromWebsite() }
            }
            .buttonStyle(.districtSecondary)
            .disabled(model.isReading || model.websiteUrl.trimmed.isEmpty)
            .accessibilityIdentifier(A11yID.Setup.Callers.fill)
        }
        if let notice = model.hoursNotice {
            SetupNote(text: notice, font: DistrictType.caption)
        }
    }

    private func dayRow(_ day: SetupWeekday) -> some View {
        let draft = model.hours[day] ?? SetupDayDraft(state: .notSet, intervals: [])
        return VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            SetupPicker(
                label: day.name,
                placeholder: SetupCopy.callersDayNotSet,
                selection: Self.key(draft.state),
                options: SetupDayState.allCases.map { (Self.key($0), Self.label($0)) },
                identifier: A11yID.Setup.Callers.day(day.rawValue),
                choose: { key in model.setState(Self.state(key), for: day) }
            )
            if draft.state == .open {
                ForEach(Array(draft.intervals.enumerated()), id: \.element.id) { index, interval in
                    periodRow(day: day, index: index, interval: interval, removable: draft.intervals.count > 1)
                }
                if !SetupFacts.isValid(draft) {
                    SetupErrorLine(text: SetupCopy.callersPeriodError)
                }
                if draft.intervals.count < SetupFacts.Limit.intervalsPerDay {
                    Button(SetupCopy.callersAddPeriod) { model.addPeriod(to: day) }
                        .buttonStyle(.districtGhost)
                }
            }
        }
    }

    private func periodRow(day: SetupWeekday, index: Int, interval: SetupInterval, removable: Bool) -> some View {
        HStack(alignment: .bottom, spacing: DistrictSpacing.tight) {
            SetupPicker(
                label: SetupCopy.callersOpens,
                placeholder: SetupInterval.text(interval.open),
                selection: SetupInterval.text(interval.open),
                options: Self.times(including: interval.open, allowMidnight: false),
                identifier: A11yID.Setup.Callers.day(day.rawValue) + "-open-\(index)",
                choose: { text in update(day, interval.id) { $0.open = SetupInterval.minutes(text) ?? $0.open } }
            )
            SetupPicker(
                label: SetupCopy.callersCloses,
                placeholder: SetupInterval.text(interval.close),
                selection: SetupInterval.text(interval.close),
                options: Self.times(including: interval.close, allowMidnight: true),
                identifier: A11yID.Setup.Callers.day(day.rawValue) + "-close-\(index)",
                choose: { text in update(day, interval.id) { $0.close = SetupInterval.minutes(text) ?? $0.close } }
            )
            if removable {
                Button {
                    model.removePeriod(interval.id, from: day)
                } label: {
                    Image(systemName: "minus.circle")
                        .accessibilityLabel(SetupCopy.callersRemovePeriod)
                }
                .buttonStyle(.districtGhost)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.name + ", " + SetupCopy.callersPeriodLabel(index + 1))
    }

    private func update(_ day: SetupWeekday, _ id: UUID, _ change: (inout SetupInterval) -> Void) {
        guard var draft = model.hours[day], let index = draft.intervals.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&draft.intervals[index])
        model.hours[day] = draft
    }

    /// Every half hour, plus the stored value when it falls between, plus "24:00" for a close.
    static func times(including stored: Int, allowMidnight: Bool) -> [(value: String, title: String)] {
        var minutes = Array(stride(from: 0, to: 24 * 60, by: 30))
        if allowMidnight {
            minutes.append(24 * 60)
        }
        if !minutes.contains(stored) {
            minutes.append(stored)
        }
        return minutes.sorted().map { (SetupInterval.text($0), SetupInterval.text($0)) }
    }

    private static func key(_ state: SetupDayState) -> String {
        switch state {
        case .notSet: "unset"
        case .closed: "closed"
        case .open: "open"
        }
    }

    private static func state(_ key: String) -> SetupDayState {
        switch key {
        case "closed": .closed
        case "open": .open
        default: .notSet
        }
    }

    private static func label(_ state: SetupDayState) -> String {
        switch state {
        case .notSet: SetupCopy.callersDayNotSet
        case .closed: SetupCopy.callersDayClosed
        case .open: SetupCopy.callersDayOpen
        }
    }
}

/// The services, each with its "Use on calls" switch.
struct SetupServicesCard: View {
    @Bindable var model: SetupCallersModel

    var body: some View {
        SettingsCard(eyebrow: SetupCopy.callersServicesHeader) {
            SetupNote(text: SetupCopy.callersServicesDescription, font: DistrictType.caption)
            if model.services.isEmpty {
                SetupNote(text: SetupCopy.callersNoServices)
            }
            ForEach(Array($model.services.enumerated()), id: \.element.id) { index, $service in
                VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                    SetupField(
                        label: SetupCopy.callersServiceName,
                        text: $service.name,
                        error: model.showErrors && !SetupFacts.isValid(service) ? SetupCopy.callersServiceError : nil
                    )
                    SetupField(label: SetupCopy.callersServicePrice, text: $service.price)
                    SetupItemSwitch(isOn: $service.enabled) {
                        model.services.removeAll { $0.id == service.id }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(SetupCopy.callersServiceLabel(index + 1))
                DistrictRowDivider()
            }
            Button(SetupCopy.callersAddService) { model.addService() }
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.Setup.Callers.addService)
        }
    }
}

/// The common questions, each with its "Use on calls" switch.
struct SetupFaqsCard: View {
    @Bindable var model: SetupCallersModel

    var body: some View {
        SettingsCard(eyebrow: SetupCopy.callersFaqsHeader) {
            SetupNote(text: SetupCopy.callersFaqsDescription, font: DistrictType.caption)
            if model.faqs.isEmpty {
                SetupNote(text: SetupCopy.callersNoFaqs)
            }
            ForEach(Array($model.faqs.enumerated()), id: \.element.id) { index, $faq in
                VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                    SetupField(
                        label: SetupCopy.callersFaqQuestion,
                        text: $faq.question,
                        error: model.showErrors && !SetupFacts.isValid(faq) ? SetupCopy.callersFaqError : nil
                    )
                    SetupField(label: SetupCopy.callersFaqAnswer, text: $faq.answer, multiline: true)
                    SetupItemSwitch(isOn: $faq.enabled) {
                        model.faqs.removeAll { $0.id == faq.id }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(SetupCopy.callersFaqLabel(index + 1))
                DistrictRowDivider()
            }
            Button(SetupCopy.callersAddFaq) { model.addFaq() }
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.Setup.Callers.addFaq)
        }
    }
}

/// "Use on calls", the off hint, and Remove.
struct SetupItemSwitch: View {
    @Binding var isOn: Bool
    let remove: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack {
                Toggle(SetupCopy.callersUseOnCalls, isOn: $isOn)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(DistrictColors.resolve(colorScheme).foreground)
                Button(SetupCopy.callersRemove, action: remove)
                    .buttonStyle(.districtGhost)
            }
            if !isOn {
                SetupNote(text: SetupCopy.callersOffHint, font: DistrictType.caption)
            }
        }
    }
}
