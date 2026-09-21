import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// Who said one line of the transcript.
///
/// ⛔ ``wireRole`` IS NOT THE CASE NAME, AND THE MAPPING IS LOAD-BEARING. The route
/// replays history straight into the model's own content list, whose vocabulary is
/// `user` and `model`, and it DROPS any turn whose role is neither, silently. A client
/// that sent the more usual `assistant` would lose half the conversation and be told
/// nothing; the answers would simply stop following the thread. The cases are named for
/// the product and the wire keeps the model's words, because conflating the two is how
/// the mapping gets dropped as redundant.
enum HQSpeaker {
    /// The person at the keyboard.
    case person
    /// District HQ.
    case console

    var wireRole: String {
        switch self {
        case .person: "user"
        case .console: "model"
        }
    }
}

/// One line of the transcript.
///
/// ⛔ ``replayable`` IS FALSE FOR THE CLIENT'S OWN RECEIPTS ("Applied."), AND THAT FLAG
/// IS NOT COSMETIC. Those sentences are OUR bookkeeping rather than something either
/// party said; replaying one as a `model` turn would tell the model it had spoken words
/// it never spoke, on a route that feeds history straight into its content list. Android
/// draws the same distinction through `UiText.Literal` vs `UiText.Resource`; this client
/// has no localisation layer to lean on, so the flag is explicit.
///
/// ⚠️ `Identifiable` ON A FRESH `UUID` RATHER THAN ON THE TEXT. Two identical answers
/// are genuinely two lines, and a content-derived identity would collide and drop one.
struct HQMessage: Identifiable {
    let id = UUID()
    let speaker: HQSpeaker
    let text: String
    /// ⛔ See the ⛔ on the type. Defaults to true because everything except a receipt
    /// is something one of the two parties actually said.
    let replayable: Bool

    init(speaker: HQSpeaker, text: String, replayable: Bool = true) {
        self.speaker = speaker
        self.text = text
        self.replayable = replayable
    }
}

/// What the console is doing, independently of what it has said.
///
/// ⛔ IT CARRIES NO MESSAGES, DELIBERATELY. Folding the transcript into these cases
/// would mean every state held a copy of the list, and the failure branch is exactly
/// where one gets forgotten: a failed turn would render as an EMPTY console, throwing
/// away a conversation the operator is mid-way through and cannot recover, because the
/// route is stateless and the server holds none of it.
///
/// ⚠️ ONE ROUTE ANSWERS TWO SHAPES AND THEY ARE TWO CASES HERE. A plain answer settles
/// to ``idle``; a proposal settles to ``confirming(_:)`` and draws a card. Modelling it
/// as one state with an optional proposal is what produces a view full of `if let`s in
/// which the confirm affordance is the thing that goes missing.
enum HQConsoleState {
    case idle
    /// A prompt turn is running server-side.
    case thinking
    /// ⛔ A WRITE HAS BEEN PROPOSED AND NOTHING HAS BEEN APPLIED.
    case confirming(HqPendingWrite)
    /// The approved write is executing.
    case applying(HqPendingWrite)
    /// A prompt turn failed. The transcript is intact.
    case failed(FailureText)
    /// ⛔ A CONFIRM FAILED, AND THE PROPOSAL IS KEPT SO THE CARD STAYS ON SCREEN. The
    /// summary is the only record of what was attempted, and the operator is the only
    /// party that may decide to send it again. ⚠️ ``HQConsoleState/isAwaitingDecision``
    /// closes the composer over it, because sending any new prompt reassigns `state` and
    /// would take this case, and the write it records, with it.
    case confirmFailed(HqPendingWrite, FailureText)
}

extension HQConsoleState {
    /// The proposal this state is about, if any.
    ///
    /// ⚠️ DERIVED IN ONE PLACE rather than re-branched at each use: the card's presence
    /// is the operator's only signal that a change is pending, and three of these six
    /// states carry one.
    var pendingWrite: HqPendingWrite? {
        switch self {
        case let .confirming(pending): pending
        case let .applying(pending): pending
        case let .confirmFailed(pending, _): pending
        case .idle, .thinking, .failed: nil
        }
    }

    /// A failed PROMPT turn. ⚠️ Not a failed confirm: that one belongs on the card.
    var promptFailure: FailureText? {
        switch self {
        case let .failed(failure): failure
        case .idle, .thinking, .confirming, .applying, .confirmFailed: nil
        }
    }

    /// A failed CONFIRM, shown on the card beside the summary it was refused for.
    var confirmFailure: FailureText? {
        switch self {
        case let .confirmFailed(_, failure): failure
        case .idle, .thinking, .confirming, .applying, .failed: nil
        }
    }

    var isThinking: Bool {
        if case .thinking = self {
            return true
        }
        return false
    }

    var isApplying: Bool {
        if case .applying = self {
            return true
        }
        return false
    }

