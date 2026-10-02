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
- Scheduling sheets show one set of failure sentences, the same as the web, and offer
  Try again only where trying again can work. Sheet titles, notices and failure lines
  look the same on every scheduling sheet.
- Workspace roles and regions have one name each across the app: Administrator,
  Member and Viewer; Canada, Europe, APAC and US.
- The reschedule date picker uses the scheduling profile's time zone, so the slots
  listed are for the day shown.
- Scheduling screens load their independent data in parallel.

### Fixed

- Signing out while the app was refreshing its session could leave that session
  stored, so the next launch signed the previous user back in. A refresh that finishes
  after sign-out is now discarded and its token revoked.
- A session left in the Keychain by a previous installation is cleared and revoked on
  the first launch of a new one.
- A second sign-out in the same launch could drop a token still waiting to be revoked.
- A token the server refuses is no longer reused until it expires; the next request
  refreshes it.
- Pulling to refresh the call log or contacts while more rows were loading could skip
  rows.
- Creating a Desk ticket with a double tap could create two tickets.
- A quick second tap on the meeting microphone or camera button could be lost, and a
  refused change now says so.
- Inbox drafts that fail to save, or fail to delete after sending, are now reported
  instead of failing silently.
- A recording that cannot be played now says so.
- A request body that cannot be encoded fails on the device instead of being sent
  empty.

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
