import Foundation

/// District HQ, telephony analytics, metered usage, the number marketplace and
/// the two billing reads.
public extension DistrictEndpoints {
    /// Ask District HQ a question, or ask it for a change.
    ///
    /// ⛔ ONE ROUTE, TWO OPERATIONS, AND **NEITHER IS IDEMPOTENT**.
    /// `POST /api/district/hq` branches on the PRESENCE of the `confirm` key in
    /// the body, not on a path or a method — there is no `/hq/confirm` to point
    /// at, and inventing one would 404.
    ///
    /// ⚠️ STATELESS: the server holds no conversation. The client sends the
    /// transcript as `history` and the server keeps the last 6 turns.
    ///
    /// ⚠️ A response carrying `needsConfirmation` has changed NOTHING yet.
    ///
    /// ⛔ RATE LIMITED AT 30/MIN PER ACCOUNT (not per workspace), shared by both
    /// operations. Surface the 429 rather than absorbing it.
    ///
    /// - Parameter history: turns carried WHOLE, as they came back. Each element
    ///   is the server's own turn object.
    static func hqPrompt(
        workspaceId: String,
        prompt: String,
        history: [JSONValue] = []
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .hqPrompt,
            .post,
            DistrictPaths.hq,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("prompt", .string(prompt)),
                ("history", .array(history)),
            ]))
        )
    }

    /// Execute the write the operator approved.
    ///
    /// ⛔ THIS EXECUTES A REAL WRITE — a persona change, a deletion, a routing
    /// replacement, an outbound campaign, or a real email or SMS to a customer.
    /// ⛔ NO AUTOMATIC RE-CONFIRM, EVER: a confirm that timed out may well have
    /// executed, and re-sending it deletes a second contact or sends a second
    /// email. A failed confirm is surfaced to the operator, who is the only party
    /// that can decide whether to repeat it.
    ///
    /// - Parameter args: ⛔ ECHOED BACK VERBATIM from the proposal, never rebuilt.
    ///   That is why this takes a ``JSONValue`` rather than a typed model: a
    ///   rebuilt argument object is a different instruction from the one the
    ///   operator approved.
    ///
    /// ⚠️ A tool name that is not a genuine write tool answers **400**, not 403 —
    /// the server refuses to let a crafted confirm body invoke a read tool.
    static func hqConfirm(
        workspaceId: String,
        tool: String,
        args: JSONValue
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .hqConfirm,
            .post,
            DistrictPaths.hq,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("confirm", .object([
                    ("tool", .string(tool)),
                    ("args", args),
                ])),
            ]))
        )
    }

    /// The analytics window.
    ///
    /// ⛔ THE RANGE IS AN ``AnalyticsRange``, NOT A STRING, BECAUSE AN
    /// UNRECOGNISED `timeRange` IS NOT AN ERROR — the server silently serves 7d
    /// with a 200. See that type.
    static func analytics(workspaceId: String, range: AnalyticsRange) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .analytics,
            .get,
            DistrictPaths.analytics,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("timeRange", range.wire),
            ]
        )
    }

    /// This month's metered usage.
    ///
    /// ⛔ A SUCCESSFUL RESPONSE MAY CARRY `usage: null`, WHICH MEANS "NOTHING
    /// METERED YET" AND NOT "ZERO OF EVERYTHING".
    ///
    /// ⚠️ THE TWO NILS ARE PASSED EXPLICITLY RATHER THAN OMITTED, so the call
    /// site reads as the same request as ``usageHistory(workspaceId:months:)``
    /// with the history switch off — and so a reader can see that the plain read
    /// is genuinely `history` ABSENT rather than `history=false`, which the
    /// server would also accept but which is a different claim about the route.
    static func usage(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .usage,
            .get,
            DistrictPaths.workspaceUsage,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("history", nil),
                ApiQueryItem("months", nil),
            ]
        )
    }

    /// The last `months` months, newest first.
    ///
    /// ⚠️ SAME PATH AS ``usage(workspaceId:)``, SWITCHED BY A QUERY PARAMETER, AND
    /// THE RESPONSE TYPE CHANGES WITH IT: `usage` is an OBJECT there and an ARRAY
    /// here. That is why these are two functions rather than one with a flag —
    /// one function would have to return a union, and a caller able to confuse
    /// them could read a single month as an empty history.
    ///
    /// ⚠️ `months` IS CLAMPED to 1...24 server-side (each month is its own query),
    /// and the response can be SHORTER than asked for because months with no rows
    /// are skipped.
    static func usageHistory(workspaceId: String, months: Int) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .usageHistory,
            .get,
            DistrictPaths.workspaceUsage,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("history", "true"),
                ApiQueryItem("months", String(months)),
            ]
        )
    }

    /// Search the carrier's available inventory.
    ///
    /// ⛔ THE MARKETPLACE IS READ ONLY FROM THIS CLIENT, AND THAT IS A DECISION
    /// RATHER THAN AN OMISSION. Purchase, release and configure routes exist
    /// server-side and are deliberately not ported: buying a number creates a
    /// recurring carrier charge, releasing one takes a live line out of service,
    /// and a released number cannot be reclaimed.
    ///
    /// ⛔ A WORKSPACE WITH NO CARRIER CONNECTED ANSWERS **400**, NOT AN EMPTY
    /// LIST. That is a legitimate account state rather than a fault, and it must
    /// render as an empty state that explains itself, never as an error the
    /// operator is invited to retry.
    ///
    /// ⚠️ The server hardcodes the result limit (10) and the capability filter
    /// (sms+voice), so neither is offered here — a parameter for either would be a
    /// control the route ignores.
    static func searchNumbers(
        workspaceId: String,
        areaCode: String?,
        country: String?,
        type: String?,
        provider: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .searchNumbers,
            .get,
            DistrictPaths.numbersSearch,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("areaCode", areaCode),
                ApiQueryItem("country", country),
                ApiQueryItem("type", type),
                ApiQueryItem("provider", provider),
            ]
        )
    }

    /// Every number the workspace already has, from every source.
    ///
    /// ⛔ THE ANSWER CAN BE INCOMPLETE ON A 200. When one carrier fails and
    /// another answers, the response is `partial: true` with `failedProviders`
    /// naming the one that did not. Render the rows AND the warning; the 502 is
    /// reserved for the case where nothing resolved at all.
    static func ownedNumbers(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .ownedNumbers,
            .get,
            DistrictPaths.providerNumbers,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// The workspace's plan, status, overage state and this month's usage — with
    /// NO Stripe call.
    ///
    /// ⛔ THE ABSENCE OF STRIPE IS THE FEATURE. Every field comes from columns the
    /// Stripe webhooks wrote to our own database, so this answer is exactly as
    /// available as our own origins are. ``stripeBilling()`` is only as available
    /// as Stripe is.
    ///
    /// ⛔ BILLING IS READ ONLY IN THIS CLIENT AND THAT IS NOT REVISITABLE — App
    /// Store Review Guideline 3.1.3(b). `POST /api/billing` cancels
    /// subscriptions, changes plans, edits payment methods and applies promo
    /// codes; none of it is ported, and **no purchase CTA and no link-out to the
    /// Stripe portal** may be added either. A link-out is what turns a compliant
    /// status screen into a rejected one.
    ///
    /// ⛔ A SUCCESSFUL RESPONSE MAY CARRY `usage: null` — "nothing metered this
    /// month", not "zero of everything".
    static func workspaceBilling(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .workspaceBilling,
            .get,
            DistrictPaths.workspaceBilling,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Subscriptions and invoices, from Stripe.
    ///
    /// ⛔ TAKES NO `workspaceId`, AND COULD NOT. It is guarded by `requireAuth`
    /// and resolves the caller's OWN Stripe customer from server-owned state; the
    /// workspace it reports on comes BACK in `usageWorkspaceId`. A parameter here
    /// would be an identity the caller supplied.
    ///
    /// ⛔ IT NEVER ANSWERS `{success: …}`, SO THE ENVELOPE GUARD MUST NOT BE
    /// APPLIED TO IT. A 200 here is decoded directly.
    ///
    /// ⛔ AND IT ANSWERS **200 WHEN STRIPE IS DOWN**, with
    /// `billingUnavailable: true` and empty arrays. Render "billing is
    /// temporarily unavailable" — never a free or unstarted account. The
    /// no-customer response is the same body WITHOUT the flag and does
    /// legitimately mean the latter.
    static func stripeBilling() -> ApiRequestDescriptor {
        ApiRequestDescriptor(.stripeBilling, .get, DistrictPaths.billing)
    }
}
