import Foundation

// The scheduling admin's bookings, calendar, users and teams rows and their three
// allowed nulls.
//
// ⛔ IN `Tests/ContractGateSupport/` AND NOT IN `Tests/ContractFixtureTests/`,
// WHICH IS NOT A FILING PREFERENCE. `allowedExplicitNulls` is composed in
// `AllowedExplicitNulls+Union.swift` out of groups declared in THIS module, and
// `ContractFixtureTests` is a different SwiftPM target that depends on it — so a
// group declared over there could never be merged in, and the gate would read the
// empty set for these three fixtures while a `schedulingB` constant sat beside it
// looking authoritative. The fourth group is chained in `+Union.swift` in the same
// change, which is what the ⛔ there requires.
//
// ⛔ SPLIT INTO ITS OWN FILE FOR THE LINE CEILING, the same reason `+Union.swift`
// and `+Inbox.swift` exist: `AllowedExplicitNulls.swift` sits three lines under
// SwiftLint's 500-line `file_length`, which `--strict` promotes to an error, and an
// entry without the comment justifying it is the thing this register exists to
// prevent.

extension StrictDecodeVerifier {
    /// The `bookings.*`, `calendar.*`, `users.*` and `teams.*` fixtures.
    ///
    /// ⛔ THREE PATHS ACROSS THREE OF SIXTEEN FIXTURES, ENUMERATED FROM THE BYTES.
    /// The other thirteen carry no null anywhere and must not be given an entry:
    /// their optional fields are ABSENT keys, which a nil Optional already
    /// round-trips, so permission there would silence a null the server does not
    /// send today and would keep silencing it the day it starts to.
    ///
    /// ⛔ ALL THREE ARE THE SAME FACT SEEN THREE TIMES: a Go slice the scheduler
    /// fork marshals WITHOUT `omitempty`, so a nil slice crosses the wire as an
    /// explicit `null` rather than as an absent key. The server's own schemas say
    /// so — `userSchema.teams` and `teamSchema.members` are `.nullish()` where
    /// every other optional array on those rows is `.optional()` — and the same
    /// mechanism is what breaks a page outright when it is missed: with `calendar.status`'s
    /// `unconfigured_providers` typed `.optional()`, every configured tenant's calendar
    /// page reads "could not be read".
    ///
    ///   teams    `SchedulingUser.teams`. Null for a scheduler user who is in no
    ///            team, which row 1 of the users fixture is. ⚠️ Null and `[]` mean
    ///            the same thing on THIS field — nobody's team membership is
    ///            "unknown" — which is not true of `members` below.
    ///   members  `SchedulingTeam.members`. Null on a team with no members. ⛔ It
    ///            is null on BOTH team fixtures because they are the SAME team seen
    ///            twice, once through `teams.list` and once through `teams.get`,
    ///            and the repetition must not be collapsed: six of the eight
    ///            `teams.*` ops answer a team, and if either read stopped
    ///            populating members that one would fail on its own.
    ///
    /// ⛔ `calendar.status`'s `providers` AND `unconfigured_providers` ARE
    /// DELIBERATELY NOT LISTED, and they are the entries a reader will most expect
    /// to find here. Both are `.nullish()` on the server and both carry REAL ARRAYS
    /// in `district-scheduling-calendar-status.json`, so an entry would be
    /// permission for a null these bytes cannot demonstrate — the same call
    /// `+Inbox.swift` makes for `message.type`. Their null branch is decoded from
    /// inline bytes in `SchedulingAdminCalendarTests` instead, which proves the
    /// Optional without widening the one escape the no-nulls invariant has.
    static let schedulingB: [String: Set<String>] = [
        // ⚠️ THE PATHS ARE INSIDE `$.data` BECAUSE THE FIXTURE IS THE WHOLE RPC
        // ENVELOPE. Every `district-scheduling-*` body is `{ok, data}`, so a path
        // copied from the row's own shape would name nothing and the entry would
        // silently exempt nothing at all.
        //
        // ⚠️ AND `users.list` ANSWERS A BARE ARRAY, so its row index sits directly
        // on `data` with no container key between them. Three envelope conventions
        // live on this API and this is the one that reads wrong at a glance.
        "district-scheduling-users.json": [
            "$.data[1].teams",
        ],
        "district-scheduling-teams.json": [
            "$.data.items[1].members",
        ],
        "district-scheduling-team.json": [
            "$.data.members",
        ],
    ]
}
