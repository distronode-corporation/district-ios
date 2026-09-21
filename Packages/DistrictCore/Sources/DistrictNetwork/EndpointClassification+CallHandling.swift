import Foundation

public extension TypedEndpoints {
    /// Who answers a call, and whether this person can be rung.
    ///
    /// ⛔ FOUR ENTRIES FOR TWO PATHS, because each route is GET + PATCH — the same "a
    /// path is not an endpoint" arithmetic `desk/settings` makes, and what lets
    /// `EndpointTableTests` assert a method per entry so a read cannot be expressed as
    /// a write.
    ///
    /// ⛔ TWO PATHS AND TWO SCOPES, WHICH IS THE ONE THING TO CARRY AWAY FROM THIS
    /// LIST. `call-handling` is a WORKSPACE setting every member shares.
    /// `availability` is a fact about the CALLER'S OWN membership row, and its PATCH
    /// takes no email and no user id — so nothing in this client can express "set
    /// someone else's availability", and no screen may imply it can.
    ///
    /// ⛔ NEVER UNTYPED: the four descriptors, `CallHandlingResponses.swift` and
    /// ``DistrictData``'s `CallHandlingRepository` belong together, so no screen can
    /// reach one of these routes and get bytes back.
    ///
    /// ⚠️ ALL FOUR HAVE NO CONTRACT FIXTURE, a property of the CORPUS rather than a
    /// lowered bar, like `createContact` and `searchMessages`: the shared corpus
    /// mirrors the Android client and that client has no call-handling surface. What
    /// pins the shapes is the route source and `CallHandlingRepositoryTests`.
    /// ⛔ SO `ContractManifest.expectedFixtureCount` MUST NOT MOVE FOR THEM. It is
    /// asserted EXACTLY against the files on disk and nothing is on disk; bumping
    /// it to "account for" these would red the fixture suite.
    ///
    /// ⚠️ BOTH PATCHES ECHO THE VALUES THEY WROTE, which makes them the first writes on
    /// the workspace surface that need no re-read. Every save on
    /// `workspace/{persona,tools,directory,routing-rules}` answers a bare
    /// `{"success": true}` and forces one; a caller copying that pattern here would
    /// spend a request to learn what it was already told.
    ///
    /// ⚠️ ITS OWN FILE RATHER THAN FOUR MORE LINES IN `EndpointClassification.swift`,
    /// which is a lint ceiling and not a taxonomy — that file sits under SwiftLint's
    /// 500-line limit and the commentary on those lists is the point of them. See the
    /// ⚠️ on ``TypedEndpoints/all``, and ``TypedEndpoints/desk`` for the precedent.
    static let callHandling: Set<EndpointID> = [
        .callHandling,
        .saveCallHandling,
        .availability,
        .saveAvailability,
    ]
}
