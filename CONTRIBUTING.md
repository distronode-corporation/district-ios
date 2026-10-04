# Contributing to District AI for iOS

Thanks for helping. The [README](README.md) covers requirements, the layout and how to
build; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) covers how the pieces fit together.
This file is the rules a change has to meet.

## The inner loop

Most of the app's logic lives in the DistrictCore package, in [district-core-swift](https://github.com/distronode-corporation/district-core-swift),
and its inner loop is `swift test` there: no simulator, no network and no account, on
macOS or Linux. Most logic belongs in the package precisely so that loop can test it.
In this repository the loop is the lint below plus `DistrictAITests` on a simulator.

## The whole local gate

This is what CI runs, in order:

```sh
swiftformat --lint .                          # SwiftFormat 0.63.0
swiftlint --strict                            # SwiftLint 0.65.1
xcodegen generate --spec project.yml
# then, on an iPhone and on an iPad simulator:
#   DistrictAITests, and DistrictAIUITests/UnauthenticatedTests + LargerTextTests
# (the README has the xcodebuild commands)
```

CI also checks that every `exactVersion` package in `project.yml` resolved at exactly
that version. It runs `gitleaks git .` (gitleaks 8.30.1) over the full history too, with
`.gitleaks.toml`; run it locally if you have it.

## Changing DistrictCore

DistrictCore is not edited here. It lives in {CORE}, and a change to
it goes **upstream first**: a pull request there, which runs the package's own gates
(its test floor, 100% line coverage, the Foundation-only import rule and the contract
fixtures), then a tagged release, then a pull request here that moves `exactVersion` in
`project.yml` to that tag. The app only ever builds a released core.

To work on both at once, clone district-core-swift beside this repository, so that
`../district-core-swift` is its root, and generate the project from the local-core spec:

```sh
git clone https://github.com/distronode-corporation/district-core-swift ../district-core-swift
xcodegen generate --spec project.local-core.yml   # DistrictCore from ../district-core-swift
xcodegen generate --spec project.yml              # back to the pinned release
```

`project.local-core.yml` is `project.yml` with the DistrictCore package swapped for that
path; with your clones elsewhere, symlink `../district-core-swift` to it. Nothing in CI
or a release uses it, so a pull request here passes only once the core change it needs
is released and pinned. It is a separate spec rather than a switch inside `project.yml`
because XcodeGen lets a spec override what it includes, never the other way round.

## Rules CI enforces

**Style.** SwiftFormat and SwiftLint, at the versions above, from the repository root.
Use exactly those versions: the two tools disagree by default about some constructs and
are configured to agree, and another version can put them back at odds. SwiftLint runs
with `--strict`, so a warning is a failure, and there is no baseline file.

**Tests.** A change in behaviour comes with a test that fails without it. Put the logic,
and its test, in DistrictCore whenever it can live there (see "Changing DistrictCore");
`App/Tests` (`DistrictAITests`) is for what the package cannot reach, such as wording and
decisions that depend on app-side types.

**DistrictCore stays Foundation-only.** Darwin-only frameworks (UIKit, SwiftUI, Security,
AuthenticationServices, CallKit, PushKit, LiveKit) are imported in `App/` only. When the
core needs one, it declares a protocol and the app implements it (see `HTTPTransport`,
`TokenStore` and `CallEngine`); district-core-swift's CI enforces its side.

**Layout follows width, not the device.** `UIScreen.main` is not used anywhere in
`App/Sources`, and `userInterfaceIdiom` is used only in
`App/Sources/Platform/SpeakerToggleRule.swift`. `App/Tests/SourceBanTests.swift` enforces
both. Use size classes and the space the view is given; an iPad in Split View or Stage
Manager is often compact.

**The project is `project.yml`.** Never commit a `.xcodeproj`; it is generated. Every
remote package in it is pinned `exactVersion`, including swift-asn1, which nothing links
and which is listed only so the graph under DistrictCore cannot float.

**Test bundles must discover their tests.** CI counts the tests each bundle ran and fails
below a floor set in `.github/workflows/ci.yml`: 460 for `DistrictAITests` and 7 for the
signed-out UI tests. The first sits a little below the current count and is a ratchet: a
change that adds many tests may raise it, and a change that deletes tests on purpose
lowers it in the same commit and says why. A
new signed-out UI test class has to be added to the `-only-testing` list there, and its
cases to the expected count.

**UI tests find elements by accessibility identifier**, from `App/Shared`, never by
label: labels change with copy, and an unsigned CI build shows a different screen from a
signed-in one.

## Pull requests

Pull requests run [`.github/workflows/ci.yml`](.github/workflows/ci.yml), and all of it
must be green. The workflow reads no secrets, so a pull request from a fork runs exactly
the same checks; GitHub asks a maintainer to approve the first run for a first-time
contributor.

Conventional Commits are not required. What is required is that the message says **why**:
the diff already says what. Name what was wrong and how you know.

For a visible change, attach before and after screenshots, iPhone and iPad where the
layout differs, using test data only.

Things CI cannot check (a real phone call, push delivery, a physical device) are fine to
leave untested; say so in the pull request.

## Releases

Contributors do not cut releases. A maintainer pushes a protected `v*` tag matching
`MARKETING_VERSION` in `project.yml`, and [`release.yml`](.github/workflows/release.yml)
builds, signs and uploads it to TestFlight; submission for App Review is a separate step
that runs only with the maintainers' explicit approval. No signing key or store
credential is stored in this repository or in GitHub. See the README's Releases section.

A change to `scripts/archive-imac.sh`, `scripts/release-preflight.sh`,
`scripts/asc-key.sh` or `scripts/asc_release.py` comes with its test in the matching
`*.test.sh` or `*_test.py`; the **release scripts** job runs them on every pull request.

## Reporting bugs and asking questions

Use the bug report form for a bug. Questions and ideas go to
[Discussions](https://github.com/distronode-corporation/district-ios/discussions), not
Issues. For anything security-relevant, do not open an issue; see
[SECURITY.md](SECURITY.md).

## Licence of contributions

By contributing you agree that your contribution is licensed under the Apache License
2.0, as section 5 of [the licence](LICENSE) provides. There is no CLA and no sign-off
requirement.
