import Foundation

/// Every sentence the DEVELOPER and CALENDAR write sheets can put on screen.
///
/// ⚠️ THE FIVE REFUSAL SENTENCES ARE NOT HERE: every scheduling surface reads them
/// from ``SchedulingFailureCopy``, the one mapping.
///
/// ⛔ A TYPE OF ITS OWN, NOT AN EXTENSION OF `SchedulingCopy`. That enum is the
/// tenancy card's copy; a second surface appending to it would couple two screens'
/// wording for no benefit, since nothing here is shared with the tenancy card.
enum SchedulingWriteCopyC {
    // MARK: - API keys

    static let keySheetTitle = "Create key"
    static let keyNameLabel = "Name"
    static let keyNameHint = "What will use this key. You will see it in the list and nowhere else."
    static let keyNameMissing = "Give the key a name."
    static let keyCreate = "Create key"
    static let keyCreating = "Creating…"

    /// ⛔ THE SHOW-ONCE SENTENCE, AND IT IS THE APP'S OWN RATHER THAN THE FORK'S.
    /// `SchedulingAPIKeyCreated.note` carries an English string from a service
    /// that does not localise; treating it as the source would make the one
    /// sentence a customer has to act on untranslatable.
    static let keyRevealWarning = "Copy it now. It is not shown again."
    static let keyCopyAction = "Copy key"
    static let keyCopied = "Copied"
    static let keyDone = "Done"

    static let keyRevokeConfirm = "Anything using it stops working now."
    static let keyRevokeAction = "Revoke key"
    static let cancel = "Cancel"

    static func keyRevokePrompt(_ name: String) -> String {
        "Revoke \(name)?"
    }

    static func keyRevealTitle(_ name: String) -> String {
        "Your key for \(name)"
    }

    // MARK: - Connected apps

    static let appRevokeAction = "Revoke access"
    static let appRevokeConfirm = "It stops reaching this workspace's booking data now."

    static func appRevokePrompt(_ clientName: String) -> String {
        "Revoke \(clientName)?"
    }

    // MARK: - Webhooks

    static let webhookAddTitle = "Add webhook"
    static let webhookEditTitle = "Edit webhook"
    static let webhookUrlLabel = "Endpoint URL"
    static let webhookUrlHint = "Where each delivery is posted. https only."
    /// ⛔ THE URL IS NOT EDITABLE, BECAUSE `webhooks.patch` TAKES ONLY `events`
    /// AND `fields`. Offering a box that silently kept the old value is worse
    /// than not offering one: the person believes deliveries have moved.
    static let webhookUrlFixed = "The URL cannot be changed. Delete this webhook and add another to move it."
    static let webhookEventsLabel = "Events"
    static let webhookEventsHint = "What to send. Each one is a separate delivery."
    static let webhookEventsMissing = "Choose at least one event."
    static let webhookFieldsLabel = "Data to send"
    static let webhookFieldsHint = "Which parts of the booking each delivery carries."
    static let webhookPersonalData = "Personal data"
    static let webhookAddAction = "Add webhook"
    static let webhookSaveAction = "Save changes"
    static let webhookSaving = "Saving…"

    static let webhookSecretTitle = "Your signing secret"
    static let webhookSecretCopyAction = "Copy signing secret"
    static let webhookAdded = "Webhook added"
    static let webhookUpdated = "Webhook updated"

    static let webhookDeletePrompt = "Delete this webhook?"
    static let webhookDeleteAction = "Delete webhook"
    static let webhookDeleteConfirm =
        "It stops receiving booking changes now, and its signing secret cannot be recovered."

    /// ⛔ THE SAVE WOULD NARROW THIS ROW'S SUBSCRIPTION, AND THE SHEET SAYS SO. An
    /// event name this build does not know cannot be drawn as a box and cannot be
    /// sent back (the fork answers `unknown event: <name>`), so the honest move is
    /// to name what is about to be lost rather than to lose it quietly.
    static func webhookDroppedEvents(_ names: [String]) -> String {
        "Saving will stop sending \(names.joined(separator: ", ")). "
            + "This app does not know those events, so it cannot send them back."
    }

    static func webhookSecretNote(_ url: String) -> String {
        "Every delivery to \(url) is signed with it, in the X-Calnode-Signature header."
    }

    // MARK: - URL refusals

    static let webhookUrlMissing = "Give the webhook a URL."
    static let webhookUrlNotAUrl = "That is not a URL. It has to start with https://."
    static let webhookUrlNotHttps = "The URL has to start with https://."
    static let webhookUrlPrivate = "That address is not reachable from the internet. Use a public https URL."
}
