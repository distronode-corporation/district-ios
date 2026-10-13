import DistrictModel
import Foundation

/// Every string on the Support screens.
///
/// ⛔ "SUPPORT" IS HELP **FROM DISTRONODE**, AND NOTHING HERE MAY BE WORDED SO THAT
/// IT COULD ALSO DESCRIBE THE DESK. The desk is the tenant's OWN queue: their
/// customers' tickets, answered by their agent. Both surfaces have requests,
/// threads, replies and a close, so the labels are the only thing keeping them
/// apart in a navigation list — which is why the web sidebar carries an explicit
/// instruction beside its two entries and why a bare "Tickets" or "Inbox" on
/// either one undoes the distinction. Every title and subtitle below names
/// Distronode or "our team" on purpose.
///
/// ⚠️ ITS OWN FILE FOR THE REASON `MarketplaceCopy` AND `DialerCopy` HAVE ONE:
/// `swiftlint --strict` reports the 500-line `file_length` warning as an error, and
/// a screen with a compose form, a thread and three writes carries more prose than
/// a view file can hold alongside its layout.
enum SupportCopy {
    // MARK: - Provenance chips

    /// ⚠️ SHOWN ONLY WHEN THE REGION IS NOT THE DEFAULT `us`, for the same reason:
    /// it answers "why does this one look different", which only a non-default
    /// region raises.
    static let defaultRegion = "us"

    // MARK: - Composing one

    /// ⛔ THE LABELS ARE NOT THE WIRE VALUES. `SupportRequestKind`'s raw values are
    /// the vocabulary the route validates; these are what a person reads. Same rule
    /// the contact inquiry types follow.
    static func kindLabel(_ kind: SupportRequestKind) -> String {
        switch kind {
        case .problem: kindProblem
        case .question: kindQuestion
        case .suggestion: kindSuggestion
        }
    }
}
