import DistrictModel
import Foundation

// The setup wizard's read, in a file of its own because `ImplementedFixtures.swift` is at its
// 500-line ceiling (the same reason `+Persona` and `+MessageThread` exist).

extension ImplementedFixtures {
    /// ⛔ GATED FROM ITS FIRST COMMIT, WITH THE DTO, THE DESCRIPTOR AND THE REPOSITORY
    /// METHOD THAT READS IT. ``DistrictSetupResponse``, `DistrictEndpoints.districtSetup(workspaceId:)` and
    /// `OverviewRepository.needsWebSetup(workspaceId:)` land beside this entry, so the name
    /// is never in `ContractManifest.unimplemented`.
    ///
    /// ⚠️ THE THREE OPAQUE FIELDS (`businessFacts`, `testCallConsent`, `forwardingCheck`) ARE
    /// ``WireJSON``, which round-trips whatever it is handed, so the gate still compares their
    /// contents key for key the day a fixture carries one. This one carries none of them as
    /// an object: `businessFacts` is null (allowlisted) and the other two are absent.
    static var setup: [ImplementedFixture] {
        [
            gate("district-setup.json", DistrictSetupResponse.self),
        ]
    }
}
