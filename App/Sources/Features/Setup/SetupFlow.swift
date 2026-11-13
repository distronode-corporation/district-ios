import DistrictModel
import Foundation

/// The setup wizard's six steps in the web's order, and where a stored progress opens it.
///
/// ⛔ THE STEP STATES ARE THE SERVICE'S AND THIS MIRRORS THE WEB'S READING OF THEM
/// (`firstOpenStepIndex` in `SetupWizard.tsx`): the wizard opens on the first step still
/// `todo`, or on the first step when none is. A state this build does not know is NOT `todo`,
/// exactly as the web's `=== "todo"` reads it, so a fourth state added server-side cannot
/// send an owner back to a step they finished.
///
/// ⚠️ EVERY STEP SAVES AS IT GOES, SO "FINISH LATER" LOSES NOTHING THE STEP SAVED. A step
/// writes its own data and then marks itself `done`; Skip marks it `skipped`. The next open
/// resumes from what the service holds, on any device, the web included.
enum SetupFlow {
    static let steps = SetupStep.allCases

    static func firstOpen(_ progress: SetupProgress?) -> SetupStep {
        steps.first { progress?.steps?.state(of: $0) == .todo } ?? .business
    }

    static func next(after step: SetupStep) -> SetupStep? {
        let index = position(of: step)
        return index + 1 < steps.count ? steps[index + 1] : nil
    }

    static func previous(before step: SetupStep) -> SetupStep? {
        let index = position(of: step)
        return index > 0 ? steps[index - 1] : nil
    }

    /// Zero-based.
    static func position(of step: SetupStep) -> Int {
        steps.firstIndex(of: step) ?? 0
    }

    static func title(_ step: SetupStep) -> String {
        switch step {
        case .business: SetupCopy.businessTitle
        case .number: SetupCopy.numberTitle
        case .receptionist: SetupCopy.receptionistTitle
        case .callers: SetupCopy.callersTitle
        case .calls: SetupCopy.callsTitle
        case .golive: SetupCopy.goliveTitle
        }
    }

    static func description(_ step: SetupStep) -> String {
        switch step {
        case .business: SetupCopy.businessDescription
        case .number: SetupCopy.numberDescription
        case .receptionist: SetupCopy.receptionistDescription
        case .callers: SetupCopy.callersDescription
        case .calls: SetupCopy.callsDescription
        case .golive: SetupCopy.goliveDescription
        }
    }
}

/// Why the wizard is not run for this person, as opposed to a failure to reach it.
///
/// ⛔ OWNER ONLY, AND THE OWNER IS THE WORKSPACE'S `ownerId`, NOT A ROLE. Every `setup/*`
/// route answers a member or an admin with **403**, so a 403 here is the ordinary answer for
/// anyone else and is explained, never shown as an error with a retry. A workspace from
/// before the wizard answers **409** `setup_not_available`, and a 200 with no progress means
/// the same thing (``DistrictSetupResponse/setupProgress``).
enum SetupRefusal: Equatable {
    case notOwner
    case notAvailable

    static func from(_ error: ApiError) -> SetupRefusal? {
        switch error.httpStatus {
        case 403: .notOwner
        case 409 where error.code == "setup_not_available": .notAvailable
        default: nil
        }
    }
}

/// The language the receptionist speaks, as step 1 offers it.
enum SetupLanguage: String, Codable, CaseIterable {
    case en
    case fr

    /// "fr-CA" is French, "en-US" English, anything else nil (the web's `localeOfPersonaLanguage`).
    init?(personaLanguage: String?) {
        let lower = (personaLanguage ?? "").lowercased()
        if lower.hasPrefix("fr") {
            self = .fr
        } else if lower.hasPrefix("en") {
            self = .en
        } else {
            return nil
        }
    }

    /// The app's own language, for a workspace whose persona names none.
    static var appDefault: SetupLanguage {
        AppL10n.copyLocale == .frCA ? .fr : .en
    }

    /// The persona `language` this choice is saved as when nothing is stored.
    var personaDefault: String {
        self == .fr ? "fr-CA" : "en-US"
    }

    /// The persona `language` step 3 saves (the web's `personaLanguageToSave`).
    ///
    /// ⛔ A STORED LANGUAGE IS KEPT UNLESS THE OWNER CHOSE THE OTHER FAMILY: step 1 offers only
    /// English and French, so a receptionist set to German in settings must not come back as
    /// `en-US`. A stored language outside both families is kept when the owner left step 1 on
    /// the app's language, which is where it opened.
    static func toSave(stored: String?, chosen: SetupLanguage) -> String {
        let kept = (stored ?? "").trimmingCharacters(in: .whitespaces)
        if !kept.isEmpty {
            let family = SetupLanguage(personaLanguage: kept)
            if family == chosen || (family == nil && chosen == appDefault) {
                return kept
            }
        }
        return chosen.personaDefault
    }
}

