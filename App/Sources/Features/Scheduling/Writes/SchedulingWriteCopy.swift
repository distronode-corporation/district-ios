import Foundation

/// The words the scheduling admin's write sheets put on screen.
///
/// ⛔ COPIED FROM THE WEB'S COMPONENTS VERBATIM WHEREVER THE WEB HAS A SENTENCE,
/// AND THAT IS A CORRECTNESS RULE RATHER THAN A CONSISTENCY ONE. These sheets
/// drive the same fork through the same catalog as the web dashboard's
/// scheduling components, so a refusal, a confirmation or a
/// validation message that differs between the two is one product answering a
/// question two ways. Where a string here has no web original it says so.
///
/// ⛔ AND NOTHING HERE IS LOCALISED, because nothing in this app is yet. The
/// French site is a website surface; the iOS client ships English only, and a
/// half-localised catalog would be worse than an honest monolingual one.
///
/// ⚠️ SEPARATE FROM `SchedulingCopy` (the hub card's copy) ON PURPOSE: keeping
/// the two surfaces' wording in separate types lets each change without touching
/// the other.
enum SchedulingWriteCopy {
    static let cancel = "Cancel"
    static let save = "Save"
    static let saving = "Saving…"
    static let delete = "Delete"
    static let add = "Add"
    static let remove = "Remove"
    static let edit = "Edit"
    static let retry = "Try again"
    static let dismiss = "Dismiss"

    /// ⚠️ THE WORD ON THE CONTROL THAT OPENS THE STATE ACTIONS, and it is
    /// deliberately not "Edit": the sheet behind it turns an event type on and
    /// off, archives it, deletes it and sends test emails, none of which is the
    /// form. The web event types table calls the same menu "Actions"; on a phone the
    /// row IS the menu, so the button says what pressing it leads to.
    static let manage = "Manage"
}