    /// ⛔ THE COMPOSER AND BOTH CARD BUTTONS ARE DISABLED ON THIS. A second prompt is a
    /// duplicated model run and two turns racing on one transcript interleave their
    /// appends; a second confirm is a second write, and the server offers no idempotency
    /// key.
    var isBusy: Bool {
        isThinking || isApplying
    }

    /// ⛔ A PROPOSAL IS ON SCREEN AND HAS NOT BEEN ANSWERED. It is NOT ``isBusy`` — the
    /// console is idle, waiting on the operator — and conflating the two is exactly the
    /// bug this property exists to close. `isBusy` is false in both `confirming` and
    /// `confirmFailed`, so a guard on it alone would let the next question replace the
    /// state and take the card, the summary and the ``HqPendingWrite`` with it.
    /// Unrecoverably: none of it is in the transcript, and
    /// ``HQRepository/confirm(workspaceId:pendingWrite:)`` accepts only a pending write
    /// obtained from a prompt response. The `confirmFailed` case matters most, because the
    /// obvious next question there ("did that actually go through?") is the very tap that
    /// would destroy the only record of what was attempted.
    var isAwaitingDecision: Bool {
        pendingWrite != nil
    }
}

/// The console: a transcript the client alone owns, and the confirm gate in front of
/// every write.
///
/// ⛔ THE CLIENT IS THE SOLE OWNER OF THE CONVERSATION. The route is stateless (no
/// session id, no server-side transcript) and it keeps only the last six turns of
/// whatever ``history()`` replays. So nothing here may quietly drop a turn, and a
/// failure must never blank the list.
///
/// ⛔ AND NOTHING HERE AUTO-RETRIES A CONFIRM. A confirm that timed out may already have
/// executed, so repeating it deletes a second contact or sends a second email. A failed
/// prompt is re-sendable on a press and a failed confirm is re-sendable on a press; what
/// is forbidden is either of them happening without one. See the ⛔ on ``HQRepository``.
///
/// ⚠️ TAKES THE CONTAINER, NEVER A REPOSITORY OR A CLIENT. ``AppContainer/hq`` is a
/// `let` built from the one ``ApiClient``; anything constructed here would reach a second
/// ``TokenRefreshCoordinator``.
@MainActor
@Observable
final class HQModel {
    private(set) var messages: [HQMessage] = []

    private(set) var state: HQConsoleState = .idle

    /// Whether to OFFER the confirm control.
    ///
    /// ⚠️ A BELT-AND-BRACES GATE THAT SHOULD NEVER FIRE. The server refuses a viewer's
    /// write inside the tool executor, BEFORE the confirmation gate, so a viewer's turn
    /// comes back as an ordinary answer with no proposal attached and there is nothing
    /// to confirm. This exists for the case where that ordering changes: a control that
    /// can only 403 is worse than an absent one. An affordance, never the authority.
    let canConfirm: Bool

    private let hq: HQRepository
    private let workspaceId: String

