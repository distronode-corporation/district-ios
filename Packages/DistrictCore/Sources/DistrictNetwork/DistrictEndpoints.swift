import Foundation

/// The whole endpoint surface, one static function per route.
///
/// ⛔ THE ONLY WAY TO BUILD AN ``ApiRequestDescriptor``. Its initialiser is
/// internal, so what this type declares is exactly what this client can ask for
/// — see the ⛔ on ``EndpointID``. Adding a route means adding a case there, a
/// function here, and a row in `EndpointTableTests`, and the count assertion in
/// that suite fails if the third is skipped.
///
/// ⚠️ SPLIT ACROSS FILES BY SECTION, MIRRORING `HttpDistrictApi.kt`'S PER-SECTION
/// CLASSES. One file would be past SwiftLint's 800-line ceiling before the traps
/// were written down, and the traps are the point of porting this by hand rather
/// than generating it.
///
/// ⚠️ NOTHING HERE SENDS ANYTHING. A descriptor is a value; ``ApiClient`` is what
/// puts one on a socket. That separation is what lets the table test assert
/// method, path, query and body bytes for every route without a transport at
/// all.
public enum DistrictEndpoints {
    /// Workspaces the signed-in user may operate on.
    ///
    /// ⚠️ TAKES NO `workspaceId` — it is USER-scoped, and is the one district
    /// route guarded by `requireAuth` rather than `requireWorkspaceRole`. An
    /// account with no workspaces gets a normal empty list here, whereas a
    /// workspace-scoped route answers 404 "User has no workspace".
    ///
    /// ⛔ IT CAN FAIL WITH **503 `REGIONS_DEGRADED`**, WHICH IS NOT AN EMPTY
    /// ACCOUNT. "We could not look" rendered as "there is nothing" routes a
    /// paying customer to an onboarding dead end. See `WorkspaceListDegradedError`.
    public static func workspaceList() -> ApiRequestDescriptor {
        ApiRequestDescriptor(.workspaceList, .get, DistrictPaths.workspaceList)
    }

    /// The dashboard landing screen.
    ///
    /// - Parameter workspaceId: ⚠️ PASSING NIL IS LEGAL AND MAKES THE SERVER
    ///   CHOOSE — it falls back to the first workspace of its own membership
    ///   listing. Prefer passing it: this client holds no selection cookie, so
    ///   the server's fallback cannot know which workspace the user picked, and
    ///   omitting it on a multi-workspace account silently reports on the wrong
    ///   one.
    public static func overview(workspaceId: String?) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .overview,
            .get,
            DistrictPaths.overview,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }
}
