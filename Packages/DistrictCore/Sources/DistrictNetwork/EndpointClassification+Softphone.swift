import Foundation

public extension TypedEndpoints {
    /// Ending a direct softphone call at the CARRIER.
    ///
    /// ⚠️ ITS OWN FILE RATHER THAN ONE MORE LINE IN `EndpointClassification.swift`,
    /// which is a lint ceiling and not a taxonomy — that file sits at SwiftLint's
    /// 500-line `file_length` and the commentary on its lists is the point of them.
    /// ``TypedEndpoints/callHandling`` and ``TypedEndpoints/desk`` are the
    /// precedent. ⛔ A family declared here and not unioned into
    /// ``TypedEndpoints/all`` fails `EndpointSurfaceTests`' partition assertion
    /// rather than defaulting to "raw".
    ///
    /// ⛔ ONE ENTRY, AND IT EXISTS BECAUSE `Room.disconnect()` IS NOT A HANG-UP.
    /// Disconnecting removes this device from the room and leaves the SIP
    /// participant in it, so the telephone at the far end goes on ringing or talking
    /// to an empty room and the carrier goes on billing, with nothing failing and
    /// nothing logged. `calls/{id}/hangup` is the
    /// only thing in this client that reaches the carrier leg.
    ///
    /// ⚠️ IT HAS NO CONTRACT FIXTURE, on the same footing as `createContact`,
    /// `searchMessages` and call handling: the shared corpus mirrors the Android
    /// client and that client has no hang-up. What pins the shape is the route source
    /// and `DialHangUpRepositoryTests`.
    /// ⛔ SO `ContractManifest.expectedFixtureCount` MUST NOT MOVE FOR IT. It is
    /// asserted EXACTLY against the files on disk and nothing is on disk.
    ///
    /// ⛔ AND IT IS THE ONE WRITE IN THIS CLIENT THAT IS SAFE TO SEND TWICE, one path
    /// segment from `dial`, which may never be re-sent because a re-send places a
    /// second call. The two rules are opposite and the routes are adjacent; see the
    /// ⛔ on ``DistrictEndpoints/hangUpCall(callId:workspaceId:)``.
    static let softphone: Set<EndpointID> = [.hangUpCall]
}
