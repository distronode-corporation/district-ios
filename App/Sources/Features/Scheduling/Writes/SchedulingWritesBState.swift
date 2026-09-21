import DistrictData
import DistrictModel
import Foundation

/// What one scheduling-admin write is doing, and what it came to.
///
/// ⛔ A SUCCESS CARRIES A SENTENCE RATHER THAN BEING A BARE `saved`, BECAUSE TWO
/// OF THESE WRITES DO NOT HAVE ONE FIXED OUTCOME. `recordings.deleteAll` answers
/// a TALLY and a partial failure is a **200**, so "all deleted" is a sentence this
/// client has to compose from the numbers rather than one it may assume; the
/// reschedule names the new time because "Booking moved" alone does not let an
/// operator check they moved it to the day they meant. The web flashes exactly
/// these strings and they are ported rather than re-invented.
///
/// ⚠️ SEPARATE FROM ``SettingsSaveState`` DESPITE THE OVERLAP. That type carries
/// ``SettingsSaveState/savedButStale(_:)``, which exists because the workspace
/// settings routes echo nothing and every save is followed by a re-read. Nothing
/// on this surface works that way: these ops either answer the row they wrote or
/// answer nothing at all and hand the re-read to the screen that owns the list,
/// so a fourth case here would be a state no code path could reach.
enum SchedulingWritesBState {
    case idle
    case working
    /// The web's own flash for this op.
    case done(String)
    case failed(FailureText)

    var isWorking: Bool {
        if case .working = self {
            return true
        }
        return false
    }
}

/// ``SchedulingAdminError`` as a sentence, for every write on this surface.
///
/// ⛔ ONE MAPPING FOR THE WHOLE SURFACE, FOR ``FailureText``'S OWN REASON: two
/// screens that explained the same refusal differently would have the operator
/// reporting a bug against whichever they read second. The browser collapses the
/// same five codes, and the sentences below are that
/// collapse's wording rather than new copy.
///
/// ⛔ AND THE STATUS IS GONE BY THE TIME IT REACHES HERE, WHICH COSTS THIS CLIENT
/// THREE DISTINCTIONS THE WEB HAS. `SchedulingAdminRepository.error(forStatus:code:)`
/// answers ``SchedulingAdminError/unknown`` for a 400, a 404 AND for any 409 that
/// is not `scheduling_not_ready` — so `users.archive`'s four documented refusals
/// (409 upcoming bookings, 403 not the owner, 400 owner/already archived, 404
/// gone) are not separable here the way the web's `archiveRefusalSentence`
/// separates them. ⚠️ The answer is to ENUMERATE rather than to guess: see
/// ``SchedulingTeamWriteCopy/archiveRefused``, which names the possibilities
/// instead of asserting one. Inventing a status-specific sentence out of an
/// ``SchedulingAdminError/unknown`` would be this client stating as fact something
/// it was never told.
enum SchedulingWritesBFailure {
    /// ⚠️ TAKES `Error` RATHER THAN ``SchedulingAdminError`` because every call
    /// site is a `catch`, where the compiler only knows `any Error`. A throw this
    /// surface did not author lands on the honest generic rather than being
    /// force-cast.
    static func text(for error: Error) -> FailureText {
        guard let admin = error as? SchedulingAdminError else {
            return FailureText(message: genericMessage, action: .retry)
        }
        return text(for: admin)
    }

    static func text(for error: SchedulingAdminError) -> FailureText {
        switch error {
        case .transport:
            // ⚠️ The session is intact. Nothing here should imply otherwise — the
            // same sentence `FailureText.from(_:)` gives an `ApiError.transport`.
            FailureText(message: offlineMessage, action: .retry)
        case .decoding:
            // ⛔ CONTRACT DRIFT, NOT CONNECTIVITY, AND NEVER RETRYABLE. A second
            // attempt cannot change a response shape this build cannot parse.
            FailureText(message: staleBuildMessage, action: .none)
        case .invalidParams:
            // ⛔ THE FIELD NAMES ARE NOT SHOWN, AND THAT IS THE DTO'S OWN RULE
            // rather than terseness: `invalidParams` carries zod PATHS, which are
            // identifiers to look up and not prose. ⚠️ Every form here mirrors the
            // catalog's own limits, so reaching this arm means the two have
            // drifted — the app's problem to fix, not the operator's.
            FailureText(message: rejectedMessage, action: .none)
        case .forbidden:
            FailureText(message: forbiddenMessage, action: .none)
        case .notReady:
            FailureText(message: notReadyMessage, action: .none)
        case .unavailable:
            FailureText(message: unavailableMessage, action: .retry)
        case .unknown:
            FailureText(message: genericMessage, action: .retry)
        case let .failure(code):
            text(for: code)
        }
    }

    /// The scheduler's own refusal, at HTTP 200.
    ///
    /// ⚠️ ``SchedulingAdminFailureCode/slotTaken`` IS THE ONE ARM WHOSE RECOVERY IS
    /// "CHOOSE SOMETHING ELSE" RATHER THAN "TRY AGAIN", so it is the one arm that
    /// must not offer a retry: the identical request stays refused for as long as
    /// somebody else holds the slot.
    static func text(for code: SchedulingAdminFailureCode) -> FailureText {
        switch code {
        case .unavailable:
            FailureText(message: unavailableMessage, action: .retry)
        case .slotTaken:
            FailureText(message: slotTakenMessage, action: .none)
        case .forbidden:
            FailureText(message: forbiddenMessage, action: .none)
        case .notReady:
            FailureText(message: notReadyMessage, action: .none)
        case .unknown:
            FailureText(message: genericMessage, action: .retry)
        }
    }

    /// ⚠️ True for the one refusal a reschedule recovers from by RE-READING the
    /// slots rather than by telling the operator to try again. The web performs the
    /// same re-fetch; keeping the test here means the sheet does not have to
    /// pattern-match an error type it otherwise never touches.
    static func isSlotTaken(_ error: Error) -> Bool {
        guard let admin = error as? SchedulingAdminError else { return false }
        return admin.uiCode == .slotTaken
    }

    static let offlineMessage = "You appear to be offline. Check your connection and try again."
    static let staleBuildMessage = "This version of the app could not read that response. Please update."
    static let rejectedMessage = "The booking system refused those details. Please update the app."
    static let forbiddenMessage = "You can view this but not change it."
    static let notReadyMessage = "Scheduling is not set up for this workspace yet."
    static let unavailableMessage = "The booking system did not answer. Try again in a minute."
    static let slotTakenMessage = "That time was just taken. Pick another."
    static let genericMessage = "That did not save. Try again."
}
