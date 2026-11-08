import DistrictData
import DistrictModel
import Foundation
import Observation

/// Step 1, "Find your business": the website read, then who the business is and where.
///
/// ⛔ "READ MY WEBSITE" SAVES DRAFTS, NEVER LIVE FACTS (the web's `Step1Business`). The lookup
/// writes nothing; this appends what it found to the stored services and questions with every
/// one `enabled: false` exactly as the service drafted it, so nothing reaches a caller until
/// the owner switches it on in step 4. ⛔ DRAFTED HOURS ARE NOT SAVED AT ALL: a day has no
/// `enabled` flag, so stored hours are live. The step says hours were found and step 4 reads
/// them again.
///
/// ⛔ THE BUSINESS NAME IS THE WORKSPACE NAME, renamed through the existing route and only
/// when it changed. There is no name in business facts.
///
/// ⚠️ THE LANGUAGE IS NOT SAVED HERE. It goes into the shell's draft and step 3 writes it into
/// the persona, the one step that owns the persona.
///
/// ⚠️ "WHAT YOU DO" IS STORED AS ONE ENABLED QUESTION in the receptionist's language
/// (``SetupWire/whatQuestion(_:)``), because the facts have no description field and a
/// question is how a caller asks for it.
///
/// ⚠️ THE EMAIL SENDER NAME AND REPLY-TO ARE NOT HERE: DistrictCore 8.5.0 has no mobile
/// contract for the email identity, so the step opens the Skills page for them.
///
/// ⛔ THE READ AND THE SAVE NEVER OVERLAP. Each builds its `faqs` from the stored ones, and the
/// service replaces a section whole, so whichever answered second would drop the other's
/// questions (the drafts, or "what you do"). ``isBusy`` keeps both buttons off while either runs.
@MainActor
@Observable
final class SetupBusinessModel {
    enum Notice: Equatable {
        case found(String)
        case nothing
        case failed(String)
    }

    var websiteUrl = ""
    var businessName: String
    var what: String
    var country: String
    var subdivision: String
    var city: String
    var street: String
    var language: SetupLanguage

    private(set) var notice: Notice?
    private(set) var isReading = false
    private(set) var isSaving = false
    private(set) var showErrors = false
    private(set) var saveError: FailureText?

    /// The website read or the save in flight; see the type's header.
    var isBusy: Bool {
        isReading || isSaving
    }

    private let wizard: SetupWizardModel
    private let workspaces: WorkspaceRepository
    private let onRenamed: () -> Void

    init(wizard: SetupWizardModel, workspaces: WorkspaceRepository, onRenamed: @escaping () -> Void = {}) {
        self.wizard = wizard
        self.workspaces = workspaces
        self.onRenamed = onRenamed
        let draft = wizard.draft
        let facts = wizard.data?.businessFacts
        businessName = draft.businessName
        what = SetupFacts.what(facts)
        country = draft.country
        subdivision = draft.subdivision
        city = draft.city
        street = facts?["address"]?["line1"]?.stringValue ?? ""
        language = draft.language
    }

    var subdivisions: [SetupPlaces.Subdivision]? {
        SetupPlaces.subdivisions(country)
    }

    var zone: SetupPlaces.Zone? {
        country.isEmpty ? nil : SetupPlaces.zone(country: country, subdivision: subdivision)
    }

    /// A country change drops the province or state, which belonged to the old one.
    func choose(country next: String) {
        guard next != country else { return }
        country = next
        subdivision = ""
    }

    // MARK: - Checking

    var nameError: String? {
        businessName.trimmed.isEmpty ? SetupCopy.businessNameRequired : nil
    }

    var countryError: String? {
        country.isEmpty ? SetupCopy.businessCountryRequired : nil
    }

    var subdivisionError: String? {
        subdivisions != nil && subdivision.isEmpty ? SetupCopy.businessSubdivisionRequired : nil
    }

    var cityError: String? {
        city.trimmed.isEmpty ? SetupCopy.businessCityRequired : nil
    }

