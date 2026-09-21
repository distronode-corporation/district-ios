import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation

/// Minimal, VALID bodies for the automation monitor, shared by
/// `WorkflowsRepositoryTests` and `CampaignRepositoryTests`.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-workflow*.json` and
/// `district-campaign-*.json` pin the wire shape through the strict gate; what lives
/// here is the smallest body that satisfies the Swift type, so those tests can be
/// about outcomes, paths and request bytes rather than about JSON.
///
/// ⚠️ INTERNAL RATHER THAN `private` BECAUSE THE TWO SUITES ARE IN SEPARATE FILES,
/// and they are separate because SwiftLint's 500-line file ceiling is an error under
/// `--strict`. One repository, two suites, one set of bodies.
enum WorkflowBodies {
    /// ⛔ BOTH ROLLUP BRANCHES AND BOTH SWITCH STATES. Row 1 has never fired, which is
    /// an explicit null rather than an omitted key and is the commonest row there is.
    static let list = #"""
    {"success":true,
     "workflows":[
       {"id":"wf_a","name":"Missed-call follow-up","active":true,
        "trigger":"call_ended_unanswered","createdAt":"2026-08-18T10:00:00.000Z",
        "latestRun":{"status":"success","startedAt":"2026-08-18T11:30:00.000Z"}},
       {"id":"wf_b","name":"New contact welcome","active":false,
        "trigger":"contact_created","createdAt":"2026-08-01T09:00:00.000Z",
        "latestRun":null}]}
    """#

    /// ⛔ A HEALTHY RUN AND THE ONE THAT FAILED BEFORE ANY ACTION RAN. The second has an
    /// EMPTY `actionResults`, a run-level `error` and a null `finishedAt` together,
    /// which is the shape a screen showing only per-action rows renders as an
    /// unexplained failure.
    ///
    /// ⚠️ `limit` IS 4 WHILE THE TESTS REQUEST 50, deliberately: the server clamps and
    /// echoes what it applied, and the echo is what a caller must page from.
    static let runs = #"""
    {"success":true,
     "runs":[
       {"id":"run_ok","workflowId":"wf_a","trigger":"call_ended_unanswered","status":"success",
        "startedAt":"2026-08-18T11:30:00.000Z","finishedAt":"2026-08-18T11:30:00.700Z",
        "actionResults":[{"type":"send_sms","outcome":"ok"}],"error":null},
       {"id":"run_failed","workflowId":"wf_a","trigger":"call_ended_unanswered","status":"failed",
        "startedAt":"2026-08-17T16:40:00.000Z","finishedAt":null,
        "actionResults":[],"error":"notify_ops webhook returned 502"}],
     "total":9,"limit":4,"offset":0,"hasMore":true}
    """#

    static let campaignRunning = #"""
    {"success":true,"campaign":{"infiniteSdrEnabled":true,"sdrBatchSize":25,
     "sdrCampaignGoal":"Book demos with lapsed trials"}}
    """#

    /// ⛔ THE UNCONFIGURED STATE: the flag false and both configuration fields null.
    /// Not an error, not an empty response, and not a zero batch size.
    static let campaignEmpty = #"""
    {"success":true,"campaign":{"infiniteSdrEnabled":false,"sdrBatchSize":null,
     "sdrCampaignGoal":null}}
    """#

    /// ⛔ THE POST-PAUSE STATE, and the two fields the request never mentioned are
    /// still there. That is what distinguishes `campaign-status` from
    /// `campaign-settings`, which would have wiped the goal and reset the size to 1.
    static let campaignPaused = #"""
    {"success":true,"campaign":{"infiniteSdrEnabled":false,"sdrBatchSize":25,
     "sdrCampaignGoal":"Book demos with lapsed trials"}}
    """#

    static let campaignNotAffirmed = #"""
    {"success":false,"campaign":{"infiniteSdrEnabled":false,"sdrBatchSize":null,
     "sdrCampaignGoal":null}}
    """#

    static let missingWorkflowId = #"{"success":false,"error":"workflowId is required"}"#
    static let workspaceNotFound = #"{"success":false,"error":"Workspace not found"}"#
    static let notABoolean = #"{"success":false,"error":"infiniteSdrEnabled must be a boolean"}"#

    /// The 403 both writes answer for a `viewer`, and the two failures every call has to
    /// keep distinct from it.
    static let forbidden = #"{"success":false,"error":"Forbidden"}"#
    static let unauthorized = #"{"error":"Unauthorized"}"#
    static let degraded = #"{"success":false,"error":"Try again"}"#
}
