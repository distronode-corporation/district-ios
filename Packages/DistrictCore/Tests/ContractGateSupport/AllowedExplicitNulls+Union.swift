import Foundation

// ⛔ THIS FILE EXISTS BECAUSE OF A LINE CEILING, NOT A BOUNDARY IN THE DOMAIN.
// `AllowedExplicitNulls.swift` sits at swiftlint's 500-line `file_length` (which
// `--strict` promotes to an error), so the union of every table lives here. That
// union TRAPS on a duplicate key rather than choosing a winner: see the ⛔ there.
//
// ⚠️ THE COUNT STAYS ASSERTED BY `ContractManifest.expectedAllowedNullPaths`,
// never by a comment in either file, because a stated total goes stale exactly
// when two changes land at once.

public extension StrictDecodeVerifier {
    /// The whole table the gate consults: the core entries unioned with every
    /// split-off group.
    ///
    /// ⛔ THE COLLISION CLOSURE TRAPS RATHER THAN PICKING A SIDE. The key sets
    /// are disjoint by construction, so a duplicate means one fixture was granted
    /// permission twice, in two files, by two changes that could not see each
    /// other. Keeping either side would silently
    /// drop the other's paths, widening the single escape the no-nulls invariant
    /// has.
    ///
    /// ⚠️ THE UNION OF EVERY GROUP LIVES HERE. Each `AllowedExplicitNulls+*.swift`
    /// file is split off for the same line ceiling; the trap generalises unchanged
    /// because `merging` is applied pairwise and each application traps. ⛔ A group
    /// declared in a new file and NOT chained in here would silently exempt
    /// nothing, and its fixture would then fail the gate for a reason nobody would
    /// look for — so add the `.merging` in the same commit as the group.
    static let allowedExplicitNulls: [String: Set<String>] = base
        .merging(inbox) { _, _ in
            preconditionFailure("a fixture appears in both allowed-null tables")
        }
        // ⚠️ `AllowedExplicitNulls+SchedulingB.swift`: the bookings, calendar, users
        // and teams half of the scheduling admin surface.
        .merging(schedulingB) { _, _ in
            preconditionFailure("a fixture appears in both allowed-null tables")
        }
        // ⚠️ `AllowedExplicitNulls+SchedulingC.swift`: the settings, recordings,
        // developer and upload half of the scheduling admin surface.
        .merging(schedulingC) { _, _ in
            preconditionFailure("a fixture appears in both allowed-null tables")
        }
        // ⚠️ `AllowedExplicitNulls+SchedulingA.swift`: the event-type and
        // availability half of the same surface.
        // ⛔ Position is not semantics: `merging` is applied pairwise and every
        // application traps on a duplicate key, so their order is free.
        .merging(schedulingA) { _, _ in
            preconditionFailure("a fixture appears in both allowed-null tables")
        }
        // ⚠️ `AllowedExplicitNulls+Meetings.swift`, kept out of the core table for
        // the line ceiling.
        .merging(meetings) { _, _ in
            preconditionFailure("a fixture appears in both allowed-null tables")
        }
        // ⚠️ `AllowedExplicitNulls+DeskSupport.swift`, for the desk and helpdesk
        // fixtures.
        .merging(deskAndSupport) { _, _ in
            preconditionFailure("a fixture appears in both allowed-null tables")
        }
        // ⚠️ `AllowedExplicitNulls+Setup.swift`, the setup wizard's read.
        .merging(setup) { _, _ in
            preconditionFailure("a fixture appears in both allowed-null tables")
        }
}
