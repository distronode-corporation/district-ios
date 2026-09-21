import Foundation

// The scheduling admin's settings, recordings, developer and upload rows
// and their four allowed nulls.
//
// ⛔ IN `Tests/ContractGateSupport/` AND NOT IN `Tests/ContractFixtureTests/`,
// FOR THE REASON `AllowedExplicitNulls+SchedulingB.swift` STATES AND WHICH IS
// WORTH RE-STATING RATHER THAN CROSS-REFERENCING: `allowedExplicitNulls` is
// composed in `AllowedExplicitNulls+Union.swift` out of groups declared in THIS
// module, and `ContractFixtureTests` is a different SwiftPM target that depends on
// it. A group declared over there could never be merged in — the dependency only
// runs one way — so the gate would read the EMPTY set for these three fixtures
// while a `schedulingC` constant sat beside them looking authoritative, and the
// four nulls below would fail the no-nulls invariant with an error pointing at the
// bytes rather than at the missing wiring. The fifth group is chained in
// `+Union.swift` in the same change, which is what the ⛔ there requires.
//
// ⛔ SPLIT INTO ITS OWN FILE FOR THE LINE CEILING, the same reason `+Union.swift`,
// `+Inbox.swift` and `+SchedulingB.swift` exist.

extension StrictDecodeVerifier {
    /// The `me.*`, `recordings.*`, `settings.*`, `apiKeys.*`,
    /// `oauth.connections.*`, `webhooks.*` and image-upload fixtures.
    ///
    /// ⛔ FOUR PATHS ACROSS THREE OF FIFTEEN FIXTURES, ENUMERATED FROM THE BYTES
    /// RATHER THAN FROM THE DTOs. The other twelve carry no null anywhere and must
    /// not be given an entry: their optional fields are ABSENT keys, which a nil
    /// Optional already round-trips, so permission there would silence a null the
    /// server does not send today and would keep silencing it the day it starts to.
    ///
    /// ⚠️ THE THREE FIXTURES A READER WOULD MOST EXPECT TO FIND HERE ARE THE ONES
    /// THAT ARE NOT. `district-scheduling-recordings.json`'s row 1 is a FAILED
    /// capture missing six of its eight keys; `-recordings-consent.json`'s row 1 is
    /// a guest with no name and no decision timestamp; and
    /// `-webhook-deliveries.json`'s row 1 is a delivery that never got an answer.
    /// Every one of those absences is an ABSENT KEY — the catalog types them
    /// `.optional()` and `JSON.stringify` drops an undefined rather than writing
    /// null — so all three are proved by the gate's ordinary key-set walk and none
    /// of them belongs in this register. The distinction is the whole reason an
    /// entry is a decision.
    ///
    /// ⛔ ALL FOUR BELOW ARE THE SAME MECHANISM SEEN TWICE OVER: a Go pointer or
    /// slice the scheduler fork marshals WITHOUT `omitempty`, so "not set" crosses
    /// the wire as an explicit `null` rather than as an absent key. The server's own
    /// schemas are where that is visible — these fields are `.nullable().optional()`
    /// and `.nullish()` where every sibling on the same row is a plain
    /// `.optional()` — and the web formatter records the consequence for the
    /// browser: a truthiness check is the right test, and an `=== undefined` one
    /// renders the string "null" into the cell.
    ///
    ///   last_used_at  `APIKey.LastUsedAt` and `OAuthConnection.LastUsedAt`, both
    ///                 `*time.Time`. Null for a credential that has NEVER BEEN
    ///                 USED, which is the ordinary state of one minted a minute
    ///                 ago — so this is the common row, not the edge. ⚠️ It appears
    ///                 on two fixtures because two unrelated tables carry the same
    ///                 column with the same meaning; if either stopped nulling it,
    ///                 that one fails on its own.
    ///   expires_at    `OAuthConnection.ExpiresAt`. ⛔ Null means "DOES NOT EXPIRE",
    ///                 never "expired". It sits beside `last_used_at` on the same
    ///                 row deliberately: a connection that has never been used and
    ///                 never expires is the shape a client is most likely to get
    ///                 wrong in both directions at once.
    ///   fields        `Webhook.Fields`, a nil slice. ⛔ Null means "THE FORK'S
    ///                 DEFAULT SET", not "no fields" — a webhook created before
    ///                 field selection existed has no list and the fork substitutes
    ///                 its own at delivery time. Typed `.nullish()` in the catalog
    ///                 where `events` on the same row is a required array, which is
    ///                 the schema saying the same thing.
    static let schedulingC: [String: Set<String>] = [
        // ⚠️ THE PATHS ARE INSIDE `$.data.items` BECAUSE THE FIXTURE IS THE WHOLE
        // RPC ENVELOPE **AND** THESE THREE OPS USE THE CATALOG'S SHARED `items`
        // CONTAINER. A path copied from the row's own shape would name nothing and
        // the entry would silently exempt nothing at all — and note that the two
        // recordings fixtures in this same group use `recordings` and `consents`
        // instead, so the container key is not a property of the surface.
        "district-scheduling-api-keys.json": [
            "$.data.items[1].last_used_at",
        ],
        "district-scheduling-oauth-connections.json": [
            "$.data.items[1].expires_at",
            "$.data.items[1].last_used_at",
        ],
        "district-scheduling-webhooks.json": [
            "$.data.items[1].fields",
        ],
    ]
}
