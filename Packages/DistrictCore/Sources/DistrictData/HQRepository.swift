import DistrictModel
import DistrictNetwork
import Foundation

/// One turn's answer, and the change it proposes.
///
/// ⚠️ A NON-NIL ``pendingWrite`` MEANS NOTHING HAS BEEN WRITTEN. The answer text
/// usually says so too, because the system prompt requires it, but the AFFORDANCE
/// has to come from this field rather than from reading the prose: a screen that
/// looked for "I've proposed" in the sentence would miss the confirm button the
/// first time the model phrased it differently.
public struct HqAnswer: Sendable {
    public let answer: String
    /// ⛔ Non-nil means a change is waiting for permission.
    public let pendingWrite: HqPendingWrite?
}

/// The outcome of a confirmed write.
///
/// ⚠️ ``executed`` FALSE MEANS THE SERVER HANDLED THE REQUEST AND DECLINED THE
/// WRITE, which is not a failure of the call: a view-only role, or a tool that
/// refused internally. Rendering it as applied is precisely the lie the flag exists
/// to prevent, and rendering it as an error is the other wrong answer, because
/// nothing went wrong.
public struct HqConfirmation: Sendable {
    /// The tool the server says it applied, already checked against the approved
    /// one.
    public let tool: String
    /// ⛔ Whether the write took effect. See the ⚠️ on the type.
    public let executed: Bool
}

