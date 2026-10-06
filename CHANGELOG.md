# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions
are the App Store version (`MARKETING_VERSION` in `project.yml`).

The public history starts at 1.2. Versions 1.0 (2026-09-23) and 1.1 (2026-09-25) were
built from history before publication, so they have no tags in this repository.

## [Unreleased]

### Added

- A live transcript on a call in progress. A call's screen shows the conversation as it
  happens, line by line, while the call is in progress and the screen is in front, then the
  full transcript in the same place once the call ends. It is fed by the telemetry socket
  (`App/Sources/Platform/Live/`, the `URLSessionWebSocketTask` adapter ported from
  district-macos with a send added), which the phone opens only for that screen, asks for
  that call's transcript alone (`socket.mode` with `broadcast: false`), and closes when the
  screen goes or the app goes to the background. Lines missed while the server was
  restarting are named ("Earlier lines will appear in the full transcript after the call").
  A call the server has no live transcript for keeps the Show transcript button.

### Changed

- DistrictCore 6.0.0: 4.0.0 resolves District Studio links, 5.0.0 adds the live
  transcript's models, ops and reducer, and 6.0.0 adds `CodeExchangeResult.mfaRequired` and
  `POST /api/auth/native/mfa`, the authenticator code step after Sign in with Apple.
- Release notes per language: What's New for every App Store localization other than English
  comes from `release-notes/<locale>/<version>.txt`, as on district-android, and a
  localization with no notes in its language stops the submission rather than showing
  English.
- `release.yml` has a `build_only` dispatch input: it archives and signs on the runner and
  uploads nothing.

## [2.1] - 2026-10-05

Your receptionist's settings now live together under District Studio, as on the web.

### Changed

- In workspace settings, your receptionist's settings are grouped under District Studio, in
  the same order and with the same names as on the web: Persona, Voice, call handling,
  Skills and Knowledge. Messaging, Members and Scheduling follow under Workspace.
- Voice Studio is now called Voice, on its own screen and everywhere the app mentions it.

### Added

- Links to District Studio on distronode.com open the matching screen in the app. A screen
  your role cannot open shows workspace settings instead, and Studio pages the app does not
  have open in the browser.
- If your account has an authenticator app turned on, Sign in with Apple now asks for its
  code, as the website does. Enter the 6-digit code, or one of your recovery codes. A wrong
  code can be typed again, and if the step times out, start again with Sign in with Apple.

## [2.0] - 2026-10-04

Voice Studio is the headline of 2.0.

### Added

- Voice Studio, in workspace settings: the same studio as on the web. Pick a starting
  point (Stable or Latest), then see the call's signal chain, Ear, Turn-taking, Brain and
  Voice (or one all-in-one realtime model), with each part's channel, where it is
  processed and how fast it was measured. Change any part, its voice, and its tuning
  under Advanced; the time to first word and where the call is processed update as you
  go, and say "at least" when part of the call has not been measured. Labels follow the
  language you use on the web, the time to first word of an unsaved change and the
  "Based on" line included.
- Changing the persona's language moves a voice chain of your own to models that speak
  it, the way the web does, and says what happened.

### Changed

- The agent persona keeps its name, greeting, personality, language and answer length.
  The engine, the voice and how fast the agent replies moved to Voice Studio.

### Removed

- Call recordings. No call or meeting is recorded in any region, so the Play recording
  control on a call is gone.
- Scheduling's Recordings section, the recording and meeting notes switches in its
  settings, and a booking's notes and transcript. Meetings are not recorded, so there was
  nothing for them to show. The settings tab is now "Booking assistant", as on the web.

## [1.3] - 2026-10-02

### Fixed

- Signing out while the app was refreshing your session could leave you signed in on
  the next launch. Signing out now always sticks.
- Reinstalling the app no longer resumes the account that was signed in before it was
  deleted.
- If the service refuses your session, the app now gets a fresh one on the next request
  instead of failing until it expires.
- Pulling to refresh the call log or contacts while more rows were loading could skip
  rows.
- A quick double tap on Create ticket in Desk could create two tickets.
- A quick second tap on the microphone or camera button in a meeting could be lost, and
  a change the device refuses now says so.
- Inbox drafts that fail to save, or fail to clear after sending, are now reported
  instead of failing silently.
- A recording that cannot be played now says so.

### Changed

- Scheduling shows the same messages as the website when something goes wrong, and
  offers Try again only where trying again can work. Its sheets now look alike.
- Rescheduling a booking lists the slots for the day shown, in your scheduling time
  zone, even when you are travelling.
- Scheduling screens open faster.
- Workspace roles read Administrator, Member and Viewer, and regions read US, Canada,
  Europe and APAC, everywhere in the app.
- Releases are built, signed and uploaded by this repository's public GitHub Actions
  workflow. No signing key or store credential is stored in the repository or in GitHub.

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

[Unreleased]: https://github.com/distronode-corporation/district-ios/compare/v2.0...HEAD
[2.0]: https://github.com/distronode-corporation/district-ios/releases/tag/v2.0
[1.3]: https://github.com/distronode-corporation/district-ios/releases/tag/v1.3
[1.2]: https://github.com/distronode-corporation/district-ios/releases/tag/v1.2
