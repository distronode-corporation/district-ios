# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions
are the App Store version (`MARKETING_VERSION` in `project.yml`).

The public history starts at 1.2. Versions 1.0 (2026-09-23) and 1.1 (2026-09-25) were
built from history before publication, so they have no tags in this repository.

## [Unreleased]

### Changed

- 3.0.0: Canadian French ships in every build. project.yml takes App/Localization
  (fr-CA.lproj) into the app and project.fr.yml is gone; the release workflow sets
  `DISTRICT_FRENCH=YES`, so the archive guard requires fr-CA.lproj's two tables and refuses
  any other French .lproj, and CI's bundle check does the same. The app follows the
  device's language (any French is Canadian French).
- The account's stored language follows the app's: `LocaleSync` writes
  `{profile:{locale:"fr"|"en"}}` (POST /api/settings) on sign-in and when the resolved
  language changes. Every request already sends `Accept-Language` (`fr-CA` or `en`).
- The detail placeholder's symbol is hidden from VoiceOver.

### Added

- New ticket on District Desk. A New ticket button in the Desk toolbar opens the form that
  raises a ticket on a customer's behalf (a walk-in, an email), as Android, Linux and
  Windows already offer. It is offered on the same rule as theirs: a role that may write,
  a desk that is on and a queue that loaded (`DeskModel.canStartTicket`). A failed submit
  is now said in the form rather than on the queue behind it.
- Read a text file into a knowledge document. Knowledge's add form has a Read a text file
  button that fills the title (when it is empty) and the text from a plain text file
  (.txt or .md) of up to 1 MB, as the Windows app does. Nothing is added until Add document.
  The same files are refused for the same reasons as on Windows: too large, empty, no
  text, or not plain text by its bytes (UTF-8, or UTF-16 with its mark, is read).
- A live transcript on a call in progress. A call's screen shows the conversation as it
  happens, line by line, while the call is in progress and the screen is in front, then the
  full transcript in the same place once the call ends. It is fed by the telemetry socket
  (`App/Sources/Platform/Live/`, the `URLSessionWebSocketTask` adapter ported from
  district-macos with a send added), which the phone opens only for that screen, asks for
  that call's transcript alone (`socket.mode` with `broadcast: false`), and closes when the
  screen goes or the app goes to the background. Lines missed while the server was
  restarting are named ("Earlier lines will appear in the full transcript after the call").
  A call the server has no live transcript for keeps the Show transcript button.
  ⚠️ When the assistant fails mid-call (`agent_error`) the pane says "Reconnecting…" rather
  than "Call ended", also when a snapshot says so (`endedReason`), and goes live again if a
  fresh assistant takes the call. A call the server answered `not_live` is subscribed again
  only when a load of the call row shows it in progress, at most once per 30 s, never on a
  timer; a load showing the call over ends the transcript and fetches the full one.

### Changed

- Two CalDAV sentences lose their em dash, the one deliberate change to English in 3.0's
  catalog work: "The server address must start with https://, because an app password sent
  over http:// travels in the clear." and "Finish in the browser, then come back: this page
  re-reads itself." The same change is in district-macos.
- Every sentence the `*Copy` enums say comes from one catalog, `l10n/ios.toml` (1,281
  entries), with English and room for Canadian French side by side. `scripts/gen-l10n.py`
  writes `App/Sources/L10n/Generated/Copy.swift` from it with the vendored tools in
  `tools/l10n/`, as extensions of the hand-written enums, so every call site reads as
  before; the enums keep only their logic, which builds its text from catalog entries. CI's
  `l10n` job fails on a stale generated file or a broken catalog rule, and
  `StoreCopyTests` scans the catalog as well as the sources. English is unchanged and
  nothing is French: `AppL10n` keeps the language English until a build ships French.
- The rest of the app's own words joined the catalog: the inline `Text`, `Button`, `Label`,
  alert and empty-state literals of the views (new `*Copy` namespaces in
  `App/Sources/L10n/CopyNamespaces.swift` for the screens that had none), sentences that
  were joined from two pieces as whole entries with placeholders, the English plural
  ternaries as catalog plurals, and the month abbreviations from the core's calendar
  words. Money stays exactly as English shows it today; in French it goes through the
  core's `L10nFormat`. Copy read from a stored `static let` is computed now, so it follows
  the language.
- French is ready to switch on and stays off. `project.fr.yml`, included only when
  `DISTRICT_FRENCH` is set for `xcodegen generate`, adds `App/Localization/fr-CA.lproj`;
  the push loc-keys (`Localizable.strings`, from `l10n/push.toml`) moved from the bundle
  root, where they would shadow every `.lproj`, into `en.lproj`, beside an
  `InfoPlist.strings` for the permission prompts (`l10n/infoplist.toml`, held equal to
  project.yml). `scripts/archive-imac.sh` deletes an archive that holds `fr-CA.lproj`
  while French is off, or any `fr.lproj`. The unit tests run pinned to English, the UI
  tests find the Overview and settings rows, the report's Done and the block
  confirmations by identifier, and `StoreCopyTests` scans the catalog's French too.
