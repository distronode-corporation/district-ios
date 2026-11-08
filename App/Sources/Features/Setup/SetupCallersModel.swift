import DistrictData
import DistrictModel
import Foundation
import Observation

/// Step 4, "What callers should know": the time zone, the address, the opening hours, the
/// services and the common questions the receptionist answers from.
///
/// ⛔ A DRAFTED ITEM ARRIVES SWITCHED OFF AND STAYS OFF UNTIL THE OWNER SWITCHES IT ON (the
/// website read produces drafts, never facts; only enabled items reach the agent). An item
/// the owner adds by hand starts on, because typing one is the confirmation.
///
/// ⛔ HOURS FROM THE WEBSITE ARE A DRAFT UNTIL THE OWNER USES THEM. "Fill from my website"
/// puts the lookup's hours on screen only; a save leaves `weeklyHours` out while that draft
/// is unconfirmed, and Continue refuses to move on past it rather than drop it silently.
/// "Use these hours", or editing any day, confirms it; "Discard" puts back what was there.
///
/// ⚠️ SAVED ON SAVE AND ON CONTINUE, NOT ON EVERY KEYSTROKE as the web's autosave does. Every
/// section present replaces the stored one whole, so each save sends all five, and an
/// empty section is sent as null (a clear).
@MainActor
@Observable
final class SetupCallersModel {
    var timezone: String
    var address: SetupAddressDraft
    var hours: [SetupWeekday: SetupDayDraft] {
        didSet {
            if hoursDraftPending, !applyingDraft {
                hoursDraftPending = false
            }
        }
    }

    var services: [SetupServiceDraft]
    var faqs: [SetupFaqDraft]
    var websiteUrl = ""

    private(set) var hoursDraftPending = false
    private(set) var hoursNotice: String?
    private(set) var isReading = false
    private(set) var isSaving = false
    private(set) var saved = false
    private(set) var showErrors = false
    private(set) var saveError: String?

    private var hoursBeforeDraft: [SetupWeekday: SetupDayDraft] = [:]
    private var applyingDraft = false
    private let wizard: SetupWizardModel

    init(wizard: SetupWizardModel) {
        self.wizard = wizard
        let facts = wizard.data?.businessFacts
        timezone = facts?["timezone"]?.stringValue ?? ""
        address = SetupFacts.address(facts)
        hours = SetupFacts.hours(facts?["weeklyHours"])
        services = SetupFacts.services(facts)
        faqs = SetupFacts.faqs(facts)
    }

    /// The zones this business's country offers, with the stored one.
    var zones: [String] {
        let country = address.country.isEmpty ? wizard.draft.country : address.country.uppercased()
        return SetupPlaces.zones(country: country, including: timezone)
    }

    var hasDrafts: Bool {
        services.contains { !$0.enabled } || faqs.contains { !$0.enabled }
    }

    var isValid: Bool {
        SetupFacts.isValid(address)
            && hours.values.allSatisfy(SetupFacts.isValid)
            && services.allSatisfy(SetupFacts.isValid)
            && faqs.allSatisfy(SetupFacts.isValid)
    }

    // MARK: - Editing

    func setState(_ state: SetupDayState, for day: SetupWeekday) {
        var draft = hours[day] ?? SetupDayDraft(state: .notSet, intervals: [])
        draft.state = state
        if state == .open, draft.intervals.isEmpty {
            draft.intervals = [SetupInterval.standard]
        }
        hours[day] = draft
    }

    func addPeriod(to day: SetupWeekday) {
        guard var draft = hours[day], draft.intervals.count < SetupFacts.Limit.intervalsPerDay else { return }
        let start = min((draft.intervals.map(\.close).max() ?? 9 * 60) + 60, 23 * 60)
        draft.intervals.append(SetupInterval(open: start, close: min(start + 60, 24 * 60)))
        hours[day] = draft
    }

    func removePeriod(_ id: UUID, from day: SetupWeekday) {
        guard var draft = hours[day] else { return }
        draft.intervals.removeAll { $0.id == id }
        if draft.intervals.isEmpty {
            draft.state = .notSet
        }
        hours[day] = draft
    }

    func addService() {
        guard services.count < SetupFacts.Limit.services else { return }
        services.append(SetupServiceDraft(name: "", price: "", enabled: true))
    }

    func addFaq() {
        guard faqs.count < SetupFacts.Limit.faqs else { return }
        faqs.append(SetupFaqDraft(question: "", answer: "", enabled: true))
    }

    // MARK: - Hours from the website

    func fillHoursFromWebsite() async {
        let url = websiteUrl.trimmed
        guard !isReading, !url.isEmpty else { return }
        isReading = true
        defer { isReading = false }
        hoursNotice = nil
        let locale = AppL10n.copyLocale == .frCA ? "fr" : "en"
        switch await wizard.repository.lookUp(workspaceId: wizard.workspaceId, websiteUrl: url, locale: locale) {
        case let .success(response):
            guard let found = response.draft.weeklyHours, !(found.objectValue?.isEmpty ?? true) else {
                hoursNotice = SetupCopy.callersNoHoursFound
                return
            }
            if !hoursDraftPending {
                hoursBeforeDraft = hours
            }
            applyingDraft = true
            hours = SetupFacts.hours(found)
            applyingDraft = false
            hoursDraftPending = true
        case let .failure(error):
            hoursNotice = FailureText.from(error).message
        }
    }

    func useDraftHours() {
        hoursDraftPending = false
    }

    func discardDraftHours() {
        guard hoursDraftPending else { return }
        applyingDraft = true
        hours = hoursBeforeDraft
        applyingDraft = false
        hoursDraftPending = false
    }

    // MARK: - Saving

    /// Every section, whole; `weeklyHours` left out while the website's hours are unconfirmed.
    func patch() -> WireJSON {
        var patch: [String: WireJSON] = [
            "address": SetupFacts.json(address: address),
            "services": SetupFacts.json(services: services),
            "faqs": SetupFacts.json(faqs: faqs),
        ]
        if !timezone.isEmpty {
            patch["timezone"] = .string(timezone)
        }
        if !hoursDraftPending {
            patch["weeklyHours"] = SetupFacts.json(hours: hours)
        }
        return .object(patch)
    }

    /// True when the facts are saved.
    @discardableResult
    func save() async -> Bool {
        showErrors = true
        saved = false
        guard !isSaving else { return false }
        guard isValid else {
            saveError = SetupCopy.callersFixErrors
            return false
        }
        isSaving = true
        wizard.beginStepWrite()
        defer {
            isSaving = false
            wizard.endStepWrite()
        }
        saveError = nil
        switch await wizard.repository.save(workspaceId: wizard.workspaceId, businessFacts: patch()) {
        case let .success(response):
            wizard.adopt(response)
            saved = true
            return true
        case let .failure(error):
            saveError = FailureText.from(error).message
            return false
        }
    }

    func saveAndContinue() async {
        guard !hoursDraftPending else {
            showErrors = true
            saveError = SetupCopy.callersConfirmHoursFirst
            return
        }
        // ⚠️ HELD ACROSS BOTH, so no move lands between the save and its completion.
        wizard.beginStepWrite()
        defer { wizard.endStepWrite() }
        guard await save() else { return }
        await wizard.complete(.callers, as: .done)
    }
}
