import Foundation

/// ⛔ THE COORDINATION POINT FOR THE SHARED FIXTURE CORPUS. Both numbers below
/// describe the contract corpus that ``ContractFixtures`` reads, which the server
/// generates and the Android client owns. When a fixture is ADDED there, this
/// file is patched in the same commit: bump ``expectedFixtureCount`` and add the
/// new name to ``unimplemented``. When a DTO lands for a fixture, remove its name
/// from ``unimplemented`` and add it to `ImplementedFixtures`.
///
/// ⛔ THE COUNT IS ASSERTED EXACTLY, NOT AS A FLOOR, AND THAT IS THE WHOLE
/// POINT. A floor (`>= 1`) would go green against a broken path that happened to
/// resolve to some other directory, and would never notice a fixture the server
/// team added and nobody wired in. An exact count turns both into a one-line
/// failure that says which names it did not expect.
///
/// ⚠️ IT WILL FAIL THE DAY A FIXTURE IS ADDED, AND THAT IS THE DESIGN. The fix
/// is two lines here, and the failure is the only thing that makes a new
/// endpoint's arrival visible to this client at all — nothing else on the iOS
/// side watches the generator.
enum ContractManifest {
    /// Every `.json` file in the contract corpus.
    ///
    /// ⚠️ THIS NUMBER COUNTS THE CORPUS, NOT THE BURN-DOWN. Porting a DTO moves a
    /// name from ``unimplemented`` into `ImplementedFixtures` and leaves this count
    /// alone; only a file arriving on (or leaving) disk moves it. Keeping the two
    /// numbers separate is what lets each one fail for exactly one reason.
    ///
    /// ⚠️ A LARGE JUMP IS HANDLED THE SAME WAY AS A SMALL ONE — a red count naming
    /// every unexpected file. The size is what tempts someone to reach for a floor
    /// instead; a floor would go green against all of them and against a broken
    /// path.
    ///
    /// ⚠️ The Android client asserts the same number
    /// (`ContractManifest.EXPECTED_FIXTURE_COUNT`), and the two move together.
    static let expectedFixtureCount = 164

    /// Fixtures with no Swift DTO yet.
    ///
    /// ⛔ ONE EXPLICIT LIST, NEVER A PATTERN OR A "SKIP IF NO DTO" FALLBACK. A
    /// rule that derives the skip set from what happens to be implemented cannot
    /// distinguish "not ported yet" from "silently stopped being verified", and
    /// the counted summary the suite prints would then be counting itself. Every
    /// entry here is a debt someone wrote down.
    ///
    /// ⛔ STALE ENTRIES ARE A HARD FAILURE, IN BOTH DIRECTIONS. A name here that
    /// is not on disk means the corpus moved under us; a name here that IS
    /// implemented means the burn-down stopped being true. `ContractFixtureTests`
    /// checks both.
    ///
    /// ⛔ "HELD BACK" IS A CLAIM WITH AN EXPIRY DATE AND NOTHING RE-CHECKS IT, so
    /// an entry kept here while a shape settles is removed the moment it settles
    /// rather than annotated. Nothing on this list is held back: every entry is
    /// genuinely unported.
    ///
    /// ⚠️ THE NO-NULLS INVARIANT DOES NOT BLOCK THIS LIST. A fixture carrying
    /// legitimate explicit nulls from nullable columns is gated through per-path
    /// entries in `StrictDecodeVerifier.allowedExplicitNulls`, each naming the
    /// column it describes, rather than held out here.
    ///
    /// ⚠️ `district-workspace-billing-null-usage.json` LOOKS LIKE IT BELONGS WITH
    /// THE USAGE TRIO AND DOES NOT. It is `workspace/billing`'s own envelope, which
    /// carries a `usage` key of its own; the metered-usage route is a different
    /// endpoint with a different body, and pairing them would gate a fixture
    /// against a DTO that does not model it.
    /// ⚠️ The two surfaces do share the INNER type — `getUsage` feeds both and the
    /// server asserts the payloads byte-identical — so `UsageMonth` is reused
    /// while the envelopes stay apart. See `ImplementedFixtures.billing`.
    static let unimplemented: Set<String> = [
        // ⛔ GATING AN ENTRY HERE BEFORE ITS TYPE EXISTS WOULD MEAN INVENTING THE TYPE
        // TO GATE IT AGAINST, which is exactly the "a DTO that nothing decodes is a
        // fixture test, not a client" failure the ⚠️ at the top of `UntypedEndpoints`
        // describes. An entry leaves this list together with its DTO, its descriptor
        // and the repository method that decodes it.
        "district-pkce-vectors.json",
    ]

