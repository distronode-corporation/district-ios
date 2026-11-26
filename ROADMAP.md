# Roadmap

The near-term plan for District AI for iOS. This repository has no open issues or pull
requests, so the list is taken from what is merged but not yet released, the unfinished items
in its own CI and the known limits in its CHANGELOG, each named with where it comes from. This
roadmap covers the next twelve months, to November 2027. Items have no dates of their own: an
item is done when the change that does it is merged and released, and it then leaves this list
for [CHANGELOG.md](CHANGELOG.md). Anything here can change; open an issue to discuss an item or
to propose a new one.

## Near term

- **Release what is merged.** Since 3.4.0, `main` has the French singular at 0 checks left on
  the setup screen ([#130](https://github.com/distronode-corporation/district-ios/issues/130),
  fixed by [#136](https://github.com/distronode-corporation/district-ios/pull/136)) and the
  hardening from the deep security scan: room joins, credential fields and the call Live
  Activity ([#134](https://github.com/distronode-corporation/district-ios/pull/134)). The plan
  is to ship them in the next App Store release.

## Known limits, not planned

- **A number typed without its trunk prefix in the dialler** can lose a leading digit when that
  digit equals the prefix. Only Belarus, the UK and Lithuania check a prefix against
  libphonenumber's number patterns; modelling every country's pattern is left out, and the line
  under the field shows the whole number before Call ("Known limits" under `[Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md)).

## Open questions

- **Using the app without a District AI account.** Today the app needs a District AI account to
  sign in. Whether it can work without one, and what that would look like, is an open question
  we are asking about before building anything (README, "Without an account with us";
  [the discussion](https://github.com/distronode-corporation/.github/discussions/1)).

## Where the rest of the work is

Most of the app's logic lives in
[district-core-swift](https://github.com/distronode-corporation/district-core-swift), and a
change there arrives here as a pinned release; its own plan is in that repository.

## How the project is run

Who decides what goes on this list, and how, is in the organization's
[GOVERNANCE.md](https://github.com/distronode-corporation/.github/blob/main/GOVERNANCE.md).