    var isValid: Bool {
        [nameError, countryError, subdivisionError, cityError].allSatisfy { $0 == nil }
    }

    // MARK: - The website read

    func readWebsite() async {
        let url = websiteUrl.trimmed
        guard !isBusy, !url.isEmpty else { return }
        isReading = true
        wizard.beginStepWrite()
        defer {
            isReading = false
            wizard.endStepWrite()
        }
        notice = nil
        let locale = AppL10n.copyLocale == .frCA ? "fr" : "en"
        switch await wizard.repository.lookUp(workspaceId: wizard.workspaceId, websiteUrl: url, locale: locale) {
        case let .success(response):
            await adoptLookup(response.draft)
        case let .failure(error):
            notice = .failed(FailureText.from(error).message)
        }
    }

    private func adoptLookup(_ found: SetupLookupDraft) async {
        let hoursFound = !(found.weeklyHours?.objectValue?.isEmpty ?? true)
        guard !found.services.isEmpty || !found.faqs.isEmpty || hoursFound || found.address != nil else {
            notice = .nothing
            return
        }
        fillAddress(found.address)
        let facts = wizard.data?.businessFacts
        var patch: [String: WireJSON] = [:]
        if !found.services.isEmpty {
            patch["services"] = .array(SetupFacts.appending(
                found.services.map(Self.row),
                to: facts?["services"]?.arrayValue ?? [],
                key: "name",
                max: SetupFacts.Limit.services
            ))
        }
        if !found.faqs.isEmpty {
            patch["faqs"] = .array(SetupFacts.appending(
                found.faqs.map(Self.row),
                to: facts?["faqs"]?.arrayValue ?? [],
                key: "question",
                max: SetupFacts.Limit.faqs
            ))
        }
        // ⛔ NO HOURS, EVER, from here: see the type's header.
        if !patch.isEmpty {
            switch await wizard.repository.save(workspaceId: wizard.workspaceId, businessFacts: .object(patch)) {
            case let .success(response):
                wizard.adopt(response)
            case let .failure(error):
                notice = .failed(FailureText.from(error).message)
                return
            }
        }
        notice = .found(Self.foundSentence(
            services: found.services.count,
            faqs: found.faqs.count,
            hours: hoursFound,
            address: found.address != nil
        ))
    }

    /// The draft's address fills EMPTY fields only; the owner confirms it by saving the step.
    private func fillAddress(_ address: WireJSON?) {
        guard let address else { return }
        if street.trimmed.isEmpty, let line1 = address["line1"]?.stringValue {
            street = line1
        }
        if city.trimmed.isEmpty, let found = address["city"]?.stringValue {
            city = found
        }
        let foundCountry = address["country"]?.stringValue ?? ""
        let foundRegion = (address["region"]?.stringValue ?? "").uppercased()
        if country.isEmpty, SetupPlaces.countries.contains(foundCountry) {
            country = foundCountry
            subdivision = Self.subdivision(foundRegion, in: foundCountry)
        } else if subdivision.isEmpty, foundCountry == country {
            subdivision = Self.subdivision(foundRegion, in: country)
        }
    }

    private static func subdivision(_ code: String, in country: String) -> String {
        guard let list = SetupPlaces.subdivisions(country) else { return code }
        return list.first { $0.code == code }?.code ?? ""
    }

    private static func row(_ service: SetupDraftService) -> WireJSON {
        var row: [String: WireJSON] = ["name": .string(service.name), "enabled": .bool(service.enabled)]
        if let price = service.price {
            row["price"] = .string(price)
        }
        return .object(row)
    }

    private static func row(_ faq: SetupDraftFaq) -> WireJSON {
        .object(["question": .string(faq.question), "answer": .string(faq.answer), "enabled": .bool(faq.enabled)])
    }

