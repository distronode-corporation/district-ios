// swift-tools-version: 6.2
//
// DistrictCore — the Linux-testable half of the District iOS app.
//
// ⛔ THIS PACKAGE MUST KEEP BUILDING AND TESTING ON LINUX, AND THAT IS THE WHOLE
// POINT OF IT. macOS CI time is scarce and expensive and is reserved for the
// app build and its simulator tests. Everything that can be tested on an
// ordinary Linux CI machine lives here, and the app target in App/ stays thin.
//
// The rule that keeps that true is enforced by CI (the `verify` job greps the
// sources): these targets import only Foundation / FoundationNetworking.
// UIKit, SwiftUI, Security (Keychain), AuthenticationServices and LiveKit live
// in App/ behind protocols declared here.
//
// ⚠️ EXACTLY ONE EXTERNAL DEPENDENCY:
// apple/swift-crypto, for SHA-256. It is the only way to hash on Linux — Darwin
// has CryptoKit, corelibs-foundation has nothing — and hashing is not optional
// here, since PKCE's S256 challenge is what makes an intercepted authorization
// code worthless.
//
// ⛔ PINNED WITH `.exact`, NOT A RANGE. A floating range lets a dependency move
// under a build whose output eventually reaches the App Store, with nothing
// in the diff to notice. Bumping it is a one-line reviewed change
// plus a regenerated Package.resolved.
//
// ⛔ AND `Package.resolved` MUST BE COMMITTED. Without it CI resolves against
// whatever swift-crypto tags exist at build time and the pin above enforces
// nothing. A blanket `*.json` ignore rule swallows it silently — `git status`
// says nothing, because an ignored file is not an untracked file, and `git add`
// skips it while reporting success.
//
// ⚠️ swift-crypto pulls apple/swift-asn1 transitively. That is a second
// checked-out dependency, recorded in Package.resolved, and it is why the
// resolved file is worth committing at all.
import PackageDescription

