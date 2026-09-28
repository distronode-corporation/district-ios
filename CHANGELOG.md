# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions
are the App Store version (`MARKETING_VERSION` in `project.yml`).

The public history starts at 1.2. Versions 1.0 (2026-09-23) and 1.1 (2026-09-25) were
built from history before publication, so they have no tags in this repository.

## [Unreleased]

### Changed

- Releases are built, signed and uploaded by the repository's GitHub Actions release
  workflow from a protected tag, instead of on a maintainer's machine. No signing key or
  store credential is stored in the repository or in GitHub, and submission for App
  Review runs only with the maintainers' explicit approval.
- The version on `main` is now 1.3.

## [1.2] - 2026-09-26

### Changed

- Calls and meeting rooms run on LiveKit 2.17.0, which brings WebRTC 150.
- Crash reporting runs on Sentry 9.29.2.

### Removed

- Staff-only screens that were never available to customer accounts.

## [1.1] - 2026-09-25

### Added

- Native iPad support, as a universal app: a sidebar on regular width with three-column
  list sections (Calls, Inbox, Contacts, Desk, Support), the tab bar on compact width,
  and one navigation state shared by both, so a rotation, a Split View resize or a Stage
  Manager drag keeps the section, the open detail and a call in progress.
- Keyboard shortcuts on iPad: ⌘1 to ⌘5 switch sections, ⌘N starts a new item, ⌘F
  searches, ⌘R refreshes, and ⌘↩ sends an Inbox reply. Pointer hover and context menus
  on rows.
- Readable-width layouts for forms and detail screens on large displays; dialogs are
  anchored to the control that opened them.
- The meeting room's participant grid sizes its columns from the available width.

### Changed

- A call start that iOS refuses (another call in progress, or a provider that declines)
  now ends the attempt at once instead of after a ten-second wait.
- The speaker toggle is shown from the device family rather than inferred from the
  audio routes, so an iPhone whose default call route is the speaker still gets it.
- The meeting room's speaker state reflects the actual output on join.

## [1.0] - 2026-09-23

The first release on the App Store.

[Unreleased]: https://github.com/distronode-corporation/district-ios/compare/v1.2...HEAD
[1.2]: https://github.com/distronode-corporation/district-ios/releases/tag/v1.2
