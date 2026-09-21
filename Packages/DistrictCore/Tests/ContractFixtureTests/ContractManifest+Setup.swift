import Foundation

// The setup wizard's half of the manifest, in a file of its own for the same `file_length`
// reason as `ContractManifest+DeskSupport.swift`.

extension ContractManifest {
    /// Every allowed-null fixture recorded outside `ContractManifest.swift`, unioned into
    /// ``fixturesWithAllowedNulls`` there so that line stays under the width ceiling.
    static let splitOutFixturesWithAllowedNulls: Set<String> =
        deskAndSupportFixturesWithAllowedNulls.union(setupFixturesWithAllowedNulls)

    /// `district-setup.json` is the real serialised body of `GET /api/district/setup` (a
    /// `ca` workspace mid-wizard, two steps done, `businessFacts` null), gated in
    /// `ImplementedFixtures+Setup.swift`.
    ///
    /// ⚠️ ONE path, `$.businessFacts`, named with its column in
    /// `AllowedExplicitNulls+Setup.swift`.
    static let setupFixturesWithAllowedNulls: Set<String> = [
        "district-setup.json",
    ]
}
