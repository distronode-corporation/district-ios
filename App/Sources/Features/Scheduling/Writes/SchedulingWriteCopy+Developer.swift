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
    // MARK: - Webhooks

    /// ⛔ THE SAVE WOULD NARROW THIS ROW'S SUBSCRIPTION, AND THE SHEET SAYS SO. An
    /// event name this build does not know cannot be drawn as a box and cannot be
    /// sent back (the fork answers `unknown event: <name>`), so the honest move is
    /// to name what is about to be lost rather than to lose it quietly.
    static func webhookDroppedEvents(_ names: [String]) -> String {
        webhookDroppedEventsLine(names.joined(separator: ", "))
    }
}
