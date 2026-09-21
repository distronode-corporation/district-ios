import Foundation

/// Every sentence the workspace settings hub and its sections say.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF A MODEL, the same call
/// ``DialerCopy`` and ``IncomingCallCopy`` make and for the same reason: `swiftlint
/// --strict` promotes the `file_length` warning at 500 lines to an error, and this
/// surface is eight screens' worth of copy. Keeping it in one place also means the
/// four sentences that have to AGREE with each other (the load failure, the
/// not-editable notice, the saved-but-stale banner and the viewer note) are
/// readable side by side rather than scattered across eight files.
///
/// ⛔ THE WORDING IS THE PRODUCT ON THIS SURFACE, NOT DECORATION. Three of its save
/// routes replace a stored array wholesale, so the difference between "we could not
/// read your configuration" and "your configuration is empty" is the difference
/// between a retry and a deletion; and the difference between "saved" and "saved,
/// but we could not read it back" is what stops an operator saving a second time
/// from a baseline that has moved. Read the ⛔s beside each string before rewriting
/// one.
enum SettingsCopy {
    // MARK: - The hub

    static let hubTitle = "Workspace settings"

    static let personaTitle = "Agent persona"
    static let personaSubtitle = "Name, greeting and personality"

    static let capabilitiesTitle = "Capabilities"
    static let capabilitiesSubtitle = "What the agent may do on a call"

    static let callsTitle = "How calls are answered"
    static let callsSubtitle = "The agent, your phone, or both"

    static let directoryTitle = "Transfer directory"
    static let directorySubtitle = "Who a live caller can be put through to"

    static let routingTitle = "Dynamic persona rules"
    static let routingSubtitle = "How the agent adapts to who is calling"

    static let knowledgeTitle = "Knowledge base"
    static let knowledgeSubtitle = "What the agent answers from"

    static let messagingTitle = "Messaging"
    static let messagingSubtitle = "Which identity messages leave from"

    static let membersTitle = "Members"
    static let membersSubtitle = "Who has access to this workspace"

    static let schedulingTitle = "Scheduling"
    static let schedulingSubtitle = "The workspace's booking pages"

    /// ⚠️ SAYS WHY THE LIST STOPS WHERE IT DOES. Campaign settings and the avatar
    /// form have no native screen and are not planned to get one.
    ///
    /// ⚠️ THE IDENTIFIER NAMES THE WEB AND THE SENTENCE DOES NOT. The sentence names
    /// nowhere, because Guideline 3.1.1 forbids steering; renaming the identifier would be
    /// a call-site change with no copy in it.
    static let moreOnWeb = "Campaign settings and the avatar configuration are not available "
        + "in this app."

    /// ⛔ A DIFFERENT SENTENCE FOR A VIEWER, AND "edit it on the web" WOULD BE FALSE.
    /// A viewer cannot edit these there either, so the note says what is true: the
    /// sections that are missing are missing because the reads behind them refuse
    /// this role.
    static let viewerNote = "You are in this workspace as a viewer, so the sections that change how "
        + "the agent behaves are not available to you."

    // MARK: - Shared section chrome

    static let loadFailedEyebrow = "Could not load this workspace's configuration"

    /// ⛔ THE SAVE LANDED AND ONLY THE READ BACK FAILED, AND THIS IS NOT AN ERROR.
    /// Telling an operator the save failed is the dangerous direction: they would
    /// change the form back and save again, through a route that replaces its stored
    /// array wholesale, from state this client can no longer vouch for. It offers a
    /// re-read, never a re-save.
    static let savedButStale = "Saved. We could not read the configuration back, so what is on "
        + "screen may be out of date."

    static let saved = "Saved."

    static let retry = "Try again"

    static let reread = "Reload"

    /// ⛔ THE ONLY WAY A BANNER LEAVES THE SCREEN WITHOUT ANOTHER WRITE. Every model on
    /// this surface has a `dismissNotices()`, and without a control wired to it a red
    /// refusal sits beside a fresh "Saved." with nothing to press.
    /// ⚠️ A successful RELOAD retires them too; this is for the operator who
    /// has read the message and does not want to re-read anything.
    static let dismiss = "Dismiss"

