import Foundation

/// The knowledge, messaging and members copy.
///
/// ⚠️ A SECOND FILE FOR THE SAME NAMESPACE, WHICH IS A LINT CEILING RATHER THAN A
/// SPLIT WITH MEANING. `swiftlint --strict` promotes the `file_length` warning at 500
/// lines to an error. The division is roughly "sections that hydrate from
/// `workspace/config`" in the first file and "sections that do not" here, which is at
/// least the same line the role gates fall on.
extension SettingsCopy {
    // MARK: - How calls are answered

    static let callsModeEyebrow = "Who answers"

    /// ⛔ WORDED AS WHAT HAPPENS ON THE NEXT CALL, NEVER AS THE ENUM. `ai_first`,
    /// `ai_then_app` and `app_first` are wire values; an operator choosing between them
    /// is choosing whether their phone rings, and these three sentences are the only
    /// place that is said. ⚠️ In the server's order, which runs from "the agent handles
    /// everything" to "your phone rings first" — reordering the picker would change what
    /// somebody scanning it reads without changing a value.
    static let callsModeAiFirst = "The agent answers everything"

    static let callsModeAiThenApp = "The agent answers, then rings your phone"

    static let callsModeAppFirst = "Your phone rings first"

    /// ⚠️ A MODE THIS BUILD HAS NOT LEARNED IS DISPLAYED AS ITSELF rather than rewritten
    /// to one the operator did not choose. It cannot be SENT — the save refuses it
    /// locally — so the picker shows it as the current selection and offers the three it
    /// knows.
    static let callsModeUnknown = "A setting this version of the app does not recognise"

    static let callsRingEyebrow = "How long your phone rings"

    static let callsRingLabel = "Ring for"

    /// ⚠️ SECONDS, NAMED, because a bare number beside a stepper reads as a count of
    /// rings on a telephone.
    static func callsRingValue(_ seconds: Int) -> String {
        "\(seconds) seconds"
    }

    /// ⛔ SAYS WHEN THE RING DURATION MATTERS AT ALL, which is not guessable from the
    /// control. On `ai_first` nothing rings, so the stepper is set and never used; saying
    /// so is what stops an operator concluding the setting is broken.
    static let callsRingNote = "This applies when your phone is rung. On \"The agent answers "
        + "everything\" nothing rings, so it has no effect."

    static let callsSave = "Save"

    /// ⚠️ THE PATCH ECHOES WHAT IT WROTE, unlike every other save on this surface, so
    /// there is no re-read to fail and no "saved but stale" state to report here.
    static let callsSaved = "Saved."

    /// ⛔ THE READ ADMITS A VIEWER AND THE WRITE DOES NOT, so this screen is offered
    /// read-only rather than hidden — the opposite call from persona and capabilities,
    /// whose reads refuse a viewer outright. The wording follows the pattern the
    /// knowledge and messaging sections already use.
    static let callsViewerNote = "You are in this workspace as a viewer, so you can see how calls "
        + "are answered and not change it."

    static let callsLoadFailedEyebrow = "Could not load how calls are answered"

    // MARK: - Knowledge

    static let knowledgeDocumentsEyebrow = "Documents"

    static let knowledgeEmptyTitle = "Nothing uploaded yet"

    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND MUST NOT READ AS A FAILURE. It is where
    /// every workspace starts.
    static let knowledgeEmptyBody = "The agent answers from its persona and its capabilities until "
        + "something is added here."

    static let knowledgeAddEyebrow = "Add a document"

    static let knowledgeTitleLabel = "Title"

    static let knowledgeContentLabel = "Text"

    /// ⛔ ONE TAP IS ONE EMBEDDING RUN OVER HOWEVER MANY CHUNKS THE TEXT PRODUCED, and
    /// it is the only call in this app that spends model budget on the operator's
    /// behalf. Saying so is what makes a long paste a decision rather than a surprise.
    static let knowledgeAddNote = "The text is split into chunks and each one is indexed, so a long "
        + "document costs more than a short one. This cannot be undone from the app."

    static let knowledgeAdd = "Add document"

    static let knowledgeAddRejected = "A title and some text are both needed."

    static let knowledgeAdded = "Added."

    static let knowledgeModeEyebrow = "Where answers come from"

    static let knowledgeModeInternal = "This workspace's own documents"

    static let knowledgeModeLinked = "The District AI help centre"

    /// ⛔ A DATA-RESIDENCY CHANGE, NOT A DISPLAY PREFERENCE, so the confirmation names
    /// where the question goes rather than asking "are you sure".
    static let knowledgeModeConfirm = "Switching to the help centre sends this workspace's caller "
        + "questions to Atlassian to compose an answer. Its own documents will not be used."

    static let knowledgeModeConfirmAction = "Send questions to the help centre"

    /// ⛔ "WE COULD NOT READ THE MODE" AND "THE MODE IS INTERNAL" ARE DIFFERENT CLAIMS
    /// ABOUT WHERE A CUSTOMER'S QUESTIONS GO. The selector is withheld rather than
    /// seeded from a guess.
    static let knowledgeModeUnavailable = "We could not read which knowledge source this workspace "
        + "uses, so it is not shown and cannot be changed here."

    /// ⚠️ A mode this build has not learned is DISPLAYED as itself rather than
    /// rewritten to one the operator did not choose.
    static let knowledgeModeUnknown = "A source this version of the app does not recognise."

    static let knowledgeViewerNote = "You are in this workspace as a viewer, so you can read the "
        + "knowledge base and not change it."

    // MARK: - Messaging

    static let messagingAccountsEyebrow = "Carrier accounts"

    /// ⚠️ A FRESH WORKSPACE IS A STATE, NOT AN ERROR, and the sentence says what
    /// happens next rather than what is missing.
    static let messagingEmptyTitle = "No carrier connected"

