import Foundation

/// `GET /api/district/setup`: the new-customer setup wizard's state (setup wizard plan 2.5).
///
/// ⛔ THE APP READS ONE FACT FROM THIS AND DOES NOT RUN THE WIZARD. The wizard lives on the
/// web; this client only decides whether to offer the owner a way back to it, through
/// ``needsWebSetup``. Everything else is modelled because the strict contract gate
/// re-encodes the fixture and fails on a lost key, not because a screen reads it.
///
/// ⛔ EVERY FIELD IS OPTIONAL, WHICH IS HOW THIS CODEBASE SPELLS ANDROID'S "EVERY FIELD HAS A
/// DEFAULT". A non-optional `let` throws on a MISSING key, so a key removed server-side would
/// break every installed build's decode of the one bit the card needs. The server already
/// omits `completedAt`, `paidAt` and friends until they are true.
///
/// ⚠️ OWNER ONLY. A member, or a support-access caller, gets 403
/// `workspace_owner_only` and never a body, so there is no "not the owner" field here.
public struct DistrictSetupResponse: Codable, Sendable, Equatable {
    /// ⛔ NIL MEANS "THIS WORKSPACE NEVER SEES THE WIZARD", not "not started". Every
    /// workspace that existed before the wizard is null and stays null; only a real paid
    /// checkout writes one.
    public let setupProgress: SetupProgress?
    /// ⚠️ OPAQUE ON PURPOSE. The business step's answers are free-form and edited only on
    /// the web, and nothing here reads them. ``WireJSON`` so a reshaped facts payload cannot
    /// fail this decode, which is the one read the card depends on.
    public let businessFacts: WireJSON?
    /// The workspace's data region, e.g. "ca".
    public let region: String?
    /// The stored subscription tier, mixed case, e.g. "VoicePro".
    public let tier: String?
    /// Numbers the tier includes, or nil when no ceiling applies.
    public let includedNumbers: Int?
    /// Numbers the workspace currently holds.
    public let numbersHeld: Int?

    /// Whether to offer the owner the rest of setup: a workspace that IS in the wizard
    /// (non-nil progress) and has not finished it. Nil progress (a pre-wizard workspace)
    /// and a completed one both answer false.
    public var needsWebSetup: Bool {
        guard let setupProgress else { return false }
        return setupProgress.completedAt == nil
    }
}

/// The wizard's stored progress. Server-owned timestamps are ABSENT until they happen.
public struct SetupProgress: Codable, Sendable, Equatable {
    public let steps: SetupSteps?
    public let paidAt: String?
    public let firstRealCallAt: String?
    /// ⛔ THE CARD'S SHOW CONDITION: absent while the owner is still setting up.
    public let completedAt: String?
    /// The owner's consent to a test call, verbatim wording included. Not read here.
    public let testCallConsent: WireJSON?
    /// The forwarding check's state. Not read here.
    public let forwardingCheck: WireJSON?
}

/// The six wizard steps, each `todo`, `done` or `skipped`.
///
/// ⚠️ STRINGS, NOT AN ENUM. A fourth state added server-side must not make the whole
/// response undecodable, which an enum would.
public struct SetupSteps: Codable, Sendable, Equatable {
    public let business: String?
    public let number: String?
    public let receptionist: String?
    public let callers: String?
    public let calls: String?
    public let golive: String?
}
