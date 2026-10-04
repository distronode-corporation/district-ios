import Foundation

/// The persona form's language and answer length, the persona preview, and the
/// routing-rule editor. (The engine, voice and tuning are the Voice Studio's; see
/// ``VoiceStudioCopy``.)
///
/// ⚠️ A THIRD FILE FOR THE SAME NAMESPACE, WHICH IS A LINT CEILING RATHER THAN A
/// SPLIT WITH MEANING — `swiftlint --strict` promotes `file_length` at 500 lines to an
/// error, and `SettingsCopy.swift` is already the whole of the rest of this surface.
/// What is here is the copy for editing the persona and its rules.
///
/// ⛔ NO SENTENCE ON THIS SURFACE MAY SAY THE PHONE CANNOT DO THIS. "chosen from lists
/// this app cannot see", "They cannot be edited in this app" and "Rules cannot be added
/// in this app" would each be false; a stale refusal is worse than no sentence, because
/// an operator believes it and goes looking for a browser.
extension SettingsCopy {
    // MARK: - The language panel

    static let personaLanguageLabel = "Language"

    /// ⚠️ SAID WHEN NO LANGUAGE IS SET, which happens when one was never chosen, and is
    /// said rather than left as a blank picker.
    static let personaLanguageUnset = "No language is set for this persona. Choose one."

    static let personaAnswerLengthLabel = "Answer length"

    /// ⚠️ SAYS IT IS PER ENGINE, because it is stored per engine: an operator who changes
    /// the engine in Voice Studio and comes back finds that engine's own setting here, and
    /// without this sentence would read it as the form losing their edit.
    static let personaAnswerLengthNote = "How long each spoken reply may run. Saved separately for "
        + "each engine, so a different engine in Voice Studio keeps its own setting."

    // MARK: - When the catalogue did not load

    static let personaOptionsFailedEyebrow = "Could not read the lists this form chooses from"

    /// ⛔ THE REFUSAL IS EXPLAINED RATHER THAN PRESENTED AS A PRODUCT DECISION, AND IT
    /// IS THE ONE THING THAT MUST NOT BE "FIXED" WITH A BUILT-IN LIST. Every value a
    /// stale Swift catalogue offered would still be accepted and stored, and then
    /// silently replaced by the agent's own fallback at synthesis time — a 200, a
    /// persona nobody chose, and nothing anywhere reporting it.
    static let personaOptionsFailedNote = "The language and answer length are chosen from lists "
        + "this workspace's server publishes. Until those load, what is stored is shown as it is and "
        + "cannot be changed. The name, greeting and personality can still be edited and saved."

    // MARK: - The avatar row

    /// ⛔ A STATUS AND NEVER A CONTROL. Turning video on starts a billable Tavus stream,
    /// and App Store Review Guideline 3.1.3(b) plus the ⛔ on `AiPersona.videoEnabled`
    /// both point the same way: nothing in this app writes it.
    static let personaAvatarLabel = "Avatar"

    static let personaAvatarNote = "The avatar starts a charged video session, so it is shown here and "
        + "set up elsewhere."

    static let personaSave = "Save persona"

    // MARK: - The preview

    static let previewTitle = "Preview persona"

    /// ⛔ IT IS A REAL, BILLED CALL AND THE OPERATOR IS TOLD BEFORE THEY PRESS. The
    /// token invites the voice agent into a room on this workspace's own pipeline,
    /// where it answers with speech recognition, a model and speech synthesis exactly
    /// as it would on a telephone call. Nothing about it is a dry run.
    static let previewIntro = "Speak to the persona as it is on screen, before saving it. This places a "
        + "real call to the agent and is charged like one."

    static let previewStart = "Start preview"

    static let previewEnd = "End preview"

    static let previewConnecting = "Connecting to the agent…"

    static let previewWaiting = "Connected. Waiting for the agent to join…"

    static let previewLive = "The agent is listening. Say something."

    static let previewReconnecting = "The connection dropped and is being re-established."

    static let previewEnded = "Preview ended."

    /// ⚠️ A DISCONNECT NOBODY ASKED FOR IS NOT "ended", and the reason is shown when
    /// the server gave one.
    static let previewDropped = "The preview ended without being stopped here."

    static let previewLevelLabel = "Agent audio"

    /// ⚠️ SPOKEN AS A LEVEL RATHER THAN DRAWN AS ONE. A bar with no label is invisible
    /// to VoiceOver, and "is the agent actually saying anything" is the question this
    /// screen exists to answer.
    static func previewLevelValue(_ level: Double) -> String {
        "\(Int((level * 100).rounded())) percent"
    }

