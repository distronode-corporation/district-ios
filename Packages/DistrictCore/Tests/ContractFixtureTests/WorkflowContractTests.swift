import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the automation monitor: the workflow list, one
/// workflow's run history, and the always-on campaign.
///
/// ⛔ THESE FIXTURES PIN A MONITOR, WHICH MAKES A DRIFTED FIELD FAIL DIFFERENTLY
/// FROM ANYWHERE ELSE IN THE CORPUS. Elsewhere a renamed key produces a screen that
/// will not load; here it produces a screen that loads and says the WRONG THING
/// about live automation: a green badge where a partial run happened, a switch
/// showing "on" for a workflow that is off, "no goal configured" for a campaign that
/// has one. Those are answers somebody acts on, so the value-level assertions below
/// matter more than the shape the gate already checks.
final class WorkflowContractTests: XCTestCase {
    // MARK: - The workflow list

    /// ⛔ BOTH `latestRun` BRANCHES AND BOTH `active` BRANCHES, IN ONE FIXTURE. A
    /// workflow that has never fired carries an explicit NULL rollup, which is the
    /// most ordinary row there is (one created five minutes ago), and a DTO regressed
    /// to non-null would throw on it. Having both `active` values is what stops the
    /// switch's state being pinned to a constant.
    ///
    /// ⛔ AND `latestRun` IS NOT A ``WorkflowRun``. The list route publishes two
    /// fields where the runs route publishes eight, so a client that modelled it as a
    /// run would assert `actionResults` on a payload that has never carried it.
    func testTheWorkflowListCoversBothRollupBranchesAndBothSwitchStates() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-workflows.json",
            as: WorkflowListResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.workflows.map(\.active), [true, false])

        let ran = try XCTUnwrap(response.workflows.first)
        XCTAssertEqual(ran.id, "wf_contract_active")
        XCTAssertEqual(ran.name, "Missed-call follow-up")
        XCTAssertEqual(ran.trigger, "call_ended_unanswered")
        XCTAssertEqual(ran.latestRun?.status, "success")
        XCTAssertEqual(ran.latestRun?.startedAt, "2026-08-18T11:30:00.000Z")

        let neverRan = try XCTUnwrap(response.workflows.last)
        XCTAssertEqual(neverRan.trigger, "contact_created")
        XCTAssertNil(neverRan.latestRun, "⛔ never fired, which is a state and not a failure")
    }

    /// ⛔ THE LIST IS A PROJECTION AND THE UNPUBLISHED COLUMNS ARE ASSERTED ABSENT ON
    /// THE RAW BYTES. `actions`, `triggerMetadata`, `workspaceId` and `updatedAt` are
    /// all on the Prisma row and none of them is published. This is the half that
    /// fails if a route ever starts spreading the row: `actions` in particular is
    /// written WHOLESALE by the same PATCH the toggle uses, so a client that learned
    /// to expect it would be one empty array from deleting every action a workflow
    /// has.
    func testAWorkflowRowIsSixKeysAndPublishesNoneOfTheStoredExtras() throws {
        let rows = try Self.array(in: "district-workflows.json", under: "workflows")

        for row in rows {
            XCTAssertEqual(
                Set(row.keys),
                ["id", "name", "active", "trigger", "createdAt", "latestRun"],
                "a workflow row grew or lost a key"
            )
        }
        // ⛔ The null is an explicit KEY on the never-fired row, not an omission: a
        // missing key would be indistinguishable from a stale client.
        XCTAssertTrue(rows[1].keys.contains("latestRun"))
    }

    // MARK: - One workflow's run history

    /// ⛔ ALL FOUR STATUSES IN ONE FIXTURE, AND `partial` IS THE REASON. It draws like
    /// a healthy run if it is toned wrong, and it means some actions ran and some did
    /// not, so a monitor that greened it would report a follow-up as sent when half of
    /// it was skipped.
    func testTheRunHistoryCoversAllFourStatuses() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-workflow-runs.json",
            as: WorkflowRunsResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.runs.map(\.status), ["success", "partial", "failed", "skipped"])
        XCTAssertEqual(response.runs.map(\.workflowId), Array(repeating: "wf_contract_active", count: 4))
    }

    /// ⛔ A SKIP'S `reason` IS THE MOST USEFUL FIELD ON THE ROW AND IS ABSENT ON AN
    /// `ok` ONE. "Skipped" alone tells an operator nothing they can act on; "contact
    /// has no email address" tells them exactly what to fix. ⚠️ Absent rather than
    /// null on the ok row, so a non-Optional would throw on the commonest shape there
    /// is, and that absence is asserted on the raw bytes because absent and null both
    /// decode to nil.
    func testASkippedActionCarriesItsReasonAndAnOkActionDoesNot() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-workflow-runs.json",
            as: WorkflowRunsResponse.self
        )
        let partial = try XCTUnwrap(response.runs.first { $0.id == "run_contract_partial" })

        XCTAssertEqual(partial.actionResults.map(\.type), ["send_sms", "send_email"])
        XCTAssertNil(partial.actionResults.first?.reason, "the ok row carries none")
        XCTAssertEqual(partial.actionResults.last?.outcome, "skipped")
        XCTAssertEqual(partial.actionResults.last?.reason, "contact has no email address")

        let rows = try Self.array(in: "district-workflow-runs.json", under: "runs")
        let partialActions = try XCTUnwrap(rows[1]["actionResults"] as? [[String: Any]])
        XCTAssertFalse(partialActions[0].keys.contains("reason"), "⛔ absent on ok, not null")
        XCTAssertTrue(partialActions[1].keys.contains("reason"))
    }

    /// ⛔ THE WHOLE-RUN ERROR WITH NO ACTION ROWS, WHICH IS THE MOST INFORMATIVE ROW IN
    /// THE FIXTURE. The engine can throw before any action executes, so this run has
    /// an EMPTY `actionResults`, a populated run-level `error` and a NULL `finishedAt`.
    /// A screen rendering only the per-action rows would draw it as a failure with no
    /// explanation whatsoever, and one treating `finishedAt` as a missing value rather
    /// than a state would show it as still running forever.
    ///
    /// ⚠️ AND `error` IS NULL ON THE OTHER THREE, including the `skipped` one. A
    /// skipped run is not a failed run: its actions declined for reasons of their own,
    /// carried per action rather than per run.
    func testAFailedRunCarriesARunLevelErrorWithNoActionsAndNoFinishTime() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-workflow-runs.json",
            as: WorkflowRunsResponse.self
        )
        let failed = try XCTUnwrap(response.runs.first { $0.id == "run_contract_failed" })

        XCTAssertTrue(failed.actionResults.isEmpty, "⛔ the engine threw before any action ran")
        XCTAssertEqual(failed.error, "notify_ops webhook returned 502")
        XCTAssertNil(failed.finishedAt, "⚠️ a state, not a missing value")

        for run in response.runs where run.id != "run_contract_failed" {
            XCTAssertNil(run.error, "\(run.id) did not fail as a whole")
            XCTAssertNotNil(run.finishedAt, "\(run.id) finished")
        }
    }

    /// ⛔ `hasMore` IS COMPUTED FROM A REAL `total`, NOT FROM A SHORT PAGE. A client
    /// re-deriving it as `runs.count < limit` would end the list early whenever a run
    /// was written between two requests, silently hiding history that exists. ⚠️ And
    /// `limit` is the value the server APPLIED: it clamps to 1...50 and REPLACES a
    /// non-numeric value rather than clamping it, so the echo is the only way a caller
    /// learns what it actually got.
    func testThePagingFieldsAreTheServersOwnAndSayThereIsMore() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-workflow-runs.json",
            as: WorkflowRunsResponse.self
        )

        XCTAssertEqual(response.total, 9)
        XCTAssertEqual(response.limit, 4, "as applied, not as requested")
        XCTAssertEqual(response.offset, 0)
        XCTAssertTrue(response.hasMore, "4 of 9")
        XCTAssertEqual(response.runs.count, 4, "a full page, so a short-page heuristic would agree here")
    }

    // MARK: - The always-on campaign

    /// The configured campaign: running, with a batch size and a goal.
    ///
    /// ⛔ THE STORED COLUMN IS FREE-FORM JSON AND THE ROUTE PUBLISHES EXACTLY THREE
    /// FIELDS. Asserted on the raw bytes, because a route that started spreading the
    /// object would ship every stored setting to a phone that asked for three, and the
    /// gate would pass it as an added key on a DTO nobody had updated.
    func testTheConfiguredCampaignPublishesExactlyThreeFields() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-campaign-status.json",
            as: CampaignStatusResponse.self
        )
        let campaign = try XCTUnwrap(response.campaign)

        XCTAssertTrue(campaign.infiniteSdrEnabled)
        XCTAssertEqual(campaign.sdrBatchSize, 25)
        XCTAssertEqual(campaign.sdrCampaignGoal, "Book demos with lapsed trials")

        let raw = try Self.object(in: "district-campaign-status.json", under: "campaign")
        XCTAssertEqual(
            Set(raw.keys),
            ["infiniteSdrEnabled", "sdrBatchSize", "sdrCampaignGoal"]
        )
    }

    /// ⛔ THE UNCONFIGURED CAMPAIGN IS A STATE, NEVER AN ERROR AND NEVER AN ABSENCE.
    /// This is every workspace that has never opened the campaigns tab, and the route
    /// NORMALISES absent and off into one rendering so that "we have no campaign" and
    /// "the campaign is off" are not two screens for the same thing.
    ///
    /// ⛔ AND NEITHER NULL MAY BE READ AS A ZERO OR AN EMPTY STRING. `sdrBatchSize` is
    /// null rather than 0 because the settings PATCH floors it to at least 1, so 0
    /// cannot be stored and rendering nil as 0 would state how many people a live
    /// outbound campaign calls from a field that said nothing.
    ///
    /// ⚠️ BOTH KEYS ARE SENT AS EXPLICIT NULLS rather than omitted, asserted on the raw
    /// bytes: that is what the two allowlist paths permit, and a client that
    /// distinguished absent from null would need to know which it is.
    func testTheUnconfiguredCampaignIsAStateWithBothFieldsExplicitlyNull() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-campaign-status-empty.json",
            as: CampaignStatusResponse.self
        )
        let campaign = try XCTUnwrap(response.campaign, "⛔ a state, so the object is still sent")

        XCTAssertFalse(campaign.infiniteSdrEnabled)
        XCTAssertNil(campaign.sdrBatchSize, "⛔ not configured, and not zero")
        XCTAssertNil(campaign.sdrCampaignGoal)

        let raw = try Self.object(in: "district-campaign-status-empty.json", under: "campaign")
        XCTAssertTrue(raw.keys.contains("sdrBatchSize"), "sent as null, hence the allowlist entry")
        XCTAssertTrue(raw.keys.contains("sdrCampaignGoal"))
    }

    /// ⛔ THE PAUSE ANSWERS THE READ'S SHAPE, WHICH IS THE WHOLE REASON ONE TYPE GATES
    /// ALL THREE CAMPAIGN FIXTURES. The route derives its reply from the object it
    /// merged, so a phone renders the result of a pause from the response rather than
    /// firing a second request that would race its own write.
    ///
    /// ⛔ AND THE TWO FIELDS THE REQUEST DID NOT MENTION SURVIVED, WHICH IS THE
    /// ASSERTION. The same `{infiniteSdrEnabled:false}` sent to
    /// `workspace/campaign-settings` would wipe the goal text and reset the batch size
    /// to 1, with a 200; this fixture is what shows `campaign-status` merges instead. A
    /// reply that echoed its own input would be indistinguishable from the correct one
    /// if the goal were missing, so the presence of both is the evidence.
    func testThePauseAnswersTheReadsShapeAndKeepsWhatItDidNotMention() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-campaign-pause.json",
            as: CampaignStatusResponse.self
        )
        let campaign = try XCTUnwrap(response.campaign)

        XCTAssertFalse(campaign.infiniteSdrEnabled, "the flag the caller sent")
        XCTAssertEqual(campaign.sdrBatchSize, 25, "⛔ not reset to 1")
        XCTAssertEqual(
            campaign.sdrCampaignGoal,
            "Book demos with lapsed trials",
            "⛔ not wiped: campaign-status merges, campaign-settings would not"
        )
    }

    /// ⚠️ THE TOGGLE IS A BARE ACKNOWLEDGEMENT, and the consequence is a UI one:
    /// nothing in this reply can be adopted, so a workflow switch is
    /// optimistic-with-revert while the campaign pause above adopts its own response.
    /// Two writes on one screen, two correct designs, and the difference is entirely
    /// what each response carries.
    func testTheWorkflowToggleEchoesNothingAtAll() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-workflow-toggle.json",
            as: SuccessResponse.self
        )
        XCTAssertTrue(response.success)

        let raw = try Self.envelope(of: "district-workflow-toggle.json")
        XCTAssertEqual(Set(raw.keys), ["success"], "no echo of the row it wrote")
    }

    // MARK: - Helpers

    private static func envelope(of fixture: String) throws -> [String: Any] {
        let raw = try ContractFixtures.read(fixture)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], fixture)
    }

    private static func object(in fixture: String, under key: String) throws -> [String: Any] {
        let body = try envelope(of: fixture)
        return try XCTUnwrap(body[key] as? [String: Any], "\(fixture) has no object at \(key)")
    }

    private static func array(in fixture: String, under key: String) throws -> [[String: Any]] {
        let body = try envelope(of: fixture)
        return try XCTUnwrap(body[key] as? [[String: Any]], "\(fixture) has no array at \(key)")
    }
}
