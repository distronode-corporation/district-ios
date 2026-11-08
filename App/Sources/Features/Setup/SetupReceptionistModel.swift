import DistrictData
import DistrictModel
import Foundation
import Observation

/// Step 3, "Your receptionist": a name, a greeting and a voice, saved into the persona.
///
/// ⛔ ONLY WHAT THIS STEP OWNS IS SENT: name, greeting, language and (when offered) voice. The
/// persona route merges per field, so every other key is left as it is (the web's
/// `Step3Receptionist`, and the rule on ``WorkspaceRepository/savePersona``).
///
/// ⛔ THE VOICES COME FROM THE SERVICE'S OPTIONS FOR THE PERSONA'S OWN ENGINE AND LANGUAGE,
/// never from a list kept here: the persona route coerces rather than rejects, so a voice
/// typed by hand would be stored and then silently replaced. With no engine recorded, or no
/// voices for it, the step offers none and leaves the voice alone.
///
/// ⚠️ THE STARTER GREETING IS REPLACED BY THE BUSINESS'S OWN; A GREETING THE OWNER WROTE IS
/// KEPT. A greeting is the starter one when it is empty, one of the two provisioned starter
/// sentences (``SetupWire/starterGreetings``), or this step's own template for the stored name.
@MainActor
@Observable
final class SetupReceptionistModel {
    enum Phase {
        case loading
        case ready
        case failed(FailureText)
    }

    private(set) var phase: Phase = .loading
    var name = ""
    var greeting = "" {
        didSet {
            if greeting != oldValue, !applyingTemplate {
                greetingEdited = true
            }
        }
    }

    var voice: String?
    private(set) var greetingEdited = false
    private(set) var voiceGroups: [PersonaVoiceGroup] = []
    private(set) var showErrors = false
    private(set) var isSaving = false
    private(set) var saveError: FailureText?

    private var storedLanguage: String?
    private var applyingTemplate = false
    private let wizard: SetupWizardModel
    private let workspaces: WorkspaceRepository

    init(wizard: SetupWizardModel, workspaces: WorkspaceRepository) {
        self.wizard = wizard
        self.workspaces = workspaces
    }

    var language: SetupLanguage {
        wizard.draft.language
    }

    /// The persona `language` the save writes.
    var languageToSave: String {
        SetupLanguage.toSave(stored: storedLanguage, chosen: language)
    }

    /// Europe requires the disclosure, so the step says so; elsewhere it is a settings choice.
    var disclosureIsMandatory: Bool {
        wizard.region == "eu"
    }

    var nameError: String? {
        name.trimmed.isEmpty ? SetupCopy.receptionistNameRequired : nil
    }

    var greetingError: String? {
        greeting.trimmed.isEmpty ? SetupCopy.receptionistGreetingRequired : nil
    }

    // MARK: - Reading

    /// The stored persona and the options for its engine, read together.
    ///
    /// ⛔ A FAILED CONFIG READ IS A RETRY AND NO FORM: a form built from nothing would save the
    /// starter name over the owner's. A failed OPTIONS read only hides the voice picker.
    func load() async {
        phase = .loading
        // ⚠️ ONE AFTER ANOTHER, NOT `async let`: see ``SetupGoLiveModel/load()``.
        let configResult = await workspaces.config(workspaceId: wizard.workspaceId)
        let optionsResult = await workspaces.personaOptions(workspaceId: wizard.workspaceId)
        switch configResult {
        case let .success(config):
            adopt(config.aiPersona, options: try? optionsResult.get())
            phase = .ready
        case let .failure(error):
            phase = .failed(FailureText.from(error))
        }
    }

    private func adopt(_ persona: AiPersona?, options: PersonaOptionsResponse?) {
        storedLanguage = persona?.language
        let storedName = persona?.name?.trimmed ?? ""
        name = storedName.isEmpty ? SetupWire.fallbackName : storedName
        let stored = persona?.greeting?.trimmed ?? ""
        applyingTemplate = true
        if Self.isStarter(stored, name: name, business: wizard.draft.businessName) {
            greeting = template(for: name)
            greetingEdited = false
        } else {
            greeting = stored
            greetingEdited = true
        }
        applyingTemplate = false
        let engine = persona?.modelId
        voiceGroups = options?.voiceGroups(engine: engine, language: languageToSave) ?? []
        if options?.voiceExists(persona?.voice, engine: engine, language: languageToSave) == true {
            voice = persona?.voice
        } else {
            voice = options?.defaultVoice(engine: engine, language: languageToSave)
                ?? voiceGroups.first?.options.first?.value
        }
    }

    static func isStarter(_ greeting: String, name: String, business: String) -> Bool {
        if greeting.isEmpty || SetupWire.starterGreetings.contains(greeting) {
            return true
        }
        return SetupLanguage.allCases.contains { language in
            greeting == SetupWire.greeting(business: business, name: name, language: language)
                || greeting == SetupWire.greeting(business: "", name: name, language: language)
        }
    }

    func template(for name: String) -> String {
        let shown = name.trimmed.isEmpty ? SetupWire.fallbackName : name.trimmed
        return SetupWire.greeting(business: wizard.draft.businessName, name: shown, language: language)
    }

    /// A rename carries the untouched template with it; a greeting the owner wrote stays.
    func nameChanged() {
        guard !greetingEdited else { return }
        applyingTemplate = true
        greeting = template(for: name)
        applyingTemplate = false
    }

    // MARK: - The save

    func save() async {
        showErrors = true
        guard nameError == nil, greetingError == nil, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        let result = await workspaces.savePersona(
            workspaceId: wizard.workspaceId,
            name: name.trimmed,
            greeting: greeting.trimmed,
            voice: voiceGroups.isEmpty ? nil : voice,
            language: languageToSave
        )
        if case let .failure(error) = result {
            saveError = FailureText.from(error)
            return
        }
        storedLanguage = languageToSave
        await wizard.complete(.receptionist, as: .done)
    }
}
