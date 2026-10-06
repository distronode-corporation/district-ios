# District AI for iOS

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/distronode-corporation/district-ios/badge)](https://scorecard.dev/viewer/?uri=github.com/distronode-corporation/district-ios)

District AI for iOS is [on the App Store](https://apps.apple.com/app/id6809297970).

Links: [project page](https://www.distronode.com/open-source/district-ios) ·
[GitLab mirror](https://gitlab.com/distronode-corporation/district-ios) (read-only mirror;
issues and pull requests live on GitHub) · [CHANGELOG](CHANGELOG.md)

The native iPhone and iPad client for [District AI](https://www.distronode.com/district-ai),
the AI receptionist service by Distronode. It places and answers calls, and covers the
inbox, contacts, meeting rooms and workspace settings of a District AI workspace.

This repository and [district-core-swift](https://github.com/distronode-corporation/district-core-swift), the Swift package that holds most of
the app's logic, are the client's complete source, under the Apache License 2.0. The
District AI service it talks to is not open source; signing in needs a District AI
account. Without one you can still build the app, run every unit test and run the
signed-out UI tests.

**Without an account with us.** Today this app needs a District AI account to sign in. We
want the District AI apps to work without an account with us too. We have not worked out
what that looks like or whether it can work, and the answer depends on what people would
use them with, so we are asking before we build anything:
[tell us what you would connect them to](https://github.com/distronode-corporation/.github/discussions/1).

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
- The lint tools also run on Linux in the Swift 6.2 image `ci/Dockerfile` defines

## Build and test

### DistrictCore

Most of the app's logic (models, the API client, repositories, auth and the call state
machines) lives in the DistrictCore package, in its own repository, [district-core-swift](https://github.com/distronode-corporation/district-core-swift).
Its tests run there, on macOS or Linux, with no simulator, network or account.
`project.yml` pins the release this app builds against (`exactVersion`), and Xcode
fetches it when it resolves the app's packages. To work on the core and the app
together, see "Changing DistrictCore" in [CONTRIBUTING.md](CONTRIBUTING.md).

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
  Tests/                DistrictAITests: app-level logic DistrictCore cannot reach
  UITests/              DistrictAIUITests
  SmokeUITests/         An end-to-end smoke suite; needs a demo account from the
                        environment and skips without one
  Shared/               Accessibility identifiers shared by the app and its UI tests
ci/                     The simulator picker CI runs, and a Dockerfile for the
                        Linux lint toolchain
scripts/                The release scripts and local test helpers
docs/ARCHITECTURE.md    How the pieces fit together
ExportOptions.plist     Export settings for the App Store release only
project.yml             The XcodeGen spec: this is the project; the .xcodeproj is
                        generated and never committed. It pins DistrictCore
project.local-core.yml  The same spec against a local district-core-swift clone
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module boundaries, navigation
and the call stack.

## The contract gate

The recorded District AI API responses, and `ContractFixtureTests`, which holds every
model to them, live with the models in [district-core-swift](https://github.com/distronode-corporation/district-core-swift). A release of the core
has passed that gate, so a bump here brings models already checked against the service.

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and
every pull request, and uses no secrets:

- **verify** (Linux, `swift:6.2.4`): SwiftFormat and SwiftLint over `App/`.
- **app** (macOS, Xcode 26.3): generates the project, resolves its packages and checks
  every `exactVersion` pin resolved as declared, builds once for testing, then runs
  `DistrictAITests` and the signed-out UI tests on an iPhone and an iPad simulator.
- **gitleaks** (Linux): scans the full git history for secrets, with the rules and
  allowlists in [`.gitleaks.toml`](.gitleaks.toml).
- **release scripts** (Linux): tests the release workflow's scripts against stubs.
- **dependency graph** (Linux): submits the Swift packages **app** resolved to GitHub's dependency graph,
  which cannot see them on its own; on pushes to `main` and pull requests from this
  repository.
- **dependency-review** (Linux, pull requests): fails a pull request that adds a
  dependency with a known moderate-or-worse vulnerability or a licence this project cannot
  ship, compared after the snapshot above has landed.

A bundle that discovers nothing reports success, so CI counts what ran. **app** fails if
`DistrictAITests` runs fewer than 460 or the signed-out UI tests fewer than 7. The first
is a ratchet a little below the current count (about 472), so losing a handful of files fails,
while deleting one or two tests deliberately does not; the UI count is the exact sum of
the classes CI names. DistrictCore's own test floor and coverage gate run in its
repository.

[`codeql.yml`](.github/workflows/codeql.yml) runs CodeQL over the workflows and the
Swift build, and [`scorecard.yml`](.github/workflows/scorecard.yml) publishes the
OpenSSF Scorecard result behind the badge above.

## Releases

Releases are built, signed and uploaded to App Store Connect by
[`release.yml`](.github/workflows/release.yml), on a GitHub-hosted macOS runner, from a
protected `v*` tag whose name matches `MARKETING_VERSION` and whose commit is on `main`.
A dispatch on `main` builds a TestFlight-only build of `main`. The build number is 4101
plus the commit count, and the workflow refuses a shallow clone, a mismatched tag and any
other branch before it reads a credential, then a build number App Store Connect already
has for that version (a tag of a commit a `main` dispatch already uploaded) before it
builds anything.

No signing key or store credential is stored in this repository or in GitHub. The
workflow's `release` environment borrows them from Distronode's Google Cloud for the
length of one run, through workload identity pinned to this repository, that environment
and those refs. Signing is Xcode's automatic signing with an App Store Connect API key.
Every valid build goes to TestFlight's internal testers. Submission for App Review is a
separate step ([`submit.yml`](.github/workflows/submit.yml), or the `submit` job of a
dispatch on a tag) and runs only with the maintainers' explicit approval.

A dispatch with `build_only` archives and signs on the runner and stops there: nothing is
uploaded or submitted, and the run's summary shows the signature it verified.

What's New is the version's `CHANGELOG.md` section for English and
`release-notes/<locale>/<version>.txt` (for example `release-notes/fr-CA/2.1.txt`, plain text
exactly as the store shows it) for every other language, as on district-android. A
localization in a language with no notes stops the submission; English is never sent in its
place.

Each version gets its GitHub Release, the source of that App Store release, once App
Store Connect has it on sale: `submit.yml` checks after each submission and every six
hours, and `scripts/github-release.sh` publishes it with the version's `CHANGELOG.md`
section. It never publishes at submission: Releases here are immutable, so the tag could
never move again, even to fix a version Apple turned down.

The workflow calls `scripts/archive-imac.sh`, which refuses a dirty tree, deletes the
archive if the UI-test hooks are present in the release binary, and uploads the debug
symbols to Sentry. `scripts/archive-imac.test.sh`, `scripts/release-preflight.test.sh`,
`scripts/asc-key.test.sh`, `scripts/github-release.test.sh` and
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
