import Foundation

/// `GET`/`PATCH /api/district/workspace/call-handling` — which of the agent and
/// the app answers a call, and how long the app is given to.
///
/// ⛔ BOTH VERBS ANSWER THE SAME SHAPE, AND THE PATCH'S BODY IS THE NEW BASELINE.
/// That makes this the FIRST write on the workspace-settings surface that does not
/// need a re-read: `workspace/persona`, `workspace/tools`, `workspace/directory`
/// and `workspace/routing-rules` all answer a bare `{"success": true}` and force
/// one. So one DTO for two endpoints, deliberately — see the ⛔ at the foot of
/// `WorkspaceConfigResponses.swift` for why sharing is the honest call when the
/// bodies really are identical, and the caveat that comes with it: the day the
/// PATCH grows a key, split a type out rather than widening this one.
///
/// ⛔ THE VALUES ARRIVE NORMALISED AND MUST NOT BE NORMALISED AGAIN. The route
/// resolves an unrecognised stored mode to ``CallHandling/default`` and clamps a
/// stored ring into range before answering, precisely so a client never has to
/// hold an opinion about a value written by an older build. A second clamp here
/// would be a second opinion about a settled question, and the first thing it
/// would break is a mode added server-side.
public struct CallHandlingResponse: Codable, Sendable {
    public let success: Bool
    /// One of ``CallHandling/modes``. ⚠️ A RAW STRING RATHER THAN AN ENUM, the same
    /// call `role` and the SSO provider id make: a mode added server-side must
    /// degrade to "some setting this build does not draw" rather than fail the whole
    /// decode and take the ring seconds with it.
    public let callHandling: String
    /// 5...30, clamped server-side. See ``CallHandling/clampRing(_:)``.
    public let appRingSeconds: Int
}

/// The vocabulary and the bounds, mirroring the server's call-handling module.
///
/// ⛔ THE THREE MODES ARE THE SERVER'S `CALL_HANDLING_MODES` AND THE ORDER IS
/// MEANINGFUL: it runs from "the agent handles everything" to "your phone rings
/// first", which is the order a picker must offer them in. Reordering it would
/// change what an operator scanning the control reads without changing a value.
///
/// ⛔ AND THE STRINGS ARE THE WIRE VALUES, NEVER LABELS. `ai_then_app` is what the
/// PATCH validates against; the sentence an operator reads is UI copy and lives
/// with the screen. A client that sent a label would be a 400.
public enum CallHandling {
    /// The agent answers and handles the call. Nothing rings.
    public static let aiFirst = "ai_first"
    /// The agent answers, then rings the app.
    public static let aiThenApp = "ai_then_app"
    /// The app rings first; the agent takes it if nobody answers.
    public static let appFirst = "app_first"

    /// ⚠️ IN THE SERVER'S ORDER, WHICH IS ALSO THE ORDER TO OFFER THEM IN.
    public static let modes = [aiFirst, aiThenApp, appFirst]

    /// `DEFAULT_CALL_HANDLING`. ⚠️ What an unrecognised STORED value reads back as,
    /// which the server does rather than the client — see the ⛔ on
    /// ``CallHandlingResponse``.
    public static let `default` = aiFirst

    public static let minimumRingSeconds = 5
    public static let maximumRingSeconds = 30
    /// `DEFAULT_APP_RING_SECONDS`.
    public static let defaultRingSeconds = 20

    /// Hold a ring duration inside the range the PATCH accepts.
    ///
    /// ⛔ FOR THE OUTBOUND VALUE ONLY, NEVER FOR THE ONE THAT ARRIVED. The route
    /// answers a **400** for an out-of-range or fractional `appRingSeconds` rather
    /// than coercing it, so a stepper that could emit 31 would produce a refusal
    /// the operator cannot act on. What comes BACK is already clamped and must be
    /// displayed as sent.
    public static func clampRing(_ seconds: Int) -> Int {
        min(max(seconds, minimumRingSeconds), maximumRingSeconds)
    }

    /// Whether a mode is one this build can send.
    ///
    /// ⚠️ USED ON THE WAY OUT, NOT ON THE WAY IN. A mode this build does not know
    /// is legitimate on a read (the server added one) and a 400 on a write.
    public static func isKnown(_ mode: String) -> Bool {
        modes.contains(mode)
    }
}

/// `GET`/`PATCH /api/district/workspace/availability` — whether the CALLER can be
/// rung for this workspace's calls.
///
/// ⛔ IT IS A FACT ABOUT THE CALLER'S OWN MEMBERSHIP ROW, NOT ABOUT THE WORKSPACE.
/// The PATCH takes no email and no user id and writes only the row belonging to the
/// verified session, so nothing built on this type can express "set someone else's
/// availability". A roster screen that appeared to must not be built here.
///
/// ⛔ AND IT IS PER WORKSPACE, WHICH IS THE PART THAT SURPRISES PEOPLE. The same
/// person can be available in one workspace and not in another, so any UI drawing
/// this has to NAME the workspace it is talking about — a bare "Available for
/// calls" toggle is a claim about the whole account that this value does not make.
public struct AvailabilityResponse: Codable, Sendable {
    public let success: Bool
    public let availableForCalls: Bool

    /// Why the answer is what it is, or nil when there is nothing to explain.
    ///
    /// ⛔ THE KEY IS ALWAYS PRESENT ON THE WIRE AND CARRIES AN EXPLICIT `null` ON
    /// THE ORDINARY PATH. That is the route's own decision, and it is the right one
    /// for these clients: the Android client decodes with `ignoreUnknownKeys =
    /// false` and this one is gated by a strict verifier, so a key that appeared
    /// only in the interesting cases would be exactly the shape that fails to
    /// decode the answer worth reading. ⚠️ Modelled as an optional VALUE rather
    /// than an optional KEY: `nil` here means the server said `null`, and there is
    /// no fourth state where the key was missing.
    public let reason: String?
}

/// The two reasons `availability` gives, spelled as the server spells them.
///
/// ⛔ TWO DIFFERENT FACTS, AND COLLAPSING THEM INTO ONE "unavailable" LINE IS THE
/// MISTAKE THIS TYPE EXISTS TO PREVENT. `role` is a viewer, who has no business
/// being rung and can do nothing about it. `no_member_row` is somebody who holds
/// their role through the OWNER FALLBACK and therefore has no `WorkspaceMember` row
/// at all — the ring fan-out reads that table, so they genuinely cannot be rung
/// today, and the write answers **409** rather than creating a row. One of those is
/// a permission and the other is a gap in the data; an operator can act on the
/// second by being added to the workspace properly.
///
/// ⚠️ PLAIN CONSTANTS RATHER THAN AN ENUM, the same call ``ApiErrorCode`` makes: a
/// third reason added server-side must degrade to "unavailable, no explanation this
/// build understands" rather than throw and take the response with it.
public enum AvailabilityReason {
    /// A viewer. Answered with no database read at all.
    public static let role = "role"
    /// No `WorkspaceMember` row: the role comes from the owner fallback. ⛔ The
    /// PATCH answers **409** for this, which is the same fact from the write side.
    public static let noMemberRow = "no_member_row"
}
