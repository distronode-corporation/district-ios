import Foundation

/// Who belongs to this workspace, what it is called, and the automation monitor.
///
/// ⛔ THE MEMBERSHIP MUTATIONS ARE AGENCY-ONLY, WHICH IS NARROWER THAN ANYTHING
/// ELSE ON THIS SURFACE. Every other write in this API admits
/// `["agency","client"]`; these three admit `agency` alone, because membership is
/// what `getWorkspaceRole` answers from — a client or viewer who could write here
/// could grant themselves any role and bypass every `requireWorkspaceRole` in the
/// product. `WorkspaceRole.canMutate` is therefore the WRONG gate for them.
///
/// ⛔ TWO OF THEM CAN BE REFUSED WITH A MACHINE-READABLE CODE RATHER THAN A
/// STATUS ALONE: a duplicate address is 409 `member_exists`, and demoting or
/// removing the last agency member is 409 `last_agency_member`. Both deserve
/// their own sentence — "already a member" and "this workspace would have no
/// administrator" are not the same problem, and only one of them is something the
/// operator did wrong. Branch on `ApiErrorEnvelope.code`, never on the message.
public extension DistrictEndpoints {
    /// The roster.
    ///
    /// ⚠️ ADMITS ALL THREE ROLES, INCLUDING `viewer` — deliberately, per the
    /// route: a viewer who cannot see who else is in the workspace cannot tell
    /// who to ask for help. So the LIST is reachable by a role the
    /// workspace-settings hub in front of it excludes.
    ///
    /// ⚠️ Ordered `createdAt asc` — OLDEST FIRST, the opposite of every other list
    /// here.
    static func members(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .members,
            .get,
            DistrictPaths.workspaceMembers,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Add one member.
    ///
    /// ⛔ NO INVITATION IS SENT AND NO ACCOUNT IS PROVISIONED. This makes an
    /// EXISTING login a member; an address that has never signed up simply has a
    /// row waiting for it. Invitation is a separate feature and deliberately out
    /// of scope.
    ///
    /// ⚠️ 404 IF THE WORKSPACE DOES NOT EXIST, and that check is not redundant
    /// with the role guard: for a support-access caller the guard returns
    /// "agency" for ANY id, so without it a typo would create a member row
    /// pointing at nothing.
    ///
    /// ⚠️ Rate limited 20/min per WORKSPACE (not per caller) across all three
    /// membership writes.
    static func addMember(workspaceId: String, email: String, role: String?) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .addMember,
            .post,
            DistrictPaths.workspaceMembers,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("email", .string(email)),
                ("role", .optional(role)),
            ]))
        )
    }

    /// Change one member's role.
    ///
    /// ⛔ REFUSED WITH 409 `last_agency_member` WHEN IT WOULD DEMOTE THE LAST
    /// AGENCY MEMBER. The count and the write share one interactive transaction,
    /// so two concurrent demotions cannot both read "there are still two" and both
    /// commit.
    ///
    /// ⚠️ 404 for an address that is not a member — distinct from the 409s, and it
    /// means the roster on screen is stale rather than that the request was wrong.
    static func changeMemberRole(
        workspaceId: String,
        email: String,
        role: String
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .changeMemberRole,
            .patch,
            DistrictPaths.workspaceMembers,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("email", .string(email)),
                ("role", .string(role)),
            ]))
        )
    }

    /// Remove one member.
    ///
    /// ⛔ **DELETE WITH QUERY PARAMETERS AND NO BODY**, spelled `workspaceId` and
    /// `email`. Same shape as the knowledge delete, and the same failure if
    /// misspelled: a 400 naming the field, which reads as a broken client rather
    /// than as a typo.
    ///
    /// ⚠️ ANSWERS A BARE `{success:true}` WITH NO `member` KEY. That is why
    /// `MemberMutationResponse.member` is optional, and it is the one response a
    /// client must not fail to decode, since the row really is gone.
    static func removeMember(workspaceId: String, email: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .removeMember,
            .delete,
            DistrictPaths.workspaceMembers,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("email", email),
            ]
        )
    }

    /// Rename the workspace.
    ///
    /// ⛔ THE RESPONSE ECHOES THE **TRIMMED, STORED** NAME, and adopting that echo
    /// rather than the requested string is what makes a re-read unnecessary — the
    /// server trims before it measures, so what comes back is what a later read
    /// will see.
    ///
    /// ⛔ NAME ONLY. The slug is unique in two physically separate databases with
    /// no cross-database transaction between them, so it is not editable from here
    /// at all.
    ///
    /// ⚠️ ADMITS `agency` AND `client`, unlike the membership writes — so the two
    /// controls on that one screen are gated separately. ⚠️ Rate limited 10/min
    /// keyed on the CALLER's email rather than on the workspace, the opposite key
    /// from the membership limiter.
    static func renameWorkspace(workspaceId: String, name: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .renameWorkspace,
            .patch,
            DistrictPaths.workspaceRename,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("name", .string(name)),
            ]))
        )
    }

    /// Every workflow in the workspace, newest first, each with its latest run.
    ///
    /// ⛔ THE CREATE, THE FULL EDIT AND THE DELETE ARE DELIBERATELY UNREACHABLE
    /// FROM THIS CLIENT. The same path serves POST and DELETE, and PATCH accepts
    /// `name`, `trigger`, `triggerMetadata` and `actions` as well as `active`. A
    /// workflow ACTION is an outbound SMS, an email, a compliance DNC registration
    /// or a `notify_ops` webhook, and `actions` is written WHOLESALE — an
    /// accidental empty array would delete every action a workflow has, with a
    /// 200.
    ///
    /// ⚠️ `latestRun` is an explicit NULL for a workflow that has never run, not
    /// an omitted key. ⚠️ NOT PAGED, and the server applies no cap.
    static func workflows(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .workflows,
            .get,
            DistrictPaths.workflows,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// One workflow's execution history, newest first.
    ///
    /// ⛔ `workflowId` IS REQUIRED AND ITS ABSENCE IS A **400**, not an unfiltered
    /// list — the route checks it before the role guard even runs. It is a QUERY
    /// parameter rather than a path segment; a `/runs/{id}` path would 404.
    ///
    /// - Parameter limit: CLAMPED server-side to 1...50, defaulting to 10 — and a
    ///   non-numeric value is REPLACED with the default rather than clamped,
    ///   because a NaN `take` makes Prisma throw. The response echoes what was
    ///   actually applied, which is the only way a caller learns.
    static func workflowRuns(
        workspaceId: String,
        workflowId: String,
        limit: Int,
        offset: Int
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .workflowRuns,
            .get,
            DistrictPaths.workflowRuns,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("workflowId", workflowId),
                ApiQueryItem("limit", String(limit)),
                ApiQueryItem("offset", String(offset)),
            ]
        )
    }

    /// Turn one workflow on or off.
    ///
    /// ⛔ **PATCH ON THE COLLECTION PATH**, NOT ON A WORKFLOW'S OWN. There is no
    /// `/api/district/workflows/{id}` route at all — the id travels in the BODY —
    /// and a POST here would CREATE a workflow rather than update one. The two
    /// verbs on one path are not interchangeable and the failure would be a new
    /// row, not an error.
    ///
    /// ⛔ THE BODY CARRIES ONLY `active`, `workflowId` AND `workspaceId`. The route
    /// decides what to write with `"active" in body`, so a dropped key is not
    /// "leave it alone" but "nothing to update", a 400 — which is why `active` is
    /// non-optional here and cannot reach the nil-drop.
    ///
    /// ⚠️ ANSWERS A BARE `{success:true}` WITH NO ECHO, so a caller needing fresh
    /// state must re-read.
    static func setWorkflowActive(
        workspaceId: String,
        workflowId: String,
        active: Bool
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .setWorkflowActive,
            .patch,
            DistrictPaths.workflows,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("workflowId", .string(workflowId)),
                ("active", .bool(active)),
            ]))
        )
    }

    /// Whether the always-on SDR campaign is running, and how it is configured.
    ///
    /// ⚠️ ADMITS `viewer`, and that is why it is a separate route from
    /// `workspace/config` at all — that one excludes viewers because its payload
    /// carries staff transfer numbers and the operator's own prompt.
    ///
    /// ⚠️ REGION-RESOLVED SERVER-SIDE: a ca/eu/apac workspace has no `Workspace`
    /// row in the hub, so a hub-only read would report every non-us tenant as
    /// having no campaign configured. ⚠️ A 404 means the workspace id did not
    /// resolve, which is distinct from "no campaign" — that is a 200 with all
    /// three fields at their empty values.
    static func campaignStatus(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .campaignStatus,
            .get,
            DistrictPaths.workspaceCampaignStatus,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Pause or resume the always-on SDR engine, and touch nothing else.
    ///
    /// ⛔ THIS IS **NOT** `workspace/campaign-settings`, AND THE DISTINCTION IS THE
    /// WHOLE REASON THE CALL EXISTS. That route rebuilds all three SDR fields from
    /// the request body (`sdrCampaignGoal: goal || ""`,
    /// `sdrBatchSize: floor(Number(size) || 1)`), so a partial body sent to pause a
    /// campaign WIPES the goal text and resets the batch size to 1 — with a 200.
    /// `PATCH campaign-status` reads the stored Json, spreads it, and assigns ONE
    /// key. Never point this at the other path to "reuse" a route.
    ///
    /// ⛔ EXCLUDES `viewer` UNLIKE THE GET ON THE SAME PATH — the only verb split
    /// in this API. Watching a campaign and pausing one are different powers.
    ///
    /// ⚠️ A NON-BOOLEAN `infiniteSdrEnabled` IS A 400 rather than a coercion,
    /// which is why the parameter is non-optional and cannot be dropped.
    static func setCampaignEnabled(
        workspaceId: String,
        infiniteSdrEnabled: Bool
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .setCampaignEnabled,
            .patch,
            DistrictPaths.workspaceCampaignStatus,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("infiniteSdrEnabled", .bool(infiniteSdrEnabled)),
            ]))
        )
    }
}