    /// ⛔ ONE TELEPHONE CALL OR ONE ROOM OWNS THIS DEVICE'S AUDIO, AND A PREVIEW IS
    /// REFUSED RATHER THAN ARBITRATED. Two owners of one audio session is how a private
    /// call ends up audible in a meeting.
    static let previewBusyCall = "There is a call on this device. End it before previewing the persona."

    static let previewBusyRoom = "You are in a room on this device. Leave it before previewing the persona."

    /// ⚠️ A DENIED MICROPHONE IS NOT FATAL TO THE SESSION — the agent still greets and
    /// can be heard — but it is fatal to the point of it, so it is said plainly.
    static let previewMicrophoneDenied = "The microphone is not available to this app, so the agent will "
        + "not hear you. You can still hear it answer."

    /// ⛔ THE BUTTON STAYS DISABLED FOR A MOMENT AFTER A PREVIEW ENDS, AND THE SENTENCE
    /// SAYS WHY. The route is capped at ten a minute per workspace and each token starts
    /// a billed session; nothing in this client retries one.
    static let previewCooldown = "Give the last session a moment to finish before starting another."

    /// ⚠️ A PREVIEW THAT WAS TAKEN AWAY BY A CALL, said rather than left as an absence.
    static let previewYieldedToCall = "A call arrived on this device, so the preview was ended."

    // MARK: - The routing editor

    static let routingRuleEyebrow = "Rule"

    /// ⛔ THE SAVE REPLACES THE WHOLE LIST. It is the one thing the rows cannot say for
    /// themselves, and the route answers `{success:true}` either way.
    static let routingNote = "Each rule changes the agent's voice or model for callers it matches. "
        + "Saving replaces the whole list, so anything removed here is gone."

    static let routingFieldLabel = "When this caller detail"

    static let routingOperatorLabel = "Is compared by"

    static let routingValueLabel = "To this value"

    static let routingVoiceLabel = "Use this voice"

    static let routingModelLabel = "Use this engine"

    /// ⛔ AN EMPTY `model` IS A REAL, MEANINGFUL VALUE AND IS NOT AN ABSENCE. The route
    /// reads a falsy model as "no override, use the workspace engine", and the web's own
    /// picker keeps an empty option for exactly that.
    static let routingModelInherit = "The workspace's engine"

    static let routingInstructionLabel = "And tell the agent"

    static let routingAdd = "Add a rule"

    static let routingRemove = "Remove"

    static let routingSave = "Save rules"

    /// ⛔ A ROW THIS BUILD CANNOT READ IS SHOWN, KEPT AND NOT OFFERED AN EDITOR. The
    /// stored column predates every schema on it and holds rows shaped nothing like the
    /// six fields above; an editor over one would have to invent them, and saving would
    /// then stamp six keys beside the four it could not read.
    static let routingUnrecognised = "This rule was written in a shape this app does not recognise. It "
        + "is shown so it is not a surprise, it is kept exactly as it is when you save, and it cannot "
        + "be changed here."

    /// ⚠️ FLAGGED, NEVER REFUSED. A rule with nothing to match on is legal, is stored,
    /// and simply never fires — which is exactly what an operator opened this screen to
    /// find out.
    static let routingIncomplete = "This rule has nothing to match on, so it never fires."

    /// ⚠️ THE VOICE LIST IS THE REALTIME ENGINE'S OWN, derived rather than restated, and
    /// an empty one is honest about a catalogue that carries no such engine.
    static let routingVoicesEmpty = "No voices are published for rules, so this rule's voice is shown "
        + "as stored and cannot be changed."

    /// ⛔ SAVING NOTHING DELETES EVERY RULE, AND IT ANSWERS SUCCESS. A confirmation
    /// rather than a caption, for the same reason the transfer directory has one.
    static let routingEmptyConfirm = "Save with no rules? Every caller will hear the persona exactly as "
        + "configured, and the rules are gone. There is no undo."

    static let routingEmptyConfirmAction = "Save with no rules"

    /// ⚠️ THE SERVER'S OWN REFUSAL IS WORTH SHOWING VERBATIM: a workspace that restricts
    /// voices or models rejects a rule naming one outside its allow-list, BY NAME, and
    /// this client cannot see either list.
    static let routingSaveHint = "A workspace can restrict which voices and engines a rule may name. "
        + "If one is refused, the reason above names it."
}