    /// ⛔ THE READ SUCCEEDED AND THE VALUE STILL CANNOT BE EDITED, WHICH IS A THIRD
    /// STATE RATHER THAN A FAILURE. `callDirectory` and `routingRules` are `Json`
    /// columns that can hold rows written before their save routes validated anything,
    /// so a stored array whose rows are not objects genuinely exists. ⚠️ No retry:
    /// nothing about the request failed, and repeating it returns the same value.
    static let notEditableEyebrow = "Stored in a shape this app cannot edit"

    static let notEditableBody = "This value was written before the settings routes validated it, "
        + "so showing it here could not be done without misrepresenting part of it. It cannot be "
        + "read or changed in this app."

    // MARK: - Persona

    static let personaNameLabel = "Agent name"
    static let personaGreetingLabel = "Greeting"
    static let personaPersonalityLabel = "Personality"

    /// ⛔ NOT A REFUSAL. The lists ARE readable — `persona/options` publishes exactly
    /// the vocabularies the web derives its own pickers from — so a sentence saying they
    /// cannot be changed here would send an operator to find a browser for nothing. This
    /// says the thing the pickers cannot say for themselves: the values come from the
    /// server and are never a list this app made up, which is why a failed read turns the
    /// panel read-only instead of guessing. See ``personaOptionsFailedNote``.
    static let personaReadOnlyNote = "The engine, voice, language and style come from the lists this "
        + "workspace's own server publishes, so nothing here can offer a value the agent would not honour."

    static let personaEngineEyebrow = "Engine and voice"

    static let personaUnset = "Not set"

    // MARK: - Capabilities

    static let capabilitiesEyebrow = "What the agent may do"

    /// ⚠️ SAYS WHAT AN EMPTY ALLOWLIST ACTUALLY DOES, because "off" on nine switches
    /// reads as a smaller change than it is.
    static let capabilitiesNote = "Turning everything off leaves the agent able to talk and nothing "
        + "else."

    /// ⛔ WHY A WORKSPACE THAT HAS NEVER STORED A LIST CANNOT BE SAVED FROM A PHONE,
    /// AND IT IS THE SAME WHOLESALE-REPLACE HAZARD THE REST OF THIS SURFACE IS BUILT
    /// AROUND. `PATCH workspace/tools` stores exactly the array it receives, so a
    /// FIRST save from here would store exactly what this build can name — and a
    /// capability District AI added after this build shipped would be switched off by
    /// someone who never saw it. Only a surface that ships from the same deploy as the
    /// route can be trusted with the FIRST choice, which is why this build refuses it.
    /// ⚠️ IT NAMES NOWHERE ELSE TO MAKE THAT CHOICE (Guideline 3.1.1 forbids steering);
    /// the refusal and its reason are what the operator needs.
    /// ⚠️ SAYS "every capability is on" rather than listing them: this build
    /// cannot enumerate what it has not learned, and pretending otherwise here would
    /// be the same claim in words that the save would have made in data.
    static let capabilitiesNoStoredList = "This workspace has never chosen which capabilities are "
        + "on, so they all are. Choosing them here would switch off anything District AI has added "
        + "since this version of the app shipped, so the first choice cannot be made in this app. "
        + "After that they can be changed here."

    static let capabilitiesUnknownRow = "Stored by this workspace and not recognised by this "
        + "version of the app. It is kept when you save."

    static let capabilitiesSave = "Save capabilities"

    static let enrichmentEyebrow = "Lead enrichment"

    /// ⛔ THE SUB-PROCESSOR LIST PROMISES THIS IS OFF UNTIL SOMEONE TURNS IT ON, so
    /// the wording has to say what turning it on does rather than name a feature.
    static let enrichmentBody = "Look up public information about an unknown caller from an outside "
        + "provider. Off unless someone in this workspace turns it on."

    static let enrichmentToggle = "Enrich unknown callers"

    static let enrichmentSave = "Save lead enrichment"

    // MARK: - Transfer directory and routing rules, both editable