    /// Every fixture with an `allowedExplicitNulls` entry.
    ///
    /// ⛔ RECORDED HERE, SEPARATELY FROM THE TABLE ITSELF, SO GROWING THE
    /// ALLOWLIST TAKES TWO EDITS IN TWO FILES. That is the same shape as the
    /// fixture count above and exists for the same reason: the one thing that
    /// must never happen quietly is a null being waved through, and a constant
    /// that is only ever read by the code it constrains constrains nothing.
    static let fixturesWithAllowedNulls: Set<String> = splitOutFixturesWithAllowedNulls.union([
        "district-analytics-new-workspace.json",
        // ⛔ THREE BILLING BODIES, AND ON TWO OF THEM THE NULLS ARE THE ENTIRE
        // BODY. `-no-customer` and `-unavailable` are the same six keys with the
        // same three nulls, and the ONLY thing that tells "we could not ask
        // Stripe" apart from "this account has no billing" is an absent
        // `billingUnavailable` key beside them — so the allowlist has to permit
        // the same three paths twice rather than once, and a reader who tidied
        // one of them away would be deleting the distinction. ⚠️ The healthy body
        // nulls two paths only, both on the UNPAID invoice: Stripe omits the
        // hosted URL and the PDF until an invoice is finalised, which makes the
        // most ordinary row there is — this month's, before it is paid — the one
        // that would throw on a client typing them non-null.
        "district-billing-no-customer.json",
        "district-billing-unavailable.json",
        "district-billing.json",
        "district-call-detail.json",
        "district-calls.json",
        // ⛔ TWO PATHS, AND THEY ARE THE WHOLE POINT OF THIS FIXTURE. It is the
        // workspace that has never opened the campaigns tab, and the route
        // NORMALISES absent and off into one rendering, so both configuration
        // fields arrive as explicit nulls beside `infiniteSdrEnabled: false`.
        // ⛔ `sdrBatchSize` IS NULL RATHER THAN 0 deliberately: the settings PATCH
        // floors it to at least 1, so 0 is a value that cannot be stored and could
        // only ever mean the client invented one for a figure that decides how many
        // people get called. ⚠️ And an empty `sdrCampaignGoal` collapses to null
        // server-side, so "typed nothing" and "never opened the tab" are one state
        // on the wire rather than two.
        "district-campaign-status-empty.json",
        "district-contact-detail.json",
        "district-contacts.json",
        "district-conversations.json",
        "district-devices.json",
        "district-draft-null.json",
        "district-drafts-list.json",
        // ⛔ ONE PATH, AND IT IS THE PASTED DOCUMENT. `KnowledgeDocument.sourceUrl`
        // is the family's only nullable column, and the list route serialises its
        // Prisma selection whole, so row 0 (a document somebody typed in) arrives
        // with the key present and null. ⚠️ Its sibling
        // `district-knowledge-create.json` needs NO entry and must not be given
        // one: the create route's `select` OMITS `sourceUrl` entirely, so there is
        // no null there to permit, and a nil Optional already round-trips an absent
        // key. Two fixtures, one nullable field, and only one of them is a null.
        "district-knowledge.json",
        // ⛔ THREE PATHS, ALL ON ROW 0, AND THEY ARE ONE FACT: a meeting that has
        // not ended. The Companion writes the minutes when the room closes, so
        // an in-progress meeting has no `summaryPreview`, no `endedAt` and no
        // `title` — and that row is the one most likely to be at the TOP of a
        // live user's list, which is what makes it the ordinary case rather than
        // an edge one. ⚠️ Row 1 nulls nothing, which is why one fixture covers
        // both branches and why a DTO regressing either Optional fails here
        // rather than on a phone. ⚠️ `district-meeting-detail.json` needs NO
        // entry and must not be given one: the detail route returns the whole
        // row and this fixture's copy happens to have every column populated.
        "district-meetings.json",
        // ⛔ ONE PATH, AND IT IS THE ROUTE'S ORDINARY STATE RATHER THAN AN EDGE.
        // `$.message.readAt` is null while nobody on the team has opened the message —
        // which is why a push was sent, so a resolver serving a notification sees this
        // more often than not. ⚠️ The route sends the key rather than omitting it
        // deliberately: it is what lets a shade drop a "Mark read" action that would do
        // nothing, since the inbox is workspace-level and a colleague may have opened
        // the thread between the push and the tap.
        // ⚠️ AND THE OTHER TWO OPTIONALS ON THAT RESPONSE GET NO ENTRY AND MUST NOT.
        // `message.type` and `thread.contactId` are both nullable server-side and both
        // carry a real value in this fixture; an entry is PERMISSION rather than a
        // requirement, so listing them would silence a null nobody has checked. Those
        // branches are decoded from bytes in `InboxThreadResolveTests` instead.
        "district-message-thread.json",
        // ⛔ ONE PATH, AND IT IS THE WHOLE POINT OF THIS FIXTURE'S EXISTENCE. A
        // workspace the platform holds no numbers for gets `managedAccount: null`,
        // which is a different fact from an empty `accounts` array and has to stay
        // distinguishable. ⚠️ Its sibling `defaultAccountId` is ABSENT in the same
        // body rather than null, so it gets no entry and must not be given one.
        "district-messaging-unmanaged.json",
        "district-overview.json",
        // ⚠️ ALL FIVE SCHEDULING TENANCY FIXTURES NEED AN ENTRY, WHICH IS UNUSUAL AND IS A
        // PROPERTY OF THE SURFACE RATHER THAN OF THE DTOs. Both routes serialise
        // a Prisma selection (or a `?? null` on it) rather than building a sparse
        // object, so every column that has no value arrives as an explicit null —
        // and the four status fixtures exist precisely to cover the states where
        // different columns are the empty ones.
        "district-scheduling-enable.json",
        "district-scheduling-status-error.json",
        "district-scheduling-status-legacy.json",
        "district-scheduling-status-provisioning.json",
        "district-scheduling-status-ready.json",
        // ⛔ THREE OF THE SIXTEEN BOOKINGS, CALENDAR, USERS AND TEAMS FIXTURES, AND
        // THE OTHER THIRTEEN MUST NOT BE GIVEN AN ENTRY. One fact three times: a Go
        // slice the fork marshals WITHOUT `omitempty` arrives as an explicit `null`,
        // which is why `userSchema.teams` and `teamSchema.members` are `.nullish()`
        // where every optional array beside them is `.optional()`. ⛔ The two team
        // entries are the SAME team through `teams.list` and `teams.get` and must not
        // be collapsed — either read has to be able to fail alone.
        // ⚠️ `district-scheduling-calendar-status.json` IS THE ENTRY A READER WILL
        // EXPECT AND IS DELIBERATELY ABSENT: its two `.nullish()` lists carry REAL
        // ARRAYS in the bytes, and an entry is permission for a null they demonstrate.
        // The null branch is proved inline in `SchedulingAdminCalendarTests` instead.
        "district-scheduling-team.json",
        "district-scheduling-teams.json",
        "district-scheduling-users.json",
        // ⛔ THREE OF THE FIFTEEN SETTINGS AND DEVELOPER FIXTURES, same mechanism as the
        // team entries above.
        // Columns, and the three deliberate absences: `AllowedExplicitNulls+SchedulingC.swift`.
        "district-scheduling-api-keys.json",
        "district-scheduling-oauth-connections.json",
        "district-scheduling-webhooks.json",
        "district-usage-empty.json",
        // ⛔ FIVE PATHS ACROSS THE TWO AUTOMATION READS, AND EVERY ONE IS A STATE.
        // The list nulls `latestRun` on a workflow that has never fired; the run
        // history nulls `error` on the three runs that did not fail as a whole, and
        // nulls `finishedAt` on the one run that never finished. ⚠️ The failed run is
        // the interesting pairing: `finishedAt` null WITH a real `error` and an EMPTY
        // `actionResults`, because the engine threw before any action ran.
        "district-workflow-runs.json",
        "district-workflows.json",
        // ⛔ TWO PATHS AND THEY ARE THE TWO HALVES OF ONE STATE: a workspace that
        // hit a hard cap and stopped paying is exactly the one with no metered
        // rows this month. `subscriptionTier` null is NOT "Free" (this route
        // passes the column through untouched where `/api/settings` substitutes
        // a word), and `usage` null is NOT zero — a column of zeros beside a cap
        // that says calls are being refused states something nothing measured.
        // ⚠️ `district-workspace-billing.json` needs no entry: the same six keys
        // are all populated there, which is what makes the pair worth having.
        "district-workspace-billing-null-usage.json",
        "district-workspace-config-sparse.json",
        "district-workspace-config.json",
        "district-workspace-list-partial.json",
        "district-workspace-list.json",
        // ⛔ NINE OF THE TWELVE, AND THE OTHER THREE MUST NOT BE GIVEN AN ENTRY —
        // `-hosts`, `-test-email` and `-override-range` carry no null at all. Every
        // path is justified in `AllowedExplicitNulls+SchedulingA.swift`.
        "district-scheduling-event-type.json",
        "district-scheduling-event-types.json",
        "district-scheduling-override-created.json",
        "district-scheduling-overrides.json",
        "district-scheduling-question.json",
        "district-scheduling-questions.json",
        "district-scheduling-rule.json",
        "district-scheduling-rules.json",
        "district-scheduling-slots.json",
    ])

