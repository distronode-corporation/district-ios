import Foundation

/// The two recording deletions, one of which is the most destructive thing on
/// this surface.
///
/// ⛔ PORTED FROM THE WEB RECORDINGS TABLE. See the namespace note on
/// ``SchedulingBookingWriteCopy``.
enum SchedulingRecordingWriteCopy {
    // MARK: - One recording

    static let deleteTitle = "Delete recording?"
    /// ⚠️ NAMES ALL THREE ARTEFACTS. An operator deleting "a recording" does not
    /// necessarily expect the transcript and the meeting notes written from it to
    /// go with it, and they do.
    static let deleteBody = "The video file, its transcript and the meeting notes written from it all go. "
        + "A recording still in progress cannot be deleted; stop it first."
    static let deleteCancel = "Cancel"
    static let deleteConfirm = "Delete recording"
    static let deleteDone = "Recording deleted"

    // MARK: - Every recording

    static let deleteAll = "Delete all recordings"
    static let deleteAllTitle = "Delete every recording?"
    static let deleteAllBody = "Every recording, transcript and set of meeting notes on this workspace goes, "
        + "and none of it can be recovered. A recording still in progress is left alone."
    static let deleteAllCancel = "Cancel"
    static let deleteAllConfirm = "Delete all recordings"
    static let deleteAllFieldLabel = "Type delete to confirm"
    static let deleteAllFieldHint = "This is the only control that removes all of them at once."

    /// ⛔ THE WORD IS LOWER-CASE `delete`, MATCHED EXACTLY AFTER TRIMMING, AND IT IS
    /// CASE-SENSITIVE. The web holds `DELETE_ALL_CONFIRMATION` and
    /// gates the button on `confirmation.trim() !== DELETE_ALL_CONFIRMATION`. ⚠️ It
    /// is NOT the workspace name.
    /// ⚠️ iOS autocapitalisation will offer "Delete" for it. The field that reads
    /// this has to turn that off or the gate is unsatisfiable on a phone.
    static let deleteAllConfirmation = "delete"

    /// ⛔ A PARTIAL FAILURE IS A **200** AND THIS IS THE ONLY PLACE IT IS REPORTED.
    /// `recordings.deleteAll` deletes per object and tallies; nothing about the
    /// status changes when some of them do not go. On a surface whose whole purpose
    /// is data removal, "all deleted" over a non-zero `failed` is the worst
    /// available wrong answer.
    static func deleteAllPartial(deleted: Int, failed: Int) -> String {
        "\(deleted) deleted, \(failed) could not be deleted. Try again in a minute."
    }

    static func deleteAllDone(_ deleted: Int) -> String {
        "\(deleted) \(deleted == 1 ? "recording" : "recordings") deleted"
    }
}
