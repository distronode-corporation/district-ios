import Foundation

/// The composer draft's answer to process death.
///
/// ⛔ A SIBLING FILE RATHER THAN ANOTHER TWENTY LINES OF `ThreadModel.swift`, AND THE
/// REASON IS A GATE RATHER THAN TASTE. That file runs close to the 500 lines
/// `swiftlint --strict` allows (`file_length` warns at 500 and every warning is an
/// error in CI), so the rationale below does not fit there; `ThreadAttachments.swift`
/// exists for the same reason, and the pressure is recurring rather than resolved.
/// The alternative is a one-line method with no explanation of a rule that is easy to
/// get wrong, which is the trade this codebase does not make. ``ThreadModel/autosaveTask``
/// and ``ThreadModel/persistDraft(_:)`` are not `private` for this and nothing else;
/// App is one module and there is no second reader.
extension ThreadModel {
    /// Persist the composer NOW, without waiting the debounce out.
    ///
    /// ⛔ THE PROCESS-DEATH HALF OF THE DRAFT, AND IT IS A FLUSH RATHER THAN A SECOND
    /// STORE. The window it closes is the up-to-two-seconds between the last keystroke
    /// and the timer: iOS suspends a backgrounded app and can kill it without running
    /// another line of this process, so a debounce that has not fired never will.
    /// ``ThreadView`` calls this when the scene stops being active, which on iOS means
    /// `.inactive` (the app switcher, Control Centre, an incoming call) before
    /// `.background`, so the write ordinarily starts while the app is still fully
    /// scheduled. It is what Android gets from `SavedStateHandle`, whose write happens
    /// at the same point in that platform's lifecycle.
    ///
    /// ⛔ AND IT IS NOT A SECOND SOURCE OF TRUTH, WHICH IS WHY IT IS THIS AND NOT
    /// `@SceneStorage`. It writes the SAME server draft row ``ThreadModel/persistDraft(_:)``
    /// already writes, so after a relaunch there is exactly one stored draft and
    /// ``ThreadModel/restoreDraft()``'s existing rule is still the whole rule: THE SERVER
    /// ROW WINS on restore, adopted only into an empty composer. A `@SceneStorage` mirror
    /// would be a second durable copy of the same text with no way to say which is
    /// fresher, because a colleague can edit that draft from another device while this
    /// one is dead, and arbitrating between them would mean inventing a clock this client
    /// does not have (see the ⚠️ on ``MessageDraft/updatedAt``: it owns no date parsing).
    ///
    /// ⚠️ VERY LIKELY, NOT GUARANTEED, AND SAYING SO IS THE POINT. A backgrounding app
    /// has an unpromised amount of runtime and this deliberately takes out no background
    /// task assertion to extend it; if the write does not land, the fallback is the
    /// draft the previous autosave persisted. Nothing awaits
    /// this from the UI and nothing should.
    ///
    /// ⚠️ IT CAN SPEND ONE REDUNDANT WRITE, AND THAT IS THE ACCEPTED PRICE OF NOT
    /// TRACKING A SECOND PIECE OF STATE. ``ThreadModel/autosaveTask`` is left set after
    /// its own debounce completes, so a background that follows an already-saved edit
    /// writes the identical bytes once more. It is one of the workspace's 60 writes/min,
    /// it happens at most once per edit because the task is cleared here, and a
    /// dirty-flag beside the task would be a second thing that can disagree with the
    /// first. ⚠️ A thread nobody has typed in costs nothing at all: the task is nil.
    func flushDraft() async {
        guard autosaveTask != nil else { return }
        // ⛔ CANCELLED BEFORE THE WRITE, for the reason `finishSend()` cancels it: a timer
        // firing afterwards would re-send the same bytes and spend a second slot of the
        // workspace's shared budget.
        autosaveTask?.cancel()
        autosaveTask = nil
        await persistDraft(composerText)
    }
}