    /// ⚠️ FRENCH TAKES THE SINGULAR FOR 0 AND 1, ENGLISH FOR 1 ONLY (the web's `<= 1` and `=== 1`).
    ///
    /// ⚠️ AN ADDRESS-ONLY ANSWER STILL SAYS SOMETHING: it filled the form, and an empty notice
    /// would leave the owner unsure the read did anything.
    static func foundSentence(services: Int, faqs: Int, hours: Bool, address: Bool = false) -> String {
        var parts: [String] = []
        if services > 0 || faqs > 0 {
            let singular = { (count: Int) in AppL10n.copyLocale == .frCA ? count <= 1 : count == 1 }
            parts.append(SetupCopy.businessReadResult(
                singular(services) ? SetupCopy.businessFoundServicesOne(services)
                    : SetupCopy.businessFoundServicesOther(services),
                singular(faqs) ? SetupCopy.businessFoundFaqsOne(faqs) : SetupCopy.businessFoundFaqsOther(faqs)
            ))
        }
        if hours {
            parts.append(SetupCopy.businessHoursFound)
        }
        if parts.isEmpty, address {
            parts.append(SetupCopy.businessAddressFound)
        }
        return parts.joined(separator: " ")
    }

    // MARK: - The save

    /// Saves the facts, renames the workspace when the name changed, keeps the draft, and
    /// marks the step done.
    func save() async {
        showErrors = true
        guard isValid, !isBusy else { return }
        isSaving = true
        wizard.beginStepWrite()
        defer {
            isSaving = false
            wizard.endStepWrite()
        }
        saveError = nil
        switch await wizard.repository.save(workspaceId: wizard.workspaceId, businessFacts: factsPatch()) {
        case let .success(response):
            wizard.adopt(response)
        case let .failure(error):
            saveError = FailureText.from(error)
            return
        }
        let name = businessName.trimmed
        if name != wizard.workspaceName.trimmed {
            switch await workspaces.rename(workspaceId: wizard.workspaceId, name: name) {
            case let .success(response):
                // ⛔ THE ECHO, NOT THE REQUEST: the service trims before it stores.
                wizard.renamed(to: response.name)
                onRenamed()
            case let .failure(error):
                saveError = FailureText.from(error)
                return
            }
        }
        wizard.updateDraft(SetupBusinessDraft(
            businessName: name,
            country: country,
            subdivision: subdivision.trimmed,
            city: city.trimmed,
            language: language
        ))
        await wizard.complete(.business, as: .done)
    }

    /// The address always (city and country are required), the street only when typed, the
    /// zone when the place implies one, and the "what you do" question in front of the rest.
    ///
    /// ⛔ THE STORED POSTAL CODE GOES BACK WITH THE ADDRESS. This step has no field for it, and
    /// the service replaces the section whole, so leaving it out would erase what step 4 (or
    /// the web) stored.
    func factsPatch() -> WireJSON {
        var patch: [String: WireJSON] = [:]
        if let zone {
            patch["timezone"] = .string(zone.timezone)
        }
        var address: [String: WireJSON] = ["city": .string(city.trimmed), "country": .string(country)]
        if !street.trimmed.isEmpty {
            address["line1"] = .string(street.trimmed)
        }
        if !subdivision.trimmed.isEmpty {
            address["region"] = .string(subdivision.trimmed)
        }
        let postalCode = SetupFacts.address(wizard.data?.businessFacts).postalCode.trimmed
        if !postalCode.isEmpty {
            address["postalCode"] = .string(postalCode)
        }
        patch["address"] = .object(address)
        let stored = wizard.data?.businessFacts?["faqs"]?.arrayValue ?? []
        let others = stored.filter { !SetupWire.whatQuestions.contains($0["question"]?.stringValue ?? "") }
        if !what.trimmed.isEmpty {
            let mine = WireJSON.object([
                "question": .string(SetupWire.whatQuestion(language)),
                "answer": .string(String(what.trimmed.prefix(SetupFacts.Limit.faqAnswer))),
                "enabled": .bool(true),
            ])
            patch["faqs"] = .array(Array(([mine] + others).prefix(SetupFacts.Limit.faqs)))
        } else if others.count != stored.count {
            patch["faqs"] = .array(others)
        }
        return .object(patch)
    }

    func dismissNotice() {
        notice = nil
    }
}