- DistrictCore 7.0.0-beta.3: the contracts from monorepo 43eed5fd6 (French API errors,
  masculine desk statuses), the billing currency, and the portal's four booking webhook
  events. Billing amounts come from its `BillingMoneyFormat`: English exactly as before
  ("$249.00"), French naming the currency (« 249,00 $ CA », « 249,00 $ US »); the five
  billing sentences that placed a "$" around the amount no longer do. The webhook editor
  offers the four booking events, and a save keeps an event already subscribed that the
  form no longer offers. 7.0.0-beta.2: the scheduling formatters write French dates and times as the
  website does (« 12 sept. 2026, 15 h 04 », « 9 h 05 », « 1er août »), and a French range
  inside one year drops its first year; English is unchanged. 7.0.0-beta.1: the core's sentences come from its catalogs, every request
  sends `Accept-Language` (`en`), and errors are shown through `ApiError.localizedMessage`
  (the same sentence in English).
- DistrictCore 6.0.0: 4.0.0 resolves District Studio links, 5.0.0 adds the live
  transcript's models, ops and reducer, and 6.0.0 adds `CodeExchangeResult.mfaRequired` and
  `POST /api/auth/native/mfa`, the authenticator code step after Sign in with Apple.
- Release notes per language: What's New for every App Store localization other than English
  comes from `release-notes/<locale>/<version>.txt`, as on district-android, and a
  localization with no notes in its language stops the submission rather than showing
  English.
- `release.yml` has a `build_only` dispatch input: it archives and signs on the runner and
  uploads nothing.
- The catalogs carry their reviewed Canadian French (fr-CA): 1,728 entries in
  `l10n/ios.toml`, `l10n/push.toml` and `l10n/infoplist.toml`, regenerated into `Copy.swift`
  and the `fr-CA.lproj` strings, so `FR_COMPLETE` is true. French stays switched off: the
  French tables still enter the app only through `project.fr.yml` (`DISTRICT_FRENCH`), and
  the release guard is unchanged.

## [3.0.0] - 2026-10-15

District AI is now in Canadian French.

- Raise a ticket on a customer's behalf from District Desk: the New ticket button in the Desk toolbar opens the form.
- Knowledge: Read a text file fills a new document's title and text from a plain text file (.txt or .md, up to 1 MB). Nothing is added until you tap Add document.
- If the receptionist is interrupted mid-call, the live transcript says Reconnecting… instead of Call ended, and goes live again when the call resumes.

## [2.2.1] - 2026-10-13

Fixes the plan name on the Billing page, which showed the plan's internal key (for example
"VoicePro") instead of its name.

## [2.2] - 2026-10-07

Live call transcripts come to iPhone and iPad, and your receptionist's settings now live
together under District Studio, as on the web.

- See a call's transcript live while the call is in progress, then the full transcript in
  the same place once it ends.
- In workspace settings, your receptionist's settings are grouped under District Studio, in
  the same order and with the same names as on the web: Persona, Voice, call handling,
  Skills and Knowledge. Messaging, Members and Scheduling follow under Workspace.
- Voice Studio is now called Voice, on its own screen and everywhere the app mentions it.
- Links to District Studio on distronode.com open the matching screen in the app. A screen
  your role cannot open shows workspace settings instead, and Studio pages the app does not
  have open in the browser.
- If your account has an authenticator app turned on, Sign in with Apple now asks for its
  code, as the website does. Enter the 6-digit code, or one of your recovery codes. A wrong
  code can be typed again, and if the step times out, start again with Sign in with Apple.

## [2.1] - 2026-10-05

Tagged and built for TestFlight (build 4130), never submitted to the App Store. Its changes
ship in 2.2, whose notes above include them.

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

[Unreleased]: https://github.com/distronode-corporation/district-ios/compare/v2.2.1...HEAD
[2.2.1]: https://github.com/distronode-corporation/district-ios/releases/tag/v2.2.1
[2.2]: https://github.com/distronode-corporation/district-ios/releases/tag/v2.2
[2.1]: https://github.com/distronode-corporation/district-ios/compare/v2.0...v2.1
[2.0]: https://github.com/distronode-corporation/district-ios/releases/tag/v2.0
[1.3]: https://github.com/distronode-corporation/district-ios/releases/tag/v1.3
[1.2]: https://github.com/distronode-corporation/district-ios/releases/tag/v1.2