    /// ⛔ THE ONE THING AN OPERATOR CANNOT SEE FROM THE ROWS THEMSELVES: saving through
    /// ``WorkspaceRepository/saveDirectory(workspaceId:callDirectory:)`` REPLACES the
    /// list rather than adding to it.
    static let directoryNote = "The agent puts a live caller through to these people. Saving "
        + "replaces the whole list, so anything removed here is gone."

    static let directoryEmptyTitle = "No transfer targets"

    /// ⛔ A CONSEQUENCE, NOT A COUNT. "No transfer targets" is a number; what actually
    /// happens on the next call is that the agent takes a message, and that is the reason
    /// somebody opened this screen.
    static let directoryEmptyBody = "The agent has nobody to put a caller through to, so it will "
        + "take a message instead."

    static let directoryNameLabel = "Name"

    static let directoryNumberLabel = "Phone number"

    static let directoryTypeLabel = "Reached by"

    /// ⛔ THE TWO WORDS THAT DECIDE WHETHER A TRANSFER DIALS A TELEPHONE OR RINGS AN
    /// APP, WORDED FOR AN OPERATOR RATHER THAN AS THE WIRE VALUES. `pstn` and `app` are
    /// what the route validates; nobody has ever called them that out loud.
    static let directoryTypePstn = "Phone number"

    static let directoryTypeApp = "District AI app"

    /// ⚠️ SAYS WHAT `app` ACTUALLY DOES, because it is not guessable from the label.
    static let directoryTypeNote = "\"District AI app\" rings this person in the app instead of "
        + "dialling the number. The number is still used if they cannot be reached."

    static let directoryAdd = "Add someone"

    static let directoryRemove = "Remove"

    static let directorySave = "Save directory"

    /// ⛔ A HALF-FILLED ROW IS SHOWN RATHER THAN HIDDEN AND IS NOT REFUSED ON SAVE. The
    /// server's schema has both fields `.nullish()`, so rows like this already exist and
    /// deleting one silently would be worse than keeping it. It IS flagged, because a
    /// target with no number is a target the agent cannot use.
    static let directoryIncomplete = "This row has no number, so the agent cannot transfer to it."

    /// ⛔ THE ONE THING THE ROW LIST CANNOT SAY FOR ITSELF. The route replaces the whole
    /// array, so an empty save is a real deletion of every target — and it answers
    /// `{success:true}`, which is why this is a confirmation rather than a caption.
    static let directoryEmptyConfirm = "Save an empty directory? The agent will have nobody to put "
        + "a live caller through to and will take a message instead. There is no undo."

    static let directoryEmptyConfirmAction = "Save an empty directory"

    /// ⛔ THE RULES ARE EDITABLE HERE, AND THE TWO OBVIOUS REASONS NOT TO ARE ANSWERED
    /// RATHER THAN WAIVED. A row is carried BYTE-IDENTICALLY through
    /// ``RoutingRuleDraft``, which overwrites only the six keys the form owns and sends
    /// a row it does not recognise back exactly as it arrived — so a `.passthrough()`
    /// column is not a reason to refuse. And the per-workspace voice and model
    /// allow-list is invisible to this client, which is why the editor does NOT
    /// pre-validate against a guess: it offers the catalogue, sends what was chosen, and
    /// shows the server's refusal verbatim when there is one. See ``routingSaveHint``.
    ///
    /// ⚠️ WHAT IS LEFT IS THE SENTENCE THE ROWS CANNOT SAY THEMSELVES, and it lives in
    /// ``routingNote``: saving replaces the whole list.
    static let routingEmptyTitle = "No dynamic persona rules"

    /// ⚠️ A CONSEQUENCE RATHER THAN A COUNT, the same call ``directoryEmptyBody`` makes:
    /// what actually happens on the next call is that everybody hears one persona.
    static let routingEmptyBody = "Every caller hears the persona exactly as it is configured above."

    static let routingRuleFallback = "Rule"

    // MARK: - Scheduling

    /// ⚠️ THE HUB'S SCHEDULING ROW OPENS THE EXISTING SCHEDULING DESTINATION rather
    /// than a settings section of its own, so there is no second copy of that
    /// screen's rules to drift.
    static let schedulingRowNote = "Booking pages are managed on their own screen."
}
