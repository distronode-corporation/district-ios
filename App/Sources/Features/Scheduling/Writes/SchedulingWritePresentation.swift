import Foundation

/// One write model on its way into a sheet.
///
/// ⛔ `sheet(item:)` RATHER THAN `sheet(isPresented:)`, WHICH IS WHY THIS EXISTS AT
/// ALL. Every write model on this surface is built fresh at the moment the control
/// is pressed — it captures the row it edits and the callback that refreshes the
/// screen behind it — and `isPresented` would need the model to be stored first and
/// read back inside the builder, where a nil is a blank sheet rather than a compile
/// error. `item:` carries the model INTO the builder, so a sheet cannot be presented
/// without one.
///
/// ⚠️ THE IDENTITY IS A FRESH `UUID` AND NEVER THE MODEL'S OWN. Two presses of the
/// same control must present twice, and an identity derived from the edited row
/// would be deduplicated by SwiftUI on the second press — the same rule
/// ``SchedulingRecordingPlayback`` and ``SchedulingHandOff`` state for a URL.
struct SchedulingWritePresentation<Model>: Identifiable {
    let id = UUID()
    let model: Model
}
