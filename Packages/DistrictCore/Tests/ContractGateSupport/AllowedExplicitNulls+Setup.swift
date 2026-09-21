import Foundation

// The setup wizard's allowlist entry, in a file of its own like `+Meetings` and
// `+DeskSupport`. Chained into `allowedExplicitNulls` in `AllowedExplicitNulls+Union.swift`.

extension StrictDecodeVerifier {
    static let setup: [String: Set<String>] = [
        // ⛔ ONE PATH, AND IT IS A FRESH WORKSPACE'S ORDINARY STATE. `Workspace.businessFacts`
        // is a nullable Json column written only by the wizard's business step, and the
        // route passes `parseBusinessFacts(row.businessFacts ?? null)` through, so a workspace
        // that has not reached that step answers the key present and null.
        //
        //   businessFacts   Null until the owner saves the business step on the web.
        //
        // ⚠️ `setupProgress` GETS NO ENTRY AND MUST NOT BE GIVEN ONE. It is null only on a
        // workspace that predates the wizard, which this fixture is not; that branch is
        // derived from the fixture text in `SetupContractTests` instead. ⚠️ Nor do
        // `completedAt`, `firstRealCallAt`, `testCallConsent` or `forwardingCheck`: the server
        // OMITS them until they happen, and an absent key needs no permission.
        "district-setup.json": [
            "$.businessFacts",
        ],
    ]
}
