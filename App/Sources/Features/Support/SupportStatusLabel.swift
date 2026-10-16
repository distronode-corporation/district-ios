import DistrictModel
import Foundation

/// The words a support request's status badge shows, in the app's language (3.0.1).
///
/// ⛔ THE DESK'S OWN `statusName` IS NEVER SHOWN AS IT IS. It is the help desk's English
/// ("Waiting for support"), so a French screen showed English, and the live workflow is
/// localised besides (`完成` and `等待客户` have been seen), so a raw name can be in any
/// language. A name this build lists gets its catalog label in English and fr-CA.
///
/// ⛔ AN UNLISTED NAME GETS A LOCALIZED GENERIC LABEL, FROM ITS CATEGORY: Atlassian's
/// language-independent bucket (`NEW`, `INDETERMINATE`, `DONE`, or the server's synthetic
/// `PENDING` while unfiled) reads as Open, In progress, Closed or Received, and an unknown
/// bucket as "Status unknown". The same rule ``WireLabel`` keeps: never the value humanized.
///
/// ⚠️ DISPLAY ONLY. Every decision about a request (resolved, closeable, the badge tone)
/// stays on the category and the server's flags, never on this label.
enum SupportStatusLabel {
    /// The label of a status, matched trimmed and case-insensitively.
    static func label(_ statusName: String, category: String) -> String {
        let key = statusName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let known = known(key) {
            return known
        }
        return generic(category)
    }

    /// The label of every status name this build lists, or nil.
    ///
    /// ⚠️ THE NAMES ARE THE SERVICE MANAGEMENT WORKFLOW'S AND THE SERVER'S OWN: `Received` is
    /// what the server writes for a request Atlassian does not hold yet, `unknown` what it
    /// writes when Atlassian sent no status, and `Done` its default for a close.
    private static func known(_ key: String) -> String? {
        switch key {
        case "received": SupportCopy.statusReceived
        case "open", "reopened", "to do": SupportCopy.statusOpen
        case "waiting for support": SupportCopy.statusWaitingForSupport
        case "waiting for customer": SupportCopy.statusWaitingForCustomer
        case "in progress", "work in progress": SupportCopy.statusInProgress
        case "pending": SupportCopy.statusPending
        case "escalated": SupportCopy.statusEscalated
        case "resolved": SupportCopy.statusResolved
        case "done", "completed": SupportCopy.statusDone
        case "closed": SupportCopy.statusClosed
        case "canceled", "cancelled": SupportCopy.statusCanceled
        case "declined": SupportCopy.statusDeclined
        case "unknown": SupportCopy.statusUnknown
        default: nil
        }
    }

    /// ⚠️ THE CATEGORY IN EITHER SPELLING: the core issue API reports it lower-case and the
    /// servicedeskapi upper-case, so it is compared without case, as ``SupportStatusCategory``
    /// does.
    private static func generic(_ category: String) -> String {
        if SupportStatusCategory.isResolved(category) {
            return SupportCopy.statusClosed
        }
        switch category.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "NEW": return SupportCopy.statusOpen
        case "INDETERMINATE": return SupportCopy.statusInProgress
        case "PENDING": return SupportCopy.statusReceived
        default: return SupportCopy.statusUnknown
        }
    }
}
