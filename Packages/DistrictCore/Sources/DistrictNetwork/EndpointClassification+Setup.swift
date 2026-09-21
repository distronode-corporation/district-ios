import Foundation

public extension TypedEndpoints {
    /// The setup wizard's read.
    ///
    /// ⛔ TYPED, WITH ITS CONTRACT FIXTURE. `district-setup.json` comes from the shared
    /// corpus and is gated in `ImplementedFixtures+Setup.swift`;
    /// ``DistrictSetupResponse`` is decoded by
    /// `OverviewRepository.needsWebSetup(workspaceId:)`.
    ///
    /// ⚠️ ITS OWN FILE because `EndpointClassification.swift` sits near SwiftLint's
    /// 500-line ceiling, the same reason ``TypedEndpoints/callHandling`` has one.
    static let setup: Set<EndpointID> = [
        .districtSetup,
    ]
}
