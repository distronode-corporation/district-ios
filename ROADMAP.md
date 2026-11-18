# Roadmap

The near-term plan for District AI for iOS. It is taken from this repository's one open issue,
its open pull request and the known limits in its own CHANGELOG, each named with where it comes
from. It has no dates: an item is done when the change that does it is merged and released, and
it then leaves this list for [CHANGELOG.md](CHANGELOG.md). Anything here can change; open an
issue to discuss an item or to propose a new one.

## Near term

- **The French plural at 0 checks left.** The setup screen reads « 0 vérifications restantes »
  where French uses the singular for 0; the fix and a test for 0, 1 and 2 in both languages are
  planned for 3.4.1
  ([#130](https://github.com/distronode-corporation/district-ios/issues/130)).
- **Hardening from the deep security scan.** One open pull request: room joins, credential
  fields and the call Live Activity
  ([#134](https://github.com/distronode-corporation/district-ios/pull/134)).

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
