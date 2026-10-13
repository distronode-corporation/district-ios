import Foundation

/// Every string District Desk shows.
///
/// ⛔ THE FIRST JOB OF THIS FILE IS TO KEEP TWO SURFACES APART, AND IT IS NOT
/// DECORATION. District Desk is the tenant's OWN customers' tickets; Support is the
/// tenant raising something with DISTRONODE. They sit next to each other in the web
/// console's sidebar, where the labels are deliberately kept apart, and a bare
/// "Tickets" or "Inbox" on either one undoes that in a single word. Every title
/// and every empty state below says WHOSE customers it means, and none of them may be
/// shortened to a noun that could describe the other surface.
///
/// ⛔ AND NOTHING HERE MAY SAY "SUPPORT". The word belongs to the other queue. When
/// this screen has to point at Distronode, it names Distronode.
///
/// ⚠️ ONE FILE RATHER THAN LITERALS IN THE VIEWS, for the reason the settings copy
/// gives: a sentence that explains a consequence has to be readable beside the other
/// sentences that explain consequences, or the three of them drift into contradicting
/// each other about what turning the desk on actually does.
enum DeskCopy {
    // MARK: - One ticket

    // ⛔ NO `replyFailed` / `statusFailed` HERE, AND THAT IS DELIBERATE. Such a string could
    // only sit on the right of `FailureText.from(error).message ?? …`, whose left side is a
    // non-optional `String`, so the fallback would be unreachable and the compiler says so.
    // ``FailureText`` is the ONE mapping every screen shares, and its own ⛔ says that is
    // what stops the next screen re-deriving it and getting it wrong — a per-feature
    // failure string is exactly that re-derivation. ``DeskModel`` uses it directly
    // (`notice = FailureText.from(error).message`, no fallback).
}