/// What step 1 learned that steps 2 and 3 need before a read could give it back: the name,
/// the place, and the language (which only step 3 stores, in the persona).
///
/// ⚠️ KEPT ON THIS DEVICE PER WORKSPACE (``SetupDraftStore``), so the language chosen in step 1
/// survives "Finish later" and a relaunch until step 3 writes it, which the web keeps only in
/// memory.
struct SetupBusinessDraft: Codable, Equatable {
    var businessName: String
    /// ISO 3166-1 alpha-2, or "" when not chosen yet.
    var country: String
    var subdivision: String
    var city: String
    var language: SetupLanguage

    /// The web's `initialBusinessDraft`.
    static func initial(
        data: DistrictSetupResponse?,
        personaLanguage: String?,
        workspaceName: String
    ) -> SetupBusinessDraft {
        let address = data?.businessFacts?["address"]
        let country = address?["country"]?.stringValue ?? SetupPlaces.defaultCountry(region: data?.region)
        let stored = address?["region"]?.stringValue ?? ""
        let subdivision: String = if let list = SetupPlaces.subdivisions(country) {
            list.first { $0.code == stored.uppercased() }?.code ?? ""
        } else {
            stored
        }
        return SetupBusinessDraft(
            businessName: SetupWire.isDefaultWorkspaceName(workspaceName) ? "" : workspaceName,
            country: country,
            subdivision: subdivision,
            city: address?["city"]?.stringValue ?? "",
            language: SetupLanguage(personaLanguage: personaLanguage) ?? .appDefault
        )
    }
}

/// The step 1 draft, per workspace, on this device.
///
/// ⚠️ `UserDefaults`, NOT THE KEYCHAIN: a business name and a city are what the workspace
/// already shows every member, not a credential.
struct SetupDraftStore {
    let defaults: UserDefaults

    private static func key(_ workspaceId: String) -> String {
        "district.setup.draft.\(workspaceId)"
    }

    func load(workspaceId: String) -> SetupBusinessDraft? {
        guard let data = defaults.data(forKey: Self.key(workspaceId)) else { return nil }
        return try? JSONDecoder().decode(SetupBusinessDraft.self, from: data)
    }

    func save(_ draft: SetupBusinessDraft, workspaceId: String) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: Self.key(workspaceId))
    }

    func clear(workspaceId: String) {
        defaults.removeObject(forKey: Self.key(workspaceId))
    }
}

/// Values the wizard writes into the business's own data, which are therefore chosen by the
/// RECEPTIONIST'S language rather than the app's and are not in the catalog.
///
/// ⛔ THEY MATCH THE WEB'S BYTE FOR BYTE, because the web reads them back: step 1's question is
/// how either client finds the "what you do" answer it wrote, and the starter greetings are
/// how both tell an untouched greeting from the owner's own (`isStarterGreeting`).
enum SetupWire {
    /// `setupCopy[language].business.whatQuestion`.
    static func whatQuestion(_ language: SetupLanguage) -> String {
        language == .fr ? "Que fait l'entreprise?" : "What does the business do?"
    }

    static let whatQuestions: Set<String> = Set(SetupLanguage.allCases.map(whatQuestion))

    /// `STARTER_PERSONA_NAME`, for a persona that holds no name.
    static let fallbackName = "Ava"

    /// `starterGreeting(locale)` in `first-run-defaults.ts`, both languages.
    static let starterGreetings: Set<String> = [
        "Thanks for calling. This is Ava. How can I help you today?",
        "Merci de votre appel. Ici Ava. Comment puis-je vous aider aujourd'hui?",
    ]

    /// `setupCopy[language].receptionist.greeting` and `greetingNoBusiness`.
    static func greeting(business: String, name: String, language: SetupLanguage) -> String {
        let business = business.trimmingCharacters(in: .whitespaces)
        switch (language, business.isEmpty) {
        case (.fr, false): return "Merci d'avoir appelé \(business), ici \(name). Comment puis-je vous aider?"
        case (.fr, true): return "Merci d'avoir appelé, ici \(name). Comment puis-je vous aider?"
        case (.en, false): return "Thanks for calling \(business), this is \(name). How can I help?"
        case (.en, true): return "Thanks for calling, this is \(name). How can I help?"
        }
    }

    /// The name a workspace is provisioned with when its buyer gave no business name.
    static func isDefaultWorkspaceName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).hasSuffix("'s Communications Workspace")
    }

    /// The web's `toE164`: an E.164 number, or a ten- or eleven-digit North American one in
    /// a `us` or `ca` workspace; nil for anything else.
    static func e164(_ raw: String, region: String?) -> String? {
        let compact = raw.filter { !" ().-".contains($0) }
        if compact.range(of: #"^\+[0-9]{8,15}$"#, options: .regularExpression) != nil {
            return compact
        }
        guard region == "us" || region == "ca" else { return nil }
        if compact.range(of: #"^[2-9][0-9]{9}$"#, options: .regularExpression) != nil {
            return "+1" + compact
        }
        if compact.range(of: #"^1[2-9][0-9]{9}$"#, options: .regularExpression) != nil {
            return "+" + compact
        }
        return nil
    }
}
