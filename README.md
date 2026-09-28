# District AI for iOS

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/distronode-corporation/district-ios/badge)](https://scorecard.dev/viewer/?uri=github.com/distronode-corporation/district-ios)

District AI for iOS is [on the App Store](https://apps.apple.com/app/id6809297970).

Links: [project page](https://www.distronode.com/open-source/district-ios) ·
[GitLab mirror](https://gitlab.com/distronode-corporation/district-ios) (read-only mirror;
issues and pull requests live on GitHub) · [CHANGELOG](CHANGELOG.md)

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

# Build for the simulator. No signing is needed: the project carries no certificates,
# provisioning profiles or DEVELOPMENT_TEAM. ExportOptions.plist names the App Store
# team for the release workflow only.
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
scripts/                The release scripts and local test helpers
docs/ARCHITECTURE.md    How the pieces fit together
ExportOptions.plist     Export settings for the App Store release only
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
- **gitleaks** (Linux): scans the full git history for secrets, with the rules and
  allowlists in [`.gitleaks.toml`](.gitleaks.toml).
- **release scripts** (Linux): tests the release workflow's scripts against stubs.

**verify** and **app** fail if a test bundle runs fewer tests than expected, because a
bundle that discovers nothing reports success.

[`codeql.yml`](.github/workflows/codeql.yml) runs CodeQL over the workflows and the
Swift build, and [`scorecard.yml`](.github/workflows/scorecard.yml) publishes the
OpenSSF Scorecard result behind the badge above.

## Releases

Releases are built, signed and uploaded to App Store Connect by
[`release.yml`](.github/workflows/release.yml), on a GitHub-hosted macOS runner, from a
protected `v*` tag whose name matches `MARKETING_VERSION` and whose commit is on `main`.
A dispatch on `main` builds a TestFlight-only build of `main`. The build number is 4101
plus the commit count, and the workflow refuses a shallow clone, a mismatched tag and any
other branch before it reads a credential.

No signing key or store credential is stored in this repository or in GitHub. The
workflow's `release` environment borrows them from Distronode's Google Cloud for the
length of one run, through workload identity pinned to this repository, that environment
and those refs. Signing is Xcode's automatic signing with an App Store Connect API key.
Every valid build goes to TestFlight's internal testers. Submission for App Review is a
separate step ([`submit.yml`](.github/workflows/submit.yml), or the `submit` job of a
dispatch on a tag) and runs only with the maintainers' explicit approval.

The workflow calls `scripts/archive-imac.sh`, which refuses a dirty tree, deletes the
archive if the UI-test hooks are present in the release binary, and uploads the debug
symbols to Sentry. `scripts/archive-imac.test.sh`, `scripts/release-preflight.test.sh` and
`scripts/asc_release_test.py` test the release scripts against stubs on every pull
request.

Versions up to the current store release (1.2) were built on a maintainer's machine with
the same script, before this workflow existed.

Builds from a fork report no crashes: crash reporting (Sentry) starts only when a DSN is
supplied at build time, and `project.yml` ships it empty. Only the release workflow
supplies one.

## Contributing, security and conduct

- [CONTRIBUTING.md](CONTRIBUTING.md): the local gate, the rules CI enforces, and how
  pull requests are reviewed.
- [SECURITY.md](SECURITY.md): report vulnerabilities privately, not in an issue.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- [SUPPORT](.github/SUPPORT.md): where questions, bugs and account problems go.
- [CHANGELOG.md](CHANGELOG.md).

Questions about a District AI account, number or bill go to
[District AI support](https://www.distronode.com/support).

## License and trademarks

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

District AI, Distronode and the District AI and Distronode logos and app icons are
trademarks of Distronode Corporation. They are not licensed under the Apache License 2.0:
a build you distribute must use its own name, icon and bundle identifier.
