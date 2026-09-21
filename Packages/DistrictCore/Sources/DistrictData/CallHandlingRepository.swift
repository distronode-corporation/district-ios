import DistrictModel
import DistrictNetwork
import Foundation

/// Who answers a call, and whether the person asking can be rung at all.
///
/// ⛔ ITS OWN REPOSITORY RATHER THAN FOUR MORE METHODS ON ``WorkspaceRepository``,
/// AND THE SEAM IS THE SCOPE RATHER THAN THE PATH PREFIX. Both routes sit under
/// `/api/district/workspace/`, so grouping by URL would put them there — but
/// `availability` is not a workspace setting at all: it reads and writes the
/// CALLER'S OWN membership row, and the PATCH takes no email and no user id to do
/// it with. Filing it beside the wholesale-replace config writes is how someone
/// later adds a `userId` parameter "for symmetry" and turns a personal toggle into
/// a way to set a colleague's availability.
///
/// ⛔ AND NEITHER OF THESE WRITES REPLACES A STORED ARRAY, WHICH IS THE OTHER HALF
/// OF THE SEAM. Every save on ``WorkspaceRepository``'s config surface carries the
/// obligation to be built on a successful read, because an empty form saved through
/// one of them DELETES a transfer directory or a tool allowlist. These two write
/// scalars: the PATCH accepts either field alone, a failed read is a blank screen
/// rather than a live deletion, and both PATCHes ECHO the new values so no re-read
/// is needed. Those are different rules, and a reader should not have to work out
/// which set applies to the method in front of them.
///
/// ⚠️ A `struct` OVER THE ONE ``ApiClient``, like every other repository here. It
/// holds no state and no credential; the client carries both.
public struct CallHandlingRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Read how this workspace answers a call.
    ///
    /// ⛔ THE VALUES ARE ALREADY NORMALISED AND THIS DELIBERATELY DOES NOT
    /// NORMALISE THEM AGAIN. The route resolves an unrecognised stored mode to
    /// `ai_first` and clamps a stored ring into 5...30 before answering, so that a
    /// client never has to hold an opinion about a value written by an older build.
    /// A second clamp here would be a second opinion about a settled question, and
    /// the first thing it would break is a mode added server-side.
    ///
    /// ⚠️ IT ADMITS `viewer` WHILE THE WRITE DOES NOT, which is the OPPOSITE split
    /// from `workspace/config` (whose read excludes viewers because it carries
    /// staff transfer numbers). Nothing here is a phone number, so the screen shows
    /// a viewer the real setting read-only rather than being hidden.
    public func callHandling(workspaceId: String) async -> Result<CallHandlingResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.callHandling(workspaceId: workspaceId),
            as: CallHandlingResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("CallHandlingResponse", $0.success, $0) }
    }

    /// Change who answers, or how long the app rings.
    ///
    /// ⛔ AT LEAST ONE FIELD IS REQUIRED AND AN EMPTY BODY IS A **400**, not a
    /// no-op. Both parameters are optional because the route accepts either alone,
    /// which is what lets a picker and a stepper save independently; `nil, nil` is
    /// refused HERE rather than spent on a round trip, because a 400 whose cause is
    /// "the client sent nothing" is a client bug and must not reach an operator as
    /// a refusal they could act on.
    ///
    /// ⛔ AN UNKNOWN MODE IS A **400**, NOT A COERCED VALUE, so a mode this build
    /// does not know is refused here too. The asymmetry with the read above is
    /// deliberate and is the server's: what is STORED must stay displayable, and
    /// what ARRIVES must be told it is wrong.
    ///
    /// ⚠️ THE RESPONSE IS THE NEW BASELINE. This is the first write on the
    /// workspace surface that echoes what it wrote, so unlike `saveTools` and its
    /// siblings there is a body to adopt and no re-read to get wrong.
    public func saveCallHandling(
        workspaceId: String,
        callHandling: String?,
        appRingSeconds: Int?
    ) async -> Result<CallHandlingResponse, ApiError> {
        guard callHandling != nil || appRingSeconds != nil else {
            return .failure(.decoding("saveCallHandling was given neither field, which the route answers 400"))
        }
        if let callHandling, !CallHandling.isKnown(callHandling) {
            return .failure(.decoding("saveCallHandling was given an unknown mode: \(callHandling)"))
        }
        if let appRingSeconds, appRingSeconds != CallHandling.clampRing(appRingSeconds) {
            return .failure(.decoding("saveCallHandling was given \(appRingSeconds)s, outside 5...30"))
        }
        let outcome = await client.send(
            DistrictEndpoints.saveCallHandling(
                workspaceId: workspaceId,
                callHandling: callHandling,
                appRingSeconds: appRingSeconds
            ),
            as: CallHandlingResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("CallHandlingResponse", $0.success, $0) }
    }

    /// Whether the caller can be rung for this workspace's calls.
    ///
    /// ⛔ A VIEWER GETS A **200** CARRYING `false` AND `reason: "role"`, NOT A 403.
    /// So a success here does not mean "you have a toggle"; it means "here is the
    /// answer, and here is why". A screen that read only `availableForCalls` would
    /// draw a live switch for someone the server will never ring.
    ///
    /// ⚠️ `reason` IS ALWAYS PRESENT ON THE WIRE and is an explicit `null` on the
    /// ordinary path — see the ⛔ on ``AvailabilityResponse/reason``.
    public func availability(workspaceId: String) async -> Result<AvailabilityResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.availability(workspaceId: workspaceId),
            as: AvailabilityResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("AvailabilityResponse", $0.success, $0) }
    }

    /// Make the caller available, or not.
    ///
    /// ⛔ IT WRITES THE CALLER'S OWN ROW AND THERE IS NO PARAMETER FOR WHOSE. Never
    /// add one: an identity that arrives as an argument is an identity the caller
    /// chose. The server takes it from the verified session and nothing else.
    ///
    /// ⛔ **409 IS NOT A VALIDATION FAILURE AND NOT A PERMISSION FAILURE.** It means
    /// there is no `WorkspaceMember` row to write, because the person holds their
    /// role through the owner fallback — the read-side twin of
    /// ``AvailabilityReason/noMemberRow``. The status reaches the caller intact so
    /// that sentence can be shown instead of a shrug; the route does not create a
    /// row and neither may this.
    public func saveAvailability(
        workspaceId: String,
        availableForCalls: Bool
    ) async -> Result<AvailabilityResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.saveAvailability(
                workspaceId: workspaceId,
                availableForCalls: availableForCalls
            ),
            as: AvailabilityResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("AvailabilityResponse", $0.success, $0) }
    }
}
