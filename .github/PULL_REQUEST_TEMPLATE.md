<!-- Thanks for the contribution. Delete any section that genuinely does not apply. -->

## What changed

<!-- One or two sentences. The diff says what; this says it in words. -->

## Why

<!-- The problem, not the patch. If it fixes an issue, link it (Fixes #123). If you saw
     it on a device or simulator rather than reading the code, say what you saw. -->

## How it was tested

<!-- Commands you actually ran, and what they said. "Should work" is not a test.
     CI runs the same gates; see CONTRIBUTING.md for the full list. -->

- [ ] `swiftformat --lint .` (SwiftFormat 0.63.0) and `swiftlint --strict` (SwiftLint 0.65.1)
- [ ] `swift test --enable-code-coverage` in `Packages/DistrictCore`, then `ci/coverage-gate.sh`
- [ ] `DistrictAITests` on an iPhone simulator
- [ ] `DistrictAITests` on an iPad simulator
- [ ] The signed-out UI tests (`UnauthenticatedTests`, `LargerTextTests`)
- [ ] `Packages/DistrictCore/Package.resolved` is not part of this change (Xcode rewrites it
      when it resolves the app's packages; restore it with
      `git checkout -- Packages/DistrictCore/Package.resolved`)

## Screenshots

<!-- For a visible change: before and after, iPhone and iPad where the layout differs.
     Use test data only; no real names, phone numbers or messages. -->

## Anything a reviewer should know

<!-- A decision you were unsure about, something you deliberately left out, or what you
     could not test (a real call, push delivery, a physical device). Saying so is useful,
     not a problem. -->
