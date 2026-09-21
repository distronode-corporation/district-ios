import DistrictData
import DistrictModel
import Foundation
import Observation

/// Deleting one recording, or every recording this tenancy holds.
///
/// ⛔ ONE MODEL FOR BOTH, AND THE TYPED CONFIRMATION IS WHAT SEPARATES THEM. They
/// share a failure mapping and a busy flag and differ in exactly one thing: the
/// bulk delete cannot be committed until the word has been typed back. Splitting
/// them would duplicate the first two and leave the third somewhere a second
/// screen could forget it.
///
/// ⛔ A PARTIAL FAILURE IS A **200**. `recordings.deleteAll` deletes per object and
/// tallies, and nothing about the status changes when some of them do not go — so
/// ``SchedulingRecordingsDeleted/failed`` is read and reported, and a non-zero one
/// is a ``SchedulingWritesBState/failed(_:)`` rather than a success. On a surface
/// whose whole purpose is data removal, "all deleted" over a non-zero `failed` is
/// the worst available wrong answer.
///
/// ⚠️ NEITHER OP ECHOES ANYTHING USEFUL, so the list a screen is holding is stale
/// on return. ``onDeleted`` is the signal to re-read; this model does not hold a
/// list and must not be asked to keep one.
@MainActor
@Observable
final class SchedulingRecordingDeleteModel {
    private(set) var state: SchedulingWritesBState = .idle
    private(set) var confirmation = ""

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let onDeleted: () -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        onDeleted: @escaping () -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.onDeleted = onDeleted
    }

    var busy: Bool {
        state.isWorking
    }

    /// ⛔ TRIMMED, THEN COMPARED FOR EXACT EQUALITY, CASE-SENSITIVELY, AGAINST THE
    /// LOWER-CASE WORD. That is the web recordings table's gate byte for byte.
    /// ⚠️ iOS offers "Delete" for it through autocapitalisation, so the field that
    /// feeds this MUST turn capitalisation off or the gate is unsatisfiable on a
    /// phone. Lower-casing here instead would be quietly weakening a confirmation
    /// the web makes people get right.
    var canDeleteAll: Bool {
        !busy && confirmation.trimmingCharacters(in: .whitespacesAndNewlines)
            == SchedulingRecordingWriteCopy.deleteAllConfirmation
    }

    func editConfirmation(_ value: String) {
        confirmation = value
        if case .failed = state {
            state = .idle
        }
    }

    func delete(recordingId: String) async {
        guard !busy else { return }
        state = .working
        do {
            _ = try await admin.deleteRecording(workspaceId: workspaceId, recordingId: recordingId)
            state = .done(SchedulingRecordingWriteCopy.deleteDone)
            onDeleted()
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    /// ⚠️ RE-CHECKS THE TYPED WORD RATHER THAN TRUSTING A DISABLED BUTTON. A
    /// view-only guard is not something anything else can make a claim about, and
    /// this is the most destructive operation on the surface. Same rule the admin
    /// console's workspace delete follows.
    ///
    /// ⛔ ``onDeleted`` FIRES ON A PARTIAL FAILURE TOO. Rows DID go; a screen that
    /// only re-read on a clean success would keep showing recordings that no longer
    /// exist beside a sentence saying some of them could not be deleted.
    func deleteAll() async {
        guard canDeleteAll else { return }
        state = .working
        do {
            let tally = try await admin.deleteAllRecordings(workspaceId: workspaceId)
            if tally.failed > 0 {
                state = .failed(FailureText(
                    message: SchedulingRecordingWriteCopy.deleteAllPartial(
                        deleted: tally.deleted,
                        failed: tally.failed
                    ),
                    action: .retry
                ))
            } else {
                state = .done(SchedulingRecordingWriteCopy.deleteAllDone(tally.deleted))
                confirmation = ""
            }
            onDeleted()
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }
}
