# District AI for iOS

The native iPhone and iPad client for [District AI](https://www.distronode.com/district-ai),
the AI receptionist service by Distronode. It places and answers calls, and covers the
inbox, contacts, meeting rooms and workspace settings of a District AI workspace.

This repository is the client's complete source, under the Apache License 2.0. The
District AI service it talks to is not open source; signing in needs a District AI
account. Without one you can still build the app, run every unit test and run the
signed-out UI tests.

SwiftUI, Swift 6 language mode, iOS 17 and later, on iPhone and iPad (one universal app).

## iPad

On regular width the shell is a sidebar, and the list sections (Calls, Inbox, Contacts,
Desk, Support) get three columns: sidebar, list, detail. On compact width, which includes an
iPad in a narrow Split View, it is the same tab bar as the iPhone. Both layouts read one
navigation state, so a rotation or a Split View resize keeps the section, the open screen
and a call in progress. ⌘1 to ⌘5 switch sections, ⌘N, ⌘F and ⌘R do what they usually do,
and ⌘↩ sends an Inbox reply. Layout follows the width a view is given, never the device
type; `App/Tests/SourceBanTests.swift` enforces that.

## Requirements

- macOS with **Xcode 26.3** (CI selects exactly this version)
- **XcodeGen 2.46** or newer (the Xcode project is generated from `project.yml`)
- Deployment target **iOS 17.0**
- For linting: **SwiftFormat 0.63.0** and **SwiftLint 0.65.1**, the versions CI pins
- `Packages/DistrictCore` also builds and tests on Linux with Swift 6.2
  (`ci/Dockerfile` defines that toolchain)

## Build and test

### DistrictCore (macOS or Linux)

Most of the app's logic lives in the package, and its tests need no simulator, no
network and no account:

```sh
cd Packages/DistrictCore
swift test --enable-code-coverage
cd ../..
ci/coverage-gate.sh        # per-module line-coverage floors
```

### The app (macOS)

```sh
xcodegen generate --spec project.yml

# Build for the simulator. No signing configuration is needed or committed.
xcodebuild build -project DistrictAI.xcodeproj -scheme DistrictAI \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO

# App-target unit tests, on an iPhone and on an iPad simulator.
xcodebuild test -project DistrictAI.xcodeproj -scheme DistrictAI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:DistrictAITests CODE_SIGNING_ALLOWED=NO
xcodebuild test -project DistrictAI.xcodeproj -scheme DistrictAI \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -only-testing:DistrictAITests CODE_SIGNING_ALLOWED=NO

# The signed-out UI tests, as CI runs them.
xcodebuild test -project DistrictAI.xcodeproj -scheme DistrictAI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:DistrictAIUITests/UnauthenticatedTests \
  -only-testing:DistrictAIUITests/LargerTextTests CODE_SIGNING_ALLOWED=NO
```

Use any simulator you have installed; `ci/sim-udid.sh iPhone` (or `iPad`) picks one
the way CI does and writes its udid to `simulator-udid.txt`.

Two things that are expected, not broken:

- **An unsigned build stops at "Try again", not "Sign in".** Without a signing identity
  the app has no Keychain access, so it cannot tell whether a session exists. The
  signed-out UI tests account for this. Running on a device needs your own signing
  team and bundle identifier; push, associated domains and Sign in with Apple are tied
  to the App Store build's team and will not work under yours.
- **Xcode rewrites `Packages/DistrictCore/Package.resolved`** when it resolves the app's
  packages. Restore it with `git checkout -- Packages/DistrictCore/Package.resolved`
  and never commit that change; CI rejects it.

### Lint

From the repository root:

```sh
swiftformat --lint .
swiftlint --strict
```

`--strict` turns every warning into an error. The two tools are configured to agree
with each other, which holds for the pinned versions.

## Repository layout

```
App/                    The SwiftUI app
  Sources/              Features/<Name>/ screens, Navigation/, Platform/ (CallKit,
                        PushKit, LiveKit, audio, notifications), Session/, DesignSystem/
  Tests/                DistrictAITests: app-level logic the package cannot reach
  UITests/              DistrictAIUITests
  SmokeUITests/         An end-to-end smoke suite; needs a demo account from the
                        environment and skips without one
  Shared/               Accessibility identifiers shared by the app and its UI tests
Packages/DistrictCore/  DistrictModel, DistrictAuthCore, DistrictNetwork, DistrictData
                        and DistrictCall: models, API client, repositories, auth and
                        call state machines. Foundation only, no UIKit, SwiftUI or
                        other Darwin-only framework (CI enforces this)
contracts/              JSON contract fixtures from the District AI service
ci/                     The coverage gate and the simulator picker CI runs, and a
                        Dockerfile for the same Linux toolchain
scripts/                The release lane and local test helpers
docs/ARCHITECTURE.md    How the pieces fit together
project.yml             The XcodeGen spec: this is the project; the .xcodeproj is
                        generated and never committed
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module boundaries, navigation
and the call stack.

## The contract gate

`contracts/` holds recorded responses from the District AI API. The service's own test
suite generates them and checks its real responses against them byte for byte; they are
copied here unchanged and are not edited in this repository.

`ContractFixtureTests` (in `Packages/DistrictCore`) holds the app to them. Every fixture
that has a Swift model must decode, re-encode to the same keys at every level, and
contain no `null` outside a reviewed allow-list. So a field the service sends that the
app does not model fails the suite, and so does a hand-written `Codable` that does not
round-trip. The suite also asserts the exact number of fixture files and an explicit
list of fixtures that have no model yet, so a missing directory or a newly added fixture
is a failure rather than a silent pass. Set `DISTRICT_CONTRACTS_DIR` to read the
fixtures from somewhere else.

The strictness is in the tests only. The app's decoders ignore unknown fields, so an
installed app keeps working when the service adds one.

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and
every pull request, and uses no secrets:

- **verify** (Linux, `swift:6.2.4`): SwiftFormat, SwiftLint, the DistrictCore import
  rule, the `Package.resolved` guard, `swift test` and the coverage floors.
- **app** (macOS, Xcode 26.3): generates the project, builds once for testing, then runs
  `DistrictAITests` and the signed-out UI tests on an iPhone and an iPad simulator.

Both fail if a test bundle runs fewer tests than expected, because a bundle that
discovers nothing reports success. **app** runs on every push and pull request. Its
`if:` guard and the `run_app` input matter only if the repository is ever private again:
the free plan bills a private repository's macOS minutes at ten times the Linux rate,
so there **app** runs only when started by hand (`workflow_dispatch` with `run_app`).

## Releases

Releases are archived and uploaded to App Store Connect from a Mac with
`scripts/archive-imac.sh`, not from CI. The App Store Connect API key and the optional
crash-reporting settings are supplied by the operator's environment; none of them is in
this repository. The script refuses a dirty tree or a branch other than `main`, derives
the build number from the commit history, and deletes the archive if the UI-test hooks
are present in the release binary. `scripts/archive-imac.test.sh` tests it against
stubs.

Builds from this repository report no crashes: crash reporting (Sentry) starts only
when a DSN is supplied at build time, and `project.yml` ships it empty.

## Contributing, security and conduct

- [CONTRIBUTING.md](CONTRIBUTING.md): the local gate, the rules CI enforces, and how
  pull requests are reviewed.
- [SECURITY.md](SECURITY.md): report vulnerabilities privately, not in an issue.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- [CHANGELOG.md](CHANGELOG.md).

Questions about a District AI account, number or bill go to
[District AI support](https://www.distronode.com/support).

## Licence and trademarks

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

The District AI and Distronode names, logos and app icon are trademarks of Distronode
Corporation and are not licensed under the Apache License 2.0. A build you distribute
must use your own name, icon and bundle identifier.