/// ⚠️ Swift 6 language mode is stated EXPLICITLY rather than inherited from the
/// tools version. It is already the default at tools-version 6.x, but this
/// package is destined to be consumed by an Xcode app target whose own default
/// can differ, and complete strict concurrency checking is load-bearing for the
/// TokenRefreshCoordinator actor.
let districtSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "DistrictCore",
    // Deployment targets for the Darwin consumer. Ignored on Linux, where the
    // package builds against whatever the toolchain's Foundation provides.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DistrictModel", targets: ["DistrictModel"]),
        .library(name: "DistrictAuthCore", targets: ["DistrictAuthCore"]),
        .library(name: "DistrictNetwork", targets: ["DistrictNetwork"]),
        .library(name: "DistrictData", targets: ["DistrictData"]),
        .library(name: "DistrictCall", targets: ["DistrictCall"]),
    ],
    // ⚠️ AFTER `products:`. `Package.init` is not a free-form argument list —
    // SwiftPM's manifest API pins the order and a `dependencies:` block moved
    // above `products:` fails manifest COMPILATION, which reports as
    // "Invalid manifest" rather than as an argument-order problem.
    dependencies: [
        // 5.0.0 is stable (released 2026-09-16) and needs Swift 6.2. Only SHA-256
        // is used (PKCE and the Apple sign-in nonce, both in DistrictAuthCore), so
        // the 5.0 API changes do not reach this package. Builds clean under swift
        // 6.2.4 in Swift 6 language mode on Linux, which is the tier that has to
        // keep working.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0"),
    ],
    targets: [
        // Codable DTOs and the single normalised error type. Depends on nothing.
        .target(
            name: "DistrictModel",
            swiftSettings: districtSwiftSettings
        ),
        // PKCE, token refresh coordination and sign-out. Pure logic; the token
        // STORE is a protocol here and a Keychain implementation in App/.
        //
        // ⛔ `Crypto` (swift-crypto), NOT `CryptoKit`. CryptoKit is Darwin-only
        // and importing it would end the Linux tier — the same class of break
        // the banned-import grep in CI catches for UIKit and Security.
        // swift-crypto's API is CryptoKit's, so the App target sees no
        // difference.
        .target(
            name: "DistrictAuthCore",
            dependencies: [
                "DistrictModel",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: districtSwiftSettings
        ),
        // Every endpoint, path construction, error-envelope normalisation.
        // The HTTP transport is a seam so libcurl-vs-Darwin URLSession
        // differences never reach feature code.
        .target(
            name: "DistrictNetwork",
            dependencies: ["DistrictModel"],
            swiftSettings: districtSwiftSettings
        ),
        // Repositories and paging over DistrictNetwork.
        .target(
            name: "DistrictData",
            dependencies: ["DistrictModel", "DistrictNetwork"],
            swiftSettings: districtSwiftSettings
        ),
        // Everything about a call that is not the media SDK and not the OS's own
        // call registry: the engine seam, the outbound and inbound state
        // machines, and the commands they emit.
        //
        // ⛔ A SEPARATE TARGET RATHER THAN MORE `DistrictData`, AND THE REASON IS
        // THE BANNED-IMPORT GREP. The App links LiveKit and CallKit and
        // implements ``CallEngine`` on top of them; CI's `verify` job fails on
        // an `import LiveKit`, `import CallKit` or `import PushKit` anywhere
        // under Sources/, so the protocols those frameworks satisfy have to live
        // in a target that provably contains none of them. Keeping them in their
        // own module also states the direction of the dependency: App depends on
        // DistrictCall, and nothing here can reach back.
        //
        // ⚠️ `DistrictModel` ONLY, AND DELIBERATELY NOT `DistrictNetwork`. The
        // machines take a url/token pair as two strings and never make a request
        // — the round trips are COMMANDS their owner performs — so a dependency
        // on the client would let a state machine start calling routes. The one
        // thing it does take from the model layer is `DialResponse`, so the
        // "used verbatim" rule about that credential pair is stated once.
        .target(
            name: "DistrictCall",
            dependencies: ["DistrictModel"],
            swiftSettings: districtSwiftSettings
        ),

        // ⛔ TEST INFRASTRUCTURE, DELIBERATELY UNDER Tests/ AND NOT UNDER
        // Sources/. This is the strict contract gate — the
        // assert/decode/re-encode/compare walk that stands in for the
        // `ignoreUnknownKeys = false` that JSONDecoder does not have. It is a
        // plain library target rather than a test target because several test
        // targets will use it and because it has to be importable, but its
        // PATH is what matters: ci/coverage-gate.sh scopes coverage to
        // `/Sources/`, so putting the gate here keeps it out of the floors it
        // would otherwise inflate — it is a hundred percent exercised by
        // construction and would flatter every module it was counted against.
        //
        // ⚠️ It links only Foundation. It must never depend on a DistrictCore
        // library: a gate that imported the module it verifies could not be
        // used to verify a second one without dragging the first along.
        .target(
            name: "ContractGateSupport",
            path: "Tests/ContractGateSupport",
            swiftSettings: districtSwiftSettings
        ),

        // ⛔ ONE TEST TARGET PER LIBRARY TARGET, EACH WITH AT LEAST ONE REAL
        // TEST. `swift test` on a target that discovers nothing succeeds, and
        // ci/coverage-gate.sh requires every configured module to appear in the
        // coverage report precisely so a module that stops being exercised
        // fails loudly instead of reporting a comfortable total.
        .testTarget(
            name: "DistrictModelTests",
            dependencies: ["DistrictModel"],
            swiftSettings: districtSwiftSettings
        ),
        // ⚠️ DEPENDS ON `ContractGateSupport` FOR ONE FIXTURE, AND THAT IS NOT
        // THE CONTRACT GATE LEAKING. `PKCEVectorTests` asserts this module's
        // S256 derivation against `district-pkce-vectors.json`, which is
        // generated from the SERVER's own implementation.
        // A self-consistency test would pass happily while both sides were
        // wrong in the same way, and the server reports the disagreement as one
        // opaque `invalid_grant` — so this is the only place that failure can be
        // caught. It reuses the loader purely for the non-empty-directory guard;
        // the fixture carries no DTO and stays in
        // `ContractManifest.unimplemented`. Kotlin does exactly this, in
        // core-auth rather than in its contract module.
        .testTarget(
            name: "DistrictAuthCoreTests",
            dependencies: ["DistrictAuthCore", "ContractGateSupport"],
            swiftSettings: districtSwiftSettings
        ),
        .testTarget(
            name: "DistrictNetworkTests",
            dependencies: ["DistrictNetwork"],
            swiftSettings: districtSwiftSettings
        ),
        .testTarget(
            name: "DistrictDataTests",
            dependencies: ["DistrictData"],
            swiftSettings: districtSwiftSettings
        ),
        .testTarget(
            name: "DistrictCallTests",
            dependencies: ["DistrictCall"],
            swiftSettings: districtSwiftSettings
        ),

        // ⛔ THE CROSS-CUTTING EXCEPTION TO THE ONE-TEST-TARGET-PER-LIBRARY RULE
        // ABOVE, AND IT IS ON PURPOSE. The contract gate is not a test OF
        // DistrictModel; it is the iOS half of a two-sided gate whose other
        // halves are the server's test suite and the Android client's JVM
        // tests, and it verifies the shared fixture corpus of recorded server
        // responses. Folding it into
        // DistrictModelTests would bury a corpus-wide gate inside a module's
        // unit tests and make "which suite went red" ambiguous the first time a
        // fixture is regenerated.
        //
        // ⚠️ IT READS FILES FROM OUTSIDE THE PACKAGE, a deliberate trade for
        // having one shared corpus. The mitigation is a non-empty-directory guard plus an
        // exact fixture count, so a broken path is RED rather than a green run
        // that verified nothing — the same guard the Kotlin loader carries.
        .testTarget(
            name: "ContractFixtureTests",
            dependencies: ["ContractGateSupport", "DistrictModel"],
            path: "Tests/ContractFixtureTests",
            swiftSettings: districtSwiftSettings
        ),
    ]
)
