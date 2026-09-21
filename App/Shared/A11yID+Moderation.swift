/// The identifiers App Store Review Guideline 1.2 asks a reviewer to be shown:
/// the terms presented before sign-in, the flag on a piece of content, and the
/// block on the person who produced it.
///
/// ⛔ THEY ARE HERE BECAUSE A RECORDING HAS TO FIND THEM, NOT BECAUSE A UNIT TEST
/// DOES. Apple's request is a video made on a physical handset showing each
/// mechanism being used, and `App/UITests/ReviewRecordingTests.swift` drives that
/// walk — so every control in the 1.2 shot list needs a name that survives a copy
/// change. A control addressed by its LABEL would make the recording unrepeatable
/// the first time anybody reworded a button.
///
/// ⛔ NONE OF THESE MAY BE ADDED TO `UITestApp.forbiddenSurfaces`, AND THAT IS A
/// DECISION RATHER THAN AN OVERSIGHT. That set exists because the UI tests may run
/// signed into a LIVE production workspace, where a stray tap sends a real message or
/// releases a real number. A block is the one
/// destructive-sounding control here that is genuinely reversible — the route takes
/// the desired STATE, so an unblock puts the row back — and the whole point of the
/// recording is a test tapping it. ⚠️ What keeps that safe is the DATA rather than
/// the identifier: the demo workspace's contacts are fictional `+1 555 01xx`
/// numbers and the harness refuses to block anything else.
///
/// ⚠️ NEW STRINGS, WITH NO KOTLIN TWIN, AND THEY WILL NOT GET ONE. The Android client
/// has no blocking or reporting surface: Play's own user-generated-content policy is
/// enforced through the listing questionnaire rather than through a binary review, so
/// this is iOS-first for the same reason `district-sign-in-apple` is.
///
/// ⚠️ ITS OWN FILE, matching the four `A11yID+Scheduling*.swift` siblings. `A11yID.swift`
/// is the base and the extensions are expected rather than exceptional.
extension A11yID.SignIn {
    /// The container holding the whole "By continuing…" sentence.
    ///
    /// ⛔ ON THE CONTAINER WITH `.contain`, NOT ON THE SENTENCE'S `Text`. The line is
    /// composed of a `Text` plus two `Button`s so each legal page is separately
    /// tappable, and an identifier applied without `.contain` is INHERITED by every
    /// descendant in SwiftUI — which would overwrite both links' own names. Measured
    /// on `SignInView`'s root, which carries the same ⛔.
    static let terms = "district-sign-in-terms"

    static let termsLink = "district-sign-in-terms-link"
    static let privacyLink = "district-sign-in-privacy-link"
}

extension A11yID.Contacts {
    /// The badge on a blocked contact's DETAIL header.
    static let blockedBadge = "district-contact-blocked-badge"

    /// ⛔ NOT A SUFFIX ON ``A11yID/Contacts/rowBase``, AND THE PREFIX ORDER IS
    /// LOAD-BEARING. The recording harness finds a contact row with
    /// `identifier BEGINSWITH "district-contact-row-"`; a badge named
    /// `district-contact-row-blocked-<id>` would match that predicate too, and
    /// `firstMatch` would hand the walk a badge to tap instead of a row. Putting
    /// `blocked` before `row` keeps the two namespaces disjoint.
    static let blockedRowBase = "district-contact-blocked-row"

    static func blockedRow(_ id: String) -> String {
        A11yID.row(blockedRowBase, id)
    }

    /// ⚠️ TWO IDENTIFIERS FOR ONE CONTROL POSITION, because the label and the
    /// action both change with the state and a test has to be able to say WHICH it
    /// expects. One name plus a label assertion would pass on the wrong direction.
    static let block = "district-contact-block"
    static let unblock = "district-contact-unblock"
}

extension A11yID.Inbox {
    /// The thread screen's own root, so a walk can assert it arrived.
    static let threadRoot = "district-thread-root"

    /// The moderation menu in the thread's toolbar.
    static let threadMenu = "district-thread-menu"
    static let threadBlock = "district-thread-block"
    static let threadReport = "district-thread-report"
}

extension A11yID.Calls {
    /// The moderation menu in the call detail screen's toolbar.
    static let detailMenu = "district-call-detail-menu"
    static let report = "district-call-detail-report"
}

extension A11yID {
    /// The report sheet, shared by the thread and the call screens.
    ///
    /// ⚠️ ONE SET OF IDENTIFIERS FOR ONE SHEET, reached from two places. The sheet
    /// is the same view with a different subject line, so two sets would be two
    /// names for the thing a reviewer watches once.
    enum Report {
        static let root = "district-report-root"
        static let note = "district-report-note"
        static let submit = "district-report-submit"
        static let cancel = "district-report-cancel"
        /// The "Reported. We'll review it." confirmation.
        ///
        /// ⛔ ADDRESSABLE ON PURPOSE. Apple's ask is that the reviewer SEES the flag
        /// being accepted; a submit that dismissed the sheet silently would be
        /// indistinguishable on video from a submit that failed.
        static let confirmation = "district-report-confirmation"
    }
}
