import DistrictModel
import DistrictNetwork
import Foundation

/// The dashboard landing screen.
public struct OverviewRepository: Sendable {
    /// ⚠️ INTERNAL RATHER THAN `private`, only so `OverviewRepository+Setup.swift` can
    /// reach it: `private` is file scope in Swift. Same call ``InboxRepository`` made.
    let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// The overview for one workspace.
    ///
    /// ⛔ THE ENVELOPE GUARD IS THE WHOLE REASON THIS IS A REPOSITORY AND NOT A
    /// BARE CALL, AND TYPING THE RESPONSE DID NOT RETIRE IT. `OverviewResponse`
    /// requires six keys, so an empty `{}` no longer decodes — but a body that
    /// carries all six and says `success: false` still would, and it would render
    /// as FOUR CONFIDENT ZEROS: a workspace that took a hundred calls this week
    /// reported as one that took none, with nothing anywhere reporting a problem.
    /// ``ResponseEnvelope/affirm(_:_:_:)`` is what makes that a failure.
    ///
    /// ⛔ AND THE SERVER HAS THE SAME TRAP ONE LAYER DOWN: these metrics read
    /// FORCE-RLS tables and, outside a workspace transaction, come back as four
    /// zeros with HTTP 200. Branch on this `Result`, never on whether the numbers
    /// look populated.
    ///
    /// - Parameter workspaceId: ⚠️ PASS IT. Nil is legal and makes the SERVER
    ///   choose — it falls back to the first workspace of its own membership
    ///   listing — and this client holds no selection cookie, so on a
    ///   multi-workspace account the server's fallback silently reports on the
    ///   wrong one. ``OverviewResponse/workspaceId`` echoes what actually
    ///   answered, which is what catches a local selection that has drifted.
    public func overview(workspaceId: String?) async -> Result<OverviewResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.overview(workspaceId: workspaceId),
            as: OverviewResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("OverviewResponse", $0.success, $0) }
    }
}
