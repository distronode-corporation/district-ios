import DistrictModel
import DistrictNetwork
import Foundation

/// The automation monitor: what is configured, whether it is on, and what it did.
///
/// ⛔ THREE INDEPENDENT READS BEHIND ONE SCREEN, AND THEY MUST NEVER SHARE A FAILURE
/// STATE. The workflow list, one workflow's run history and the SDR campaign status
/// hit three routes against two different data layers: the first two are RLS-scoped
/// reads on the regional database, the third is a region-resolved read of a
/// `Workspace` row that has RLS disabled by design. Folding them into one result
/// means a campaign read that failed would blank a workflow list that was answered
/// correctly, so each method reports its own outcome and the screen composes them.
///
/// ⛔ NO CACHE. This surface exists to answer "is the automation working right now",
/// which is the one question a stale answer is worst at. The run history in
/// particular is what somebody opens after a customer says they never got the
/// follow-up.
///
/// ⛔ TWO WRITES, NEITHER OF WHICH IS A GENERAL EDIT, AND THEY NEED OPPOSITE UI
/// DESIGNS FOR ONE REASON: what their replies carry.
/// ``setActive(workspaceId:workflowId:active:)`` answers a bare `{success:true}`, so
/// there is nothing to adopt and a toggle is optimistic-with-revert;
/// ``setCampaignEnabled(workspaceId:enabled:)`` answers the READ's whole shape from
/// the object it merged, so the truth arrives with the reply and the caller adopts
/// it. ⛔ There is no create, no edit and no delete for a workflow on this client at
/// all.
///
/// ⚠️ THE ROLE SPLIT ACROSS THESE FOUR ROUTES IS UNUSUAL: the list, the run history
/// and the campaign READ all admit `viewer`, while the toggle and the campaign
/// PATCH do not. That is what makes the screen present for every role with only its
/// controls gated, and the campaign path is the only verb split in this API.
public struct WorkflowsRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Every workflow, newest first.
    ///
    /// ⚠️ AN EMPTY LIST IS A LEGITIMATE ANSWER once `success` is affirmed: most
    /// workspaces have never created a workflow, so the caller renders an
    /// explanatory empty state rather than a failure.
    ///
    /// ⚠️ ENVELOPE-CHECKED FOR THE USUAL REASON AND WITH AN UNUSUALLY BAD FAILURE
    /// MODE. A required field rejects `{}`, but not a well-formed `success: false`
    /// from the route's catch branch, and on the automation monitor "we could not
    /// look" rendered as "you have no workflows" reads as "your automation was
    /// deleted".
    public func workflows(workspaceId: String) async -> Result<[WorkflowListItem], ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.workflows(workspaceId: workspaceId),
            as: WorkflowListResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("WorkflowListResponse", $0.success, $0) }
            .map(\.workflows)
    }

    /// One workflow's run history, newest first.
    ///
    /// ⛔ THE WHOLE ENVELOPE IS RETURNED BECAUSE THE PAGING FIELDS ARE PART OF THE
    /// ANSWER. `hasMore` is the SERVER's, computed from a real `total`, so
    /// end-of-list is known rather than inferred; and `limit`/`offset` are echoed as
    /// the server APPLIED them. A caller handed only the rows would have to
    /// re-derive both, and `runs.count < limit` disagrees with the server the moment
    /// a run is written between two requests.
    ///
    /// ⛔ `limit` AND `offset` ARE PASSED THROUGH UNCLAMPED, DELIBERATELY. The server
    /// clamps to 1...50 and replaces a non-numeric value rather than clamping it; a
    /// second clamp here would be a copy of a rule that lives elsewhere, and a
    /// drifted copy pages by a size the server never used, which either skips rows
    /// or repeats them on every "load more".
    ///
    /// ⚠️ `workflowId` IS REQUIRED SERVER-SIDE and its absence is a **400** rather
    /// than an unfiltered list, checked before the role guard even runs. It cannot be
    /// omitted from this signature.
    public func runs(
        workspaceId: String,
        workflowId: String,
        limit: Int,
        offset: Int
    ) async -> Result<WorkflowRunsResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.workflowRuns(
                workspaceId: workspaceId,
                workflowId: workflowId,
                limit: limit,
                offset: offset
            ),
            as: WorkflowRunsResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("WorkflowRunsResponse", $0.success, $0) }
    }

    /// Turn one workflow on or off.
    ///
    /// ⛔ THE ENVELOPE GUARD IS THE ENTIRE CONTENT CHECK, because the response has no
    /// content: a bare `{success:true}` with nothing about the row it wrote. So the
    /// only two outcomes are "the write landed" and "revert", and a caller that needs
    /// fresh state re-reads ``workflows(workspaceId:)``.
    ///
    /// ⛔ NOT RETRIED HERE, AND THE REASON IS THE MISSING ECHO RATHER THAN THE WRITE
    /// ITSELF. Setting one boolean on one row IS idempotent server-side, so a repeat
    /// would not corrupt anything; but the reply carries no state, so a retry cannot
    /// tell "the first one landed" from "neither did", and an automatic loop would
    /// hide a persistent failure behind a screen that looks settled. The honest
    /// recovery is a re-read, which is a decision for the caller.
    ///
    /// ⚠️ WHAT MAKES THAT SAFE IS THE DESCRIPTOR, NOT THIS METHOD. The same PATCH
    /// route also accepts `name`, `trigger`, `triggerMetadata` and `actions`, and
    /// `actions` is written WHOLESALE, so a body one field wider is one empty array
    /// away from deleting every action a workflow has, with a 200.
    /// ``DistrictEndpoints/setWorkflowActive(workspaceId:workflowId:active:)`` cannot
    /// express any of them.
    ///
    /// ⚠️ EXCLUDES `viewer` SERVER-SIDE, and the refusal is a plain role 403 with no
    /// machine-readable code, so it is indistinguishable from any other role refusal.
    /// The UI gates the control rather than relying on this.
    public func setActive(
        workspaceId: String,
        workflowId: String,
        active: Bool
    ) async -> Result<Void, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.setWorkflowActive(
                workspaceId: workspaceId,
                workflowId: workflowId,
                active: active
            ),
            as: SuccessResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("WorkflowToggleResponse", $0.success, $0) }
            .map { _ in }
    }

    /// Whether the always-on SDR campaign is running, and how it is configured.
    ///
    /// ⛔ RETURNS THE UNWRAPPED ``CampaignStatus``, WHICH IS THE POINT RATHER THAN A
    /// CONVENIENCE. ``CampaignStatusResponse/campaign`` is Optional only so a `{}`
    /// body can decode at all; the route always sends the object on a 200 because it
    /// normalises every field itself, and a workspace that has never opened the
    /// campaigns tab answers `{false, null, null}`. Handing a caller the Optional
    /// would make every screen re-decide what nil means, and the tempting answer is
    /// the wrong one: "paused, no batch size, no goal" is a confident claim about
    /// somebody's live outbound campaign made from a body that said nothing.
    ///
    /// ⚠️ SO A 200 WITH NO `campaign` IS REPORTED AS DRIFT, not as a state. ⚠️ And a
    /// **404** means the workspace id did not resolve, which is distinct again from
    /// "no campaign": that is a 200 with all three fields at their empty values.
    ///
    /// ⚠️ REGION-RESOLVED SERVER-SIDE. A ca/eu/apac workspace has no row in the hub,
    /// so a hub-only read would report every non-us tenant as having no campaign.
    /// ⚠️ Admits `viewer`, which is the whole reason this route exists rather than
    /// widening `workspace/config`.
    public func campaignStatus(workspaceId: String) async -> Result<CampaignStatus, ApiError> {
        await unwrapCampaign(DistrictEndpoints.campaignStatus(workspaceId: workspaceId))
    }

    /// Pause or resume the always-on SDR engine, and touch nothing else.
    ///
    /// ⛔ RETURNS THE POST-WRITE ``CampaignStatus`` AND THE CALLER IS EXPECTED TO
    /// ADOPT IT. The route answers in the READ's shape, derived from the object it
    /// just merged rather than re-read from a replica, so there is no window in which
    /// the client and the server disagree and no second request needed to close one.
    /// That is why this write is not optimistic the way ``setActive`` is: there the
    /// response carries nothing, so flip-and-revert is the only design available;
    /// here the truth arrives with the reply.
    ///
    /// ⚠️ IT IS IDEMPOTENT AND A CALLER MAY REPEAT IT, which is the one write on this
    /// surface where that is true and useful. The route spreads the stored Json and
    /// assigns one boolean, so sending the same value twice leaves the same state,
    /// and because the reply carries the post-write state a repeat also RE-ANSWERS
    /// the question rather than leaving the client guessing. ⛔ That is permission to
    /// let an operator press the control again, not permission to poll: nothing here
    /// may loop, because each call is still a write to a live campaign
    /// configuration.
    ///
    /// ⛔ AND IT GOES THROUGH `campaign-status`, WHICH MERGES. The three SDR fields
    /// live in one free-form Json column, and `campaign-settings` rebuilds all of
    /// them from its request body, so the same `{infiniteSdrEnabled:false}` sent
    /// there wipes the goal text and resets the batch size to 1, answering 200. Do
    /// not "simplify" the two writes onto one path.
    ///
    /// ⚠️ A NON-BOOLEAN `infiniteSdrEnabled` IS A 400 rather than a coercion, which
    /// is deliberate server-side: `Boolean("false")` is `true`, i.e. resuming a
    /// campaign somebody just paused. The parameter is non-optional here and cannot
    /// reach the nil-drop.
    ///
    /// ⚠️ EXCLUDES `viewer` while the read admits one. Watching a campaign and
    /// pausing one are different powers on the same path.
    public func setCampaignEnabled(
        workspaceId: String,
        enabled: Bool
    ) async -> Result<CampaignStatus, ApiError> {
        await unwrapCampaign(
            DistrictEndpoints.setCampaignEnabled(
                workspaceId: workspaceId,
                infiniteSdrEnabled: enabled
            )
        )
    }

    /// ⛔ SHARED BY THE READ AND THE WRITE ON PURPOSE, because they answer in the
    /// same shape and a second copy of this unwrapping is a second chance for one of
    /// them to render the empty campaign from a body that said nothing. That claim
    /// is worse coming from the WRITE path, where it would read as the state the
    /// operator just created.
    ///
    /// ⚠️ THE DIAGNOSTIC CARRIES NO BODY PREVIEW: this response holds a workspace's
    /// own outbound campaign goal, which is customer-facing copy rather than
    /// something to log. The only fact worth reporting is that the object was absent.
    private func unwrapCampaign(
        _ descriptor: ApiRequestDescriptor
    ) async -> Result<CampaignStatus, ApiError> {
        let outcome = await client.send(descriptor, as: CampaignStatusResponse.self)
        let affirmed = outcome.flatMap {
            ResponseEnvelope.affirm("CampaignStatusResponse", $0.success, $0)
        }
        switch affirmed {
        case let .success(response):
            guard let campaign = response.campaign else {
                return .failure(.decoding("CampaignStatusResponse carried no campaign"))
            }
            return .success(campaign)
        case let .failure(error):
            return .failure(error)
        }
    }
}