/// District HQ: ask a question, and apply a change the operator approved.
///
/// ⛔ THE TWO-STEP IS THE PRODUCT, NOT A CEREMONY, AND THIS LAYER'S JOB IS TO KEEP
/// IT HONEST IN BOTH DIRECTIONS. The model may only PROPOSE a write; nothing is
/// applied until ``confirm(workspaceId:pendingWrite:)`` is called with the proposal
/// echoed back. So a proposal that cannot be confirmed is reported as malformed
/// rather than shown, and a confirmation that came back describing a DIFFERENT
/// action than the one sent is reported as drift rather than as done.
///
/// ⛔ AND THE SIGNATURE IS WHAT ENFORCES IT. ``confirm(workspaceId:pendingWrite:)``
/// takes an ``HqPendingWrite``, which can only be obtained from a prompt response:
/// there is no overload taking a tool name and an argument object, deliberately,
/// because such an overload would let a caller assemble an action the operator never
/// read. The summary they DID read is attached to the same value, so the thing
/// confirmed and the thing described cannot come apart.
///
/// ⛔ NEITHER CALL IS IDEMPOTENT AND NEITHER IS RETRIED HERE. A prompt spends a
/// model turn and can propose a write; a confirm executes one, and a confirm that
/// timed out may well have executed already, so re-sending it deletes a second
/// contact or sends a second email. A failed confirm is surfaced to the operator,
/// who is the only party that can decide whether to repeat it.
///
/// ⚠️ STATELESS AND NON-STREAMING, so the client owns the transcript. History is
/// sent WHOLE and the server keeps the last six turns; trimming here would mean two
/// places deciding the same thing and disagreeing after a server change.
///
/// ⚠️ RATE LIMITED AT 30/MIN PER ACCOUNT, shared by both operations, so the 429 is
/// surfaced rather than absorbed.
public struct HQRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Ask District HQ something.
    ///
    /// ⚠️ ENVELOPE FIRST. Every response field a `{}` body could omit is either
    /// required or Optional here, so `{}` fails to decode on ``HqPromptResponse``'s
    /// `answer` alone; the envelope check is what catches the well-formed
    /// `success: false` that the route's catch branch produces on a 200 once the
    /// headers are written. Without it a handled failure reads as a turn whose
    /// answer happens to be a fabricated silence.
    ///
    /// - Parameter history: prior turns, oldest first, carried WHOLE as the
    ///   server's own turn objects. ⛔ The role vocabulary is `user` and `model`,
    ///   NOT `assistant`: the server feeds these straight into the model's content
    ///   list and DROPS any turn whose role is neither, silently, so a client using
    ///   the more usual word would lose half the conversation and be told nothing.
    public func ask(
        workspaceId: String,
        prompt: String,
        history: [JSONValue] = []
    ) async -> Result<HqAnswer, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.hqPrompt(workspaceId: workspaceId, prompt: prompt, history: history),
            as: HqPromptResponse.self
        )
        let affirmed = outcome.flatMap { ResponseEnvelope.affirm("HqPromptResponse", $0.success, $0) }
        switch affirmed {
        case let .success(response):
            return Self.answer(of: response)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Apply a proposed write.
    ///
    /// ⛔ IT EXECUTES A REAL WRITE: a persona change, a deletion, a routing
    /// replacement, an outbound campaign, or a real email or SMS to a customer. ⛔
    /// Nothing above this layer may retry it. A confirm that timed out may already
    /// have executed, and repeating it acts twice.
    ///
    /// ⛔ THE SERVER'S ECHO IS CHECKED RATHER THAN TRUSTED. The route echoes `tool`
    /// back precisely so the client can prove the applied action is the proposed
    /// one, and a mismatch is reported as contract drift rather than as success:
    /// "we applied something, but not what you approved" has no honest rendering,
    /// and treating it as done is how a deletion gets attributed to a persona edit.
    /// ⚠️ Compared EXACTLY, with no trimming and no case folding: both sides are
    /// machine-generated identifiers from a fixed catalog, so a difference in case
    /// or whitespace is drift and not a formatting variation to smooth over.
    ///
    /// ⚠️ `executed: false` IS NOT A FAILURE of this call. The request was handled
    /// and the write was declined, which the caller reports as "not applied" rather
    /// than "failed". See ``HqConfirmation``.
    ///
    /// ⚠️ A tool name that is not a genuine write tool answers **400**, not 403.
    /// The server refuses to let a crafted confirm body invoke a read tool. That
    /// cannot arise from this signature, which is the point of it.
    public func confirm(
        workspaceId: String,
        pendingWrite: HqPendingWrite
    ) async -> Result<HqConfirmation, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.hqConfirm(
                workspaceId: workspaceId,
                tool: pendingWrite.tool,
                args: Self.request(from: pendingWrite.args)
            ),
            as: HqConfirmResponse.self
        )
        let affirmed = outcome.flatMap { ResponseEnvelope.affirm("HqConfirmResponse", $0.success, $0) }
        switch affirmed {
        case let .success(response):
            guard response.tool == pendingWrite.tool else {
                return .failure(.decoding(
                    "HqConfirmResponse echoed a different tool than the one approved"
                ))
            }
            return .success(HqConfirmation(tool: response.tool, executed: response.executed))
        case let .failure(error):
            return .failure(error)
        }
    }

    /// ⛔ `needsConfirmation` WITHOUT A `pendingWrite` IS A MALFORMED RESPONSE, NOT
    /// AN ANSWER. It means the server said "the operator must confirm this" and then
    /// sent nothing to confirm. The tempting fallback, showing the answer and
    /// dropping the flag, is the worst option available: the model has just told the
    /// operator in prose that it proposed a change, and the screen would offer no
    /// way to apply it and no indication anything was missing. They read that as
    /// "done".
    ///
    /// ⚠️ THE MIRROR CASE IS DELIBERATELY NOT AN ERROR. A `pendingWrite` present
    /// WITHOUT the flag is treated as a proposal anyway: the payload is the
    /// substantive half and the flag is a summary of it, so trusting the payload
    /// fails toward ASKING rather than toward acting.
    private static func answer(of response: HqPromptResponse) -> Result<HqAnswer, ApiError> {
        if let pendingWrite = response.pendingWrite {
            return .success(HqAnswer(answer: response.answer, pendingWrite: pendingWrite))
        }
        guard response.needsConfirmation != true else {
            return .failure(.decoding(
                "HqPromptResponse set needsConfirmation with no pendingWrite to confirm"
            ))
        }
        return .success(HqAnswer(answer: response.answer, pendingWrite: nil))
    }

    /// Re-express a carried response value as a request value, losslessly.
    ///
    /// ⛔ THE TWO JSON TYPES ARE THE RECORDED DEBT AT THE FOOT OF `WireJSON.swift`,
    /// AND THIS IS THE ONE PLACE THE SEAM IS CROSSED. ``WireJSON`` is the
    /// response-side carrier and drops nothing; ``JSONValue`` is the request-side
    /// builder whose `object(_:)` factory drops nils, because an explicit null is a
    /// different instruction from an absent key on four of this API's routes.
    ///
    /// ⛔ SO THE MAPPING IS CASE BY CASE AND `.null` MAPS TO `.null`, NOT TO AN
    /// OMISSION. The proposal's arguments have to reach the server byte-identical to
    /// the ones the summary described, and a null the model chose is part of that
    /// instruction. `JSONValue.object(_:)`'s nil-dropping is not reached here
    /// because this builds the dictionary case directly.
    private static func request(from value: WireJSON) -> JSONValue {
        switch value {
        case let .string(text):
            .string(text)
        case let .integer(number):
            .integer(number)
        case let .number(number):
            .number(number)
        case let .bool(flag):
            .bool(flag)
        case let .array(values):
            .array(values.map(request(from:)))
        case let .object(fields):
            .object(fields.mapValues(request(from:)))
        case .null:
            .null
        }
    }
}
