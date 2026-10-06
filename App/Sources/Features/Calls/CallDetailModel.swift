import DistrictData
import DistrictModel
import Foundation
import Observation

/// One call, fetched by id.
enum CallDetailState {
    case loading
    case content(CallSummary)
    case failed(FailureText)
}

/// The transcript, which is fetched separately and only when asked for.
///
/// ⛔ `absent` IS A SUCCESS, NOT A FAILURE. The handler writes `call.transcript || ""`,
/// so `""` is the legitimate "nothing was said" answer and a nil check would never
/// fire; see the ⛔ on ``CallTranscriptResponse``.
enum CallTranscriptState {
    case idle
    case loading
    case loaded(String)
    case absent
    case failed(FailureText)
}

/// One call in full: the row and its transcript on demand.
///
/// ⚠️ NO RECORDING. Nothing is recorded in any region, and the server retired
/// `calls/{id}/recording` on 2026-10-03; `CallSummary.recordingUrl` still decodes and
/// is always null, and nothing reads it.
///
/// ⚠️ IT FETCHES BY ID RATHER THAN RECEIVING THE ROW, which is what makes the screen
/// survive process death and be openable from a push notification, where an id is all
/// the app has. See the ⚠️ on ``CallsRepository/detail(workspaceId:callId:)``.
@MainActor
@Observable
final class CallDetailModel {
    private(set) var state: CallDetailState = .loading
    private(set) var transcript: CallTranscriptState = .idle

    /// The live transcript, for a call that was in progress when it loaded; nil otherwise.
    ///
    /// ⚠️ MADE ONCE AND KEPT ACROSS A RELOAD of the same call, so a retry does not drop the
    /// lines already on screen or open a second socket.
    private(set) var live: LiveTranscriptModel?

    private let calls: CallsRepository
    private let workspaceId: String
    private let callId: String
    private let liveDependencies: @MainActor () -> LiveTranscriptModel.Dependencies

    init(container: AppContainer, workspaceId: String, callId: String) {
        calls = container.calls
        self.workspaceId = workspaceId
        self.callId = callId
        liveDependencies = { .live(container: container, workspaceId: workspaceId, callId: callId) }
    }

    func load() async {
        state = .loading
        transcript = .idle
        switch await calls.detail(workspaceId: workspaceId, callId: callId) {
        case let .success(call):
            let display = CallDisplay(call)
            if live == nil, display.transcribesLive {
                live = LiveTranscriptModel(workspaceId: workspaceId, callId: callId, dependencies: liveDependencies())
            }
            // ⚠️ EVERY LOAD IS A CALL-STATUS SIGNAL FOR THE LIVE TRANSCRIPT, the only one this
            // screen gets (contract §4.12 Q10): in progress, it may subscribe again after
            // `not_live`; no longer live, the call has ended. Ringing says nothing yet.
            if display.transcribesLive {
                live?.callShownInProgress()
            } else if !display.live {
                live?.callEnded()
            }
            state = .content(call)
        case let .failure(error):
            state = .failed(Self.detailFailure(error))
        }
    }

    /// Fetch the transcript.
    ///
    /// ⚠️ ON DEMAND, AND NOT TAKEN FROM THE ROW even though the row carries one.
    /// Transcripts are large enough that the contact timeline stopped embedding them,
    /// and one can be written after a call ends, so the row's copy is only as fresh as
    /// the request that loaded it.
    func loadTranscript() async {
        guard case .content = state else { return }
        // Already loading or resolved: re-fetching on every redraw would hammer the
        // endpoint.
        guard case .idle = transcript else { return }
        transcript = .loading

        switch await calls.transcript(workspaceId: workspaceId, callId: callId) {
        case let .success(text):
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .absent
                : .loaded(text)
        case let .failure(error):
            transcript = .failed(FailureText.from(error))
        }
    }

    /// ⛔ A 404 HERE DOES NOT IMPLY A MALFORMED ID. The server reads by id and checks
    /// ownership afterwards, so another tenant's call id is indistinguishable from one
    /// that never existed, and the server's own "Call not found" would be the wrong
    /// register for either. Nothing to retry, so nothing is offered.
    private static func detailFailure(_ error: ApiError) -> FailureText {
        guard error.httpStatus == 404 else { return FailureText.from(error) }
        return FailureText(message: "This call is not available.", action: .none)
    }
}