    /// The prompt whose turn has not been answered yet.
    ///
    /// ⚠️ HELD SO A FAILED TURN CAN BE RE-SENT WITHOUT RE-APPENDING THE OPERATOR'S
    /// MESSAGE. It is already in the transcript, and a retry that appended it again
    /// would show the question twice and then replay the duplicate as its own history.
    private var unansweredPrompt: String?

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        canConfirm = WorkspaceRole.allowsMutation(role)
        hq = container.hq
        self.workspaceId = workspaceId
    }

    /// Whether a new prompt may be sent.
    ///
    /// ⛔ THE SCREEN DISABLES THE COMPOSER ON THIS RATHER THAN LETTING ``ask(_:)``
    /// SWALLOW THE TAP. A guard alone would make Send a silent no-op, which is the same
    /// class of fault as the destruction it replaces: the operator learns nothing either
    /// way. ``HQCopy/composerBlocked`` is the sentence that goes with it, and both ways
    /// out of the state are one tap on the card directly above.
    var canAsk: Bool {
        !state.isBusy && !state.isAwaitingDecision
    }

    /// Ask a question, or ask for a change.
    ///
    /// ⛔ REFUSED WHILE A TURN IS IN FLIGHT. Every prompt runs a function-calling loop
    /// over the workspace's data, so a double tap is a duplicated model run, and two
    /// turns racing on the same transcript can interleave their appends and produce a
    /// conversation that never happened.
    ///
    /// ⛔ AND REFUSED WHILE A PROPOSAL IS UNANSWERED, WHICH IS A DIFFERENT REASON WITH A
    /// WORSE CONSEQUENCE. ``send(_:)`` assigns `state` unconditionally, so a prompt sent
    /// over a `confirming` or `confirmFailed` state does not queue behind the card, it
    /// DELETES it — and with it the summary, which is the only description of the change
    /// that was proposed and the only record of one that may already have executed. The
    /// operator declines a proposal with Dismiss, deliberately; they must not be able to
    /// do it by typing. See ``HQConsoleState/isAwaitingDecision``.
    ///
    /// ⚠️ A BLANK PROMPT IS REFUSED LOCALLY. The server answers 400, and spending a round
    /// trip to be told what the client can already see surfaces as a fault.
    func ask(_ prompt: String) async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canAsk else { return }
        messages.append(HQMessage(speaker: .person, text: text))
        unansweredPrompt = text
        await send(text)
    }

    /// Re-send the turn that failed.
    ///
    /// ⚠️ ONLY MEANINGFUL FROM ``HQConsoleState/failed(_:)``; anything else is a no-op so
    /// a stray tap cannot duplicate a turn that already succeeded.
    func retry() async {
        guard state.promptFailure != nil else { return }
        guard let text = unansweredPrompt else { return }
        await send(text)
    }

    /// Apply the proposed write.
    ///
    /// ⛔ THE PROPOSAL IS CARRIED STRAIGHT FROM THE ANSWER INTO THE CONFIRM AND IS NEVER
    /// REBUILT. ``HQRepository/confirm(workspaceId:pendingWrite:)`` takes an
    /// ``HqPendingWrite`` and nothing else precisely so the thing confirmed is provably
    /// the thing proposed: ``HqPendingWrite/summary`` is the only description the
    /// operator ever read, and a re-derived tool-and-arguments pair could differ from it
    /// invisibly.
    ///
    /// ⛔ REACHABLE FROM ``HQConsoleState/confirmFailed(_:_:)`` AS WELL AS FROM
    /// ``HQConsoleState/confirming(_:)``, AND THAT IS DELIBERATE RATHER THAN A WIDENED
    /// GUARD. A failed confirm may already have executed, so nothing may repeat it
    /// automatically, but the repository's own note says the operator is the only party
    /// who can decide whether to repeat it, and a Confirm button that is drawn and does
    /// nothing takes that decision away while appearing to offer it. The card's label
    /// changes to say it is a second attempt.
    func confirmPending() async {
        guard canConfirm, !state.isBusy else { return }
        guard let pending = state.pendingWrite else { return }

        state = .applying(pending)
        switch await hq.confirm(workspaceId: workspaceId, pendingWrite: pending) {
        case let .success(confirmation):
            // ⚠️ `executed` DECIDES THE WORDING, NOT `success`. A handled request that
            // declined the write must not read as applied, and must not read as an
            // error either: nothing went wrong.
            messages.append(HQMessage(
                speaker: .console,
                text: confirmation.executed ? HQCopy.applied : HQCopy.notApplied,
                replayable: false
            ))
            state = .idle
        case let .failure(error):
            // ⛔ THE CARD SURVIVES. The operator has to be able to see what was
            // attempted, and the decision to try again is theirs.
            state = .confirmFailed(pending, FailureText.from(error))
        }
    }

    /// Decline the proposed write.
    ///
    /// ⚠️ NOTHING IS SENT. The proposal was never applied, so declining it is purely
    /// local: there is no cancel endpoint, and calling one would imply the server was
    /// holding state it is not.
    func dismissPending() {
        switch state {
        case .confirming, .confirmFailed:
            state = .idle
        case .idle, .thinking, .applying, .failed:
            break
        }
    }

    // MARK: - Internals

    private func send(_ text: String) async {
        state = .thinking
        switch await hq.ask(workspaceId: workspaceId, prompt: text, history: history()) {
        case let .success(answer):
            unansweredPrompt = nil
            messages.append(HQMessage(speaker: .console, text: answer.answer))
            // ⛔ THE AFFORDANCE COMES FROM THE FIELD, NEVER FROM THE PROSE. The answer
            // usually says a change was proposed, but a screen that looked for that
            // sentence would miss the confirm button the first time it was phrased
            // differently.
            if let pending = answer.pendingWrite {
                state = .confirming(pending)
            } else {
                state = .idle
            }
        case let .failure(error):
            // ⛔ THE TRANSCRIPT IS UNTOUCHED, including the operator's unanswered
            // message. See the ⛔ on the class.
            state = .failed(FailureText.from(error))
        }
    }

    /// The turns to replay, oldest first.
    ///
    /// ⛔ EXCLUDES A TRAILING OPERATOR MESSAGE, because that message IS the prompt being
    /// sent. The route appends `prompt` to whatever `history` carries, so leaving it in
    /// would send the question twice in one request (once as context and once as the
    /// ask), and the model answers the duplicate as though it had been repeated.
    ///
    /// ⚠️ SENT WHOLE OTHERWISE. The server keeps the last six turns; trimming here as
    /// well would be two places deciding the same thing and disagreeing after a server
    /// change.
    private func history() -> [JSONValue] {
        var turns = messages.filter(\.replayable)
        if let last = turns.last, case .person = last.speaker {
            turns.removeLast()
        }
        return turns.map { message in
            JSONValue.object([
                "role": .string(message.speaker.wireRole),
                "text": .string(message.text),
            ])
        }
    }
}