    /// How many exact JSON paths those entries name in total.
    ///
    /// ⚠️ THE NUMBER IS LARGE BECAUSE THE PATHS ARE EXACT, NOT BECAUSE THE
    /// SURFACE IS LOOSE. Many of them are the SAME nullable call columns written
    /// out per row across the fixtures that re-serve one server-side mapping. A
    /// wildcard would make this read as a handful; it would also silence rows
    /// that do not exist yet.
    ///
    /// ⛔ RECORDED SEPARATELY FROM THE TABLE, SO GROWING THE ALLOWLIST TAKES TWO
    /// EDITS. The count is asserted against the table, so a wrong sum here fails
    /// the suite rather than quietly widening the one escape the no-nulls
    /// invariant has.
    ///
    /// ⚠️ MANY FIXTURES ADD NOTHING, AND THAT IS THE HALF WORTH KNOWING. The
    /// optional fields on most surfaces are ABSENT keys rather than nulls
    /// (`JSON.stringify` drops an undefined rather than writing null), and a nil
    /// Optional already round-trips an absent key, so permission for a null there
    /// would be permission for a shape the server does not send. The same goes for
    /// a nullable column that carries a real value in its fixture: an entry is
    /// PERMISSION rather than a requirement, and listing it would silence a null
    /// nobody has checked.
    ///
    /// ⛔ REPEATED PATHS ACROSS SIBLING FIXTURES ARE NOT DUPLICATION AND MUST NOT BE
    /// COLLAPSED. `district-billing-unavailable.json` and
    /// `district-billing-no-customer.json` hold the SAME three paths because they
    /// are the same body, and the only thing separating a Stripe outage from an
    /// account with no billing is one key that is absent rather than null.
    ///
    /// Each path is named with its column in the `AllowedExplicitNulls*.swift` files.
    static let expectedAllowedNullPaths = 190
}