    /// ⛔ IT NAMES NO OTHER PLACE TO ADD ONE, BECAUSE IT IS RENDERED DIRECTLY ABOVE THE
    /// BUTTON THAT ADDS ONE (``MessagingAccountSheet``). Sending an operator to a laptop
    /// to do something the button under their thumb does is worse than saying nothing.
    static let messagingEmptyBody = "Messages cannot be sent from this workspace until a carrier "
        + "account is added."

    static let messagingManagedEyebrow = "Numbers Distronode holds for you"

    /// ⛔ THE PLATFORM ACCOUNT IS NOT AN ENTRY IN THE ACCOUNT LIST AND MUST NOT BE
    /// DRAWN AS ONE. That list is the id space a sender is validated against, so a
    /// synthetic managed row would be a pickable sender whose every send is rejected.
    static let messagingManagedNote = "These are on Distronode's own carrier account. They cannot "
        + "be picked as a sender here."

    /// ⚠️ A FRESH WORKSPACE OMITS `defaultAccountId` AND NULLS `managedAccount`. That
    /// is a state, not an error, and this is the sentence for it.
    static let messagingNoDefault = "No default sender is set, so the workspace has not chosen "
        + "which identity a message leaves from."

    static let messagingDefaultBadge = "Default sender"

    static let messagingChannelsEyebrow = "Per-channel senders"

    static let messagingNoChannelOverrides = "Every channel uses the default sender."

    static let messagingSetDefault = "Make default"

    static let messagingDelete = "Remove account"

    /// ⛔ THE CONFIRMATION NAMES THE CONSEQUENCE RATHER THAN ASKING "are you sure".
    /// Removing an account frees every phone number only it held in the hub index that
    /// routes inbound calls and SMS to this workspace, and once released another tenant
    /// can claim one. There is no undo that does not involve re-proving ownership at
    /// the carrier.
    static let messagingDeleteConfirm = "Remove this account? Every phone number only it holds is "
        + "released, and another business can then claim one. Getting a number back means proving "
        + "ownership at the carrier again."

    static let messagingCredentialsRedacted = "Credentials are not shown, and they are not sent "
        + "back when you save."

    static let messagingViewerNote = "You are in this workspace as a viewer, so you can see which "
        + "identity messages leave from and not change it."

    static let messagingCreatorCellEyebrow = "Creator cell number"

    /// ⛔ NOTHING IN THIS CLIENT CAN READ THE STORED VALUE BACK. It is not on the
    /// messaging GET and the write answers a bare acknowledgement, so the field asks
    /// for a NEW number and says so rather than presenting an empty box an operator
    /// reads as "not set".
    static let messagingCreatorCellNote = "This number is not readable by the app, so the box is "
        + "always empty. Anything entered here replaces what is stored."

    static let messagingCreatorCellLabel = "New number"

    static let messagingCreatorCellSave = "Save number"

    // MARK: - Members

    static let membersRosterEyebrow = "Roster"

    static let membersAddEyebrow = "Add someone"

    static let membersEmailLabel = "Email address"

    static let membersAdd = "Add member"

    /// ⛔ THE ROUTE'S OWN LOOSE EMAIL RULE, MIRRORED SO THE BUTTON IS HONEST. The point
    /// is that a stored address is MATCHABLE by the membership lookups, not that it is
    /// deliverable.
    static let membersAddRejected = "That does not look like an email address."

    /// ⚠️ NO INVITATION IS SENT AND NO ACCOUNT IS CREATED. An operator who expects an
    /// email would otherwise wait for one that is not coming.
    static let membersAddNote = "No invitation is sent. If that address has never signed up, the "
        + "membership waits until it does."

    static let membersRemove = "Remove"

    /// ⛔ REMOVING SOMEONE ENDS THEIR ACCESS IMMEDIATELY and re-adding them is a new
    /// row rather than an undo.
    static let membersRemoveConfirm = "Remove this person? They lose access to every call, contact "
        + "and conversation in this workspace on their next request."

    static let membersRoleLabel = "Role"

    /// ⛔ THE SERVER'S DEFAULT IS `client`, NOT `viewer`, and the cautious guess is
    /// wrong: someone added without touching the picker gets more than read-only.
    static let membersRoleNote = "Someone added without changing this becomes a member who can use "
        + "and change the workspace."

    static let membersRenameEyebrow = "Workspace name"

    /// ⛔ THE FIELD DOES NOT PREFILL AND THAT IS THE LOAD-FIRST RULE APPLIED HONESTLY.
    /// Nothing this client can call returns the workspace's current name: the roster
    /// does not carry it, `workspace/config` excludes it, and the only read that has it
    /// fans out across every region. A box seeded from nothing is how a blank gets
    /// saved over a real value.
    static let membersRenameNote = "The current name is not readable here, so this box asks for a "
        + "new one. What you save replaces it."

    static let membersRenameLabel = "New name"

    static let membersRename = "Rename workspace"

    /// ⚠️ NOT A MISTAKE THE OPERATOR MADE, AND NOT RETRYABLE. Pressing again produces
    /// the identical refusal.
    static let membersLastAgency = "This workspace would be left with no administrator, so that "
        + "change was refused."

    static let membersDuplicate = "That address is already a member of this workspace."

    static let membersViewerNote = "You are in this workspace as a viewer, so you can see who has "
        + "access and not change it."

    /// ⚠️ WIDER THAN THE MEMBERSHIP GATE, DELIBERATELY. `workspace/rename` admits a
    /// client while every membership write is agency-only, so the screen gates two
    /// things at two widths and says so.
    static let membersClientNote = "Adding, removing and changing roles is limited to workspace "
        + "administrators."
}
