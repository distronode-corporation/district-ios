import DistrictModel
import DistrictNetwork
import Foundation

// The `recordings.*` ops, as named methods.
//
// ⛔ THE LIST METHODS UNWRAP THEIR CONTAINER AND THE DELETE METHODS DO NOT. A
// caller wants the rows, so ``recordings(workspaceId:)`` answers
// `[SchedulingRecording]` rather than ``SchedulingRecordingList``; but
// `recordings.deleteAll` answers a TALLY whose second number is the whole point,
// so that one hands back the struct. Collapsing it to `deleted` would discard
// ``SchedulingRecordingsDeleted/failed`` at the layer least able to notice.
//
// ⚠️ `id` TRAVELS IN `params` EVEN THOUGH IT IS A PATH SEGMENT. The catalog's
// `pathKeys` strip happens SERVER-side, after `op.params` has validated the body
// — a client that removed it would fail that schema for a missing required field
// and get a 400 naming the very key it was being clever about.

public extension SchedulingAdminRepository {
    /// `recordings.list` — every recording, newest first.
    ///
    /// ⛔ NO PAGING EXISTS AT THE FAR END. The fork takes no query parameters and
    /// answers a LIMIT 200 window; a workspace past that cannot reach its older
    /// recordings through this op at all. That is a product limit to state on the
    /// screen, not something a client can page around.
    ///
    /// ⚠️ `viewer`-LEVEL, WHICH IS WIDER THAN THE DOWNLOAD BESIDE IT. A viewer may
    /// see that a recording exists and may not take a copy of a customer
    /// conversation away — see
    /// ``SchedulingAdminMediaRepository/recordingDownloadURL(workspaceId:recordingId:)``.
    /// A row drawn from this list must not assume its Play button will answer.
    func recordings(workspaceId: String) async throws -> [SchedulingRecording] {
        try await perform(
            .recordingsList,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingRecordingList.self
        ).recordings
    }

    /// `recordings.delete` — remove one recording and its object.
    ///
    /// ⚠️ ANSWERS NOTHING. The list a screen is holding is stale on return.
    func deleteRecording(workspaceId: String, recordingId: String) async throws -> SchedulingNoContent {
        try await perform(
            .recordingsDelete,
            workspaceId: workspaceId,
            params: .object([("id", .string(recordingId))]),
            as: SchedulingNoContent.self
        )
    }

    /// `recordings.deleteAll` — remove every recording this tenancy holds.
    ///
    /// ⛔ READ ``SchedulingRecordingsDeleted/failed`` AND SAY SO. A partial failure
    /// is a 200: the op deletes per object and tallies, and nothing about the
    /// status changes when some of them do not go. On a surface whose whole
    /// purpose is data removal, "all deleted" over a non-zero `failed` is the worst
    /// available wrong answer.
    func deleteAllRecordings(workspaceId: String) async throws -> SchedulingRecordingsDeleted {
        try await perform(
            .recordingsDeleteAll,
            workspaceId: workspaceId,
            params: .object([]),
            as: SchedulingRecordingsDeleted.self
        )
    }

    /// `recordings.consent` — who agreed to be recorded, and when.
    ///
    /// ⛔ RENDER WHAT IT SAYS AND FILL NO GAPS. These rows are the evidence for a
    /// two-party-consent jurisdiction. `pending` is a real and common state — the
    /// guest left before the prompt resolved — and is never "granted by default";
    /// an absent ``SchedulingRecordingConsent/decidedAt`` beside a decision means
    /// the decision has not been made.
    func recordingConsents(
        workspaceId: String,
        recordingId: String
    ) async throws -> [SchedulingRecordingConsent] {
        try await perform(
            .recordingsConsent,
            workspaceId: workspaceId,
            params: .object([("id", .string(recordingId))]),
            as: SchedulingRecordingConsents.self
        ).consents
    }
}
