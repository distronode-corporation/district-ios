import Foundation

/// Who answers a call, and whether the person asking can be rung at all.
///
/// ⛔ TWO ROUTES THAT LOOK LIKE ONE FEATURE AND ARE NOT ONE SCOPE, WHICH IS THE
/// ONLY THING IN THIS FILE THAT IS EASY TO GET WRONG. `workspace/call-handling`
/// is a WORKSPACE setting: every member sees the same value and a mutator
/// changes it for all of them. `workspace/availability` is a fact about the
/// CALLER'S OWN membership row — the PATCH takes no email and no user id, so
/// there is no way to express "set someone else's availability" and no UI may
/// imply otherwise.
///
/// ⛔ NEITHER OF THESE IS A WHOLESALE REPLACE, WHICH MAKES THEM THE FIRST WRITES
/// ON THIS SURFACE THAT DO NOT NEED A LOAD FIRST. `saveTools`,
/// `saveRoutingRules` and `saveDirectory` all overwrite a stored array, so a
/// form that opened empty and saved would delete something; these two write
/// scalars and the PATCH accepts either field alone. A screen still reads first,
/// because it has to draw the current value, but a failed read is a blank screen
/// rather than a live delete.
///
/// ⚠️ BOTH PATCHES ECHO THE NEW VALUES, unlike every other workspace-settings
/// write on this surface (which answer a bare `{success:true}` and force a
/// re-read). So a save here adopts its own response and needs no second request.
public extension DistrictEndpoints {
    /// How this workspace answers a call.
    ///
    /// ⚠️ THE VALUES ARE NORMALISED SERVER-SIDE, WHICH IS WHY THE CLIENT NEVER
    /// SEES A RAW STORED VALUE. An unrecognised mode reads back as
    /// ``CallHandling/default`` and an out-of-range ring is clamped and
    /// truncated, so this read cannot hand a picker a selection it has no row
    /// for. ⛔ Do not re-normalise on top of that: a client that clamped again
    /// would be a second opinion about a value the server has already settled.
    ///
    /// ⚠️ IT ADMITS `viewer` WHILE THE PATCH DOES NOT — the opposite split from
    /// `workspace/config`, whose read excludes them because it carries staff
    /// transfer numbers. Nothing here is a phone number, so the screen shows a
    /// viewer the real setting read-only rather than being hidden.
    static func callHandling(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .callHandling,
            .get,
            DistrictPaths.workspaceCallHandling,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Change who answers, or how long the app rings.
    ///
    /// ⛔ AT LEAST ONE OF THE TWO FIELDS IS REQUIRED AND AN EMPTY BODY IS A 400,
    /// not a no-op. That is why both parameters are optional here and why a
    /// caller must never send `nil, nil`: the nil-drop in ``JSONValue/object(_:)``
    /// would produce a body carrying only the workspace, which the route refuses.
    ///
    /// ⛔ AN UNKNOWN MODE OR AN OUT-OF-RANGE RING IS A **400**, NOT A COERCED
    /// VALUE. The read normalises what is STORED; the write validates what
    /// ARRIVES, and those are deliberately not the same rule — a stored value
    /// predating the vocabulary must still be displayable, while a client sending
    /// one must be told it is wrong. Send ``CallHandling`` and
    /// ``CallHandling/clampRing(_:)`` rather than free values.
    ///
    /// ⚠️ IT ECHOES THE NEW VALUES, so the response is the new baseline and no
    /// re-read is needed.
    static func saveCallHandling(
        workspaceId: String,
        callHandling: String?,
        appRingSeconds: Int?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveCallHandling,
            .patch,
            DistrictPaths.workspaceCallHandling,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("callHandling", .optional(callHandling)),
                // ⛔ `.integer`, NEVER `.number`. The route refuses a FRACTIONAL
                // value with a 400, and a `Double` that encodes as `20.0` is
                // fractional as far as a zod `.int()` is concerned. The type is
                // `Int` here for the same reason.
                ("appRingSeconds", appRingSeconds.map { JSONValue.integer($0) }),
            ]))
        )
    }

    /// Whether the caller can be rung for this workspace's calls.
    ///
    /// ⛔ `reason` IS ALWAYS PRESENT ON THE WIRE AND IS `null` WHEN THERE IS
    /// NOTHING TO EXPLAIN. That is the route's own decision and it is the right
    /// one for these clients: both native decoders are strict about unknown keys,
    /// so a key that appeared only in the interesting cases would be exactly the
    /// shape that fails to decode the answer worth reading. See
    /// ``AvailabilityReason``.
    ///
    /// ⚠️ A VIEWER GETS `false` WITH `reason: "role"` AND NO DATABASE READ. It is
    /// a real answer rather than a refusal, so this route never 403s for a role —
    /// which means a screen must render the reason instead of assuming a 200
    /// carries a toggleable value.
    static func availability(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .availability,
            .get,
            DistrictPaths.workspaceAvailability,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Make the caller available, or not.
    ///
    /// ⛔ IT WRITES THE CALLER'S OWN MEMBERSHIP ROW AND TAKES NO IDENTITY. There
    /// is no `email` and no `userId` parameter here and there must never be one:
    /// an identity that arrives as an argument is an identity the caller chose,
    /// which is the same rule the voice tools document. A roster screen offering
    /// to toggle a colleague cannot be built on this and must not be faked with
    /// one.
    ///
    /// ⛔ **409 WHEN THERE IS NO MEMBER ROW TO WRITE.** That is not a validation
    /// failure and not a permission failure: the person holds their role through
    /// the owner fallback, so there is genuinely nothing to set, and the ring
    /// fan-out reads `WorkspaceMember`. It is the write-side twin of the read's
    /// `reason: "no_member_row"` and needs the same sentence rather than a generic
    /// refusal.
    ///
    /// ⚠️ IT ECHOES THE VALUE WRITTEN, with `reason: null`, so the response is the
    /// new baseline.
    static func saveAvailability(workspaceId: String, availableForCalls: Bool) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .saveAvailability,
            .patch,
            DistrictPaths.workspaceAvailability,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("availableForCalls", .bool(availableForCalls)),
            ]))
        )
    }
}
