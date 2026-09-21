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

/// The recording, whose URL is resolved at the moment of playback.
enum CallRecordingState {
    case idle
    case resolving
    /// ⚠️ Ordinary for a missed call, so it reads as a fact rather than an error.
    case absent
    case failed(FailureText)
}

/// One call in full: the row, its transcript on demand, and a recording URL resolved
/// only at playback.
///
/// ⚠️ IT FETCHES BY ID RATHER THAN RECEIVING THE ROW, which is what makes the screen
/// survive process death and be openable from a push notification, where an id is all
/// the app has. See the ⚠️ on ``CallsRepository/detail(workspaceId:callId:)``.
@MainActor
@Observable
final class CallDetailModel {
    private(set) var state: CallDetailState = .loading
    private(set) var transcript: CallTranscriptState = .idle
    private(set) var recording: CallRecordingState = .idle

    private let calls: CallsRepository
    private let workspaceId: String
    private let callId: String

    init(container: AppContainer, workspaceId: String, callId: String) {
        calls = container.calls
        self.workspaceId = workspaceId
        self.callId = callId
    }

    /// ⚠️ Whether a recording is worth OFFERING, from the row we already have, so the
    /// screen does not show a play button that resolves to a 404. Not authoritative:
    /// an archived copy lives under a key this shape does not expose, so the server
    /// can still produce a URL when this is false. Erring toward offering it is the
    /// friendlier mistake.
    var mayHaveRecording: Bool {
        guard case let .content(call) = state else { return false }
        return call.recordingUrl != nil
    }

    func load() async {
        state = .loading
        transcript = .idle
        recording = .idle
        switch await calls.detail(workspaceId: workspaceId, callId: callId) {
        case let .success(call):
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

    /// Resolve a playable URL and hand it back.
    ///
    /// ⛔ RESOLVED AT THE MOMENT OF PLAYBACK AND NEVER STORED. The server redirects to
    /// a short-lived presigned object URL; a cached one expires and then fails inside
    /// whatever player received it, where the failure looks like a corrupt recording
    /// rather than a stale link. The returned value goes straight into the player and
    /// dies with the sheet: nothing here retains it, nothing writes the audio to disk,
    /// and there is no download or share affordance anywhere on this screen.
    ///
    /// ⛔ AND IT IS GUARDED AGAINST A DOUBLE TAP. The other client set `resolving` and
    /// then never checked it, so two taps resolved twice and opened two players, with
    /// the server issuing two presigned URLs for one deliberate action.
    func resolveRecording() async -> URL? {
        guard case .content = state else { return nil }
        guard case .idle = recording else { return nil }
        recording = .resolving

        switch await calls.recordingURL(workspaceId: workspaceId, callId: callId) {
        case let .success(location):
            guard let url = URL(string: location) else {
                // A 302 whose Location this client cannot parse is contract drift, not
                // an absence, so it must not read as "no recording".
                recording = .failed(Self.recordingFailure)
                return nil
            }
            recording = .idle
            return url
        case let .failure(error):
            // ⚠️ A 404 IS ORDINARY: a missed call has no recording. Everything else is
            // a failure and gets the failure sentence.
            recording = error.httpStatus == 404 ? .absent : .failed(Self.recordingFailure)
            return nil
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

    private static let recordingFailure = FailureText(
        message: "Could not open the recording.",
        action: .none
    )
}
