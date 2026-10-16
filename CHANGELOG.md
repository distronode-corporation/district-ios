# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions
are the App Store version (`MARKETING_VERSION` in `project.yml`).

The public history starts at 1.2. Versions 1.0 (2026-09-23) and 1.1 (2026-09-25) were
built from history before publication, so they have no tags in this repository.

## [Unreleased]

### Fixed

- 3.0.2: an answered call joins before its speaker starts (port of district-macos #64). The
  softphone joined with LiveKit's auto-subscribe, so the server's first subscriber offer
  already carried the caller's and the agent's audio, and applying it starts the speaker
  (WebRTC's `AVAudioEngine` playout start, up to ten attempts 100 ms apart) on the worker
  thread before the answer the join waits for is sent. On the Mac that held the join past
  the SDK's 10 s primary-transport wait, "the call could not be connected" on 1 answered
  call in 5 (District AI for Mac 3.0.1 build 20062, 2026-10-16, 07:07:03Z); this engine
  joins the same way, and on iOS the speaker starts at that subscribe too, not at CallKit's
  activation. `LiveKitCallRoom.connect` now joins with `ConnectOptions(autoSubscribe: false,
  enableMicrophone: false)` and then subscribes every remote audio track already in the
  room; `RemoteAudioSubscriber` (a room delegate) subscribes each one published later. A
  slow speaker start now delays the first sound instead of failing the call. Opt-in join
  diagnostics: the launch argument `-diagnostics.webrtcLog YES` forwards the SDK's debug
  lines and WebRTC's native ones to the unified log (`io.livekit.sdk`); off by default.
  Tested by `LiveKitCallEngineJoinTests` (the join's options and the subscriber's selector).
- An answered call joins before its microphone starts. The softphone joined with LiveKit's
  concurrent microphone mode (`ConnectOptions(enableMicrophone: true)`), which starts Core
  Audio on the SDK's one serial WebRTC queue while the join builds its peer connections on
  that same queue. A slow start (VoiceProcessingIO building its aggregate device, about 5 s
  on the first answer after a launch) held the join past its 10 s transport wait: the server
  saw the session start and never become active, and the call ended "the call could not be
  connected" (District AI for Mac 3.0.1, 2026-10-16, 05:46:05Z; this engine joins the same way). `LiveKitCallEngine.connect` now
  joins with nothing published (`LiveKitCallRoom`) and then calls `setMicrophone(enabled: true)`
  once; `CallJoinGate` still holds the reducers' unmute until that publish is done, so a call
  still has exactly one microphone track. A microphone that cannot start after the join no
  longer ends anything: the call stays connected and shows muted, and Unmute tries again.
  3.0.0 joined the same way. Tested at the engine seam (`CallRoom`,
  `LiveKitCallEngineJoinTests`).
- The end screen no longer shows LiveKit's own text. A caller hanging up read "Call ended ·
  Room deleted" (the SDK's English error description, passed through as the end reason), and
  a failed join could show the SDK's message the same way. `InCallCopy.word(for:)` now always
  says the catalog's sentence for both (`wordRemoteEnded`, `wordFailed`, English and French);
  the SDK's text goes to the log (`Logger`, category `Call`). No new strings.

- 3.0.2, the Apple batch after 3.0.1 (the 3.0.1 visual QA's MEDIUM and LOW findings, the
  queued contrast and type items, and the French notes from the 3.0.1 round):
  - Every tinted badge clears WCAG AA. A badge's label (and an avatar's initials, and a
    desk chip's) is drawn in a chip ink, its tone moved a fifth of the way towards
    `foreground`, on the same 12% tint: the six pairs that sat between 3.91:1 and 4.44:1
    now measure 4.71:1 or better, and `DistrictContrastTests` asserts all fifty instead of
    pinning the gap. The destructive button's label and the selected Desk filter take the
    same ink.
  - Section and field labels (`DistrictEyebrow`) are sentence case in the system face,
    with no capitals and no letter spacing at any text size (AP-011; AP-002 had dropped
    them at accessibility sizes only).
  - Sheets sit on the Ledger ground rather than the system's grey (AP-020). Text fields
    take the site's field grammar, a `card` ground inside an `input` edge, instead of a
    grey `input` fill on which the dark placeholder was 4.34:1, and a field whose label is
    drawn above it no longer repeats that label as its placeholder (AP-021).
  - An empty Calls, Contacts or Inbox list fills the screen instead of drawing a grey band
    across it (AP-022). A workspace name that ends in a period no longer closes the
    Account sentence twice (AP-024). The Inbox title is « Réception » in French, as the
    tab bar and Apple Mail say it, and the iPad sidebar shows a long workspace name on up
    to two lines (AP-026) under a solid bar (AP-033). The Desk's status filters wrap onto
    a second line instead of scrolling off the iPad column (AP-027). Bookings switches
    views with the system's segmented control (AP-028).
  - Working hours: the two buttons say what they do (Edit working hours, Edit date
    overrides) in one style, so they no longer read as tabs.
  - French: a call length never wraps between its minutes and seconds (« 3 min 4 s »);
    the contact dossier heads the keys the vocabulary lists in the portal's words
    (« Enjeux CRM déduits », not « Core pain points »). A test holds every French ellipsis
    to U+2026 attached to its word (« Sonnerie… » already was).

- A ring stops on this device when it ends elsewhere. The server now sends a
  `call_ring_cancelled` APNs background push (on the alert token, never VoIP) whenever a ring
  ends: answered on any device, timed out, the caller hung up, or withdrawn. `AppDelegate`
  reads it before the registrar guard, so it works while the session is still being checked;
  `IncomingCallModel.ringCancelled(_:)` reports the
  CallKit call ended (`.answeredElsewhere` for answered, `.remoteEnded` for call_ended,
  `.unanswered` for timeout, withdrawn and any unknown reason) and dismisses the ringing
  screen; `DeliveredRingAlerts` removes the call's delivered `incoming_call` alert. The parse
  is DistrictCore 7.0.1's `RingCancel` (shared with the Mac); the CallKit half is the app's
  (`RingCancel+CallKit.swift`). Matched
  on `callId` only; a call this device answered or is answering is not touched, alert
  included. The completion handler is called once on every path, and every other background
  push still only refreshes the badge. The 30 s local ring timeout stays as the fallback.
- One microphone track per call. The engine joins with the microphone published
  concurrently (`ConnectOptions(enableMicrophone: true)`), LiveKit reports the room connected
  before it publishes that track, and both reducers answer `.connected` with an unmute, which
  in that gap published a second track (found on District AI for Mac 3.0.0 on 2026-10-15,
  the same engine and reducers). `setMuted(_:)` now asks DistrictCore 7.0.1's
  `CallJoinGate`: an unmute while the join is out is dropped, a mute waits for the join.
- A second account signed in on the same launch registers for push. The ask was once per
  launch (`hasAskedThisLaunch`), so after a sign-out (which deletes the installation's rows)
  the next account never called `registerForRemoteNotifications` and had no alert row.
  `forget()` now re-arms it on every transition into signed-out.
- Wire labels in English are the vocabulary's, not the raw value. `AppWire.label` returned
  the value as sent on an English screen (the Overview showed `completed` beside
  "Transferred"); English now takes DistrictCore 7.0.1's `WireLabel.knownLabel` ("Completed")
  and keeps a value the vocabulary does not list as sent, as District AI for Mac 3.0.1 does;
  French is unchanged (`WireLabel.label`, « Terminé », « Autre »).
- Support request statuses are labelled in English and fr-CA. `SupportView` and
  `SupportThreadView` showed the help desk's `statusName` as sent, English on French screens
  (and the live workflow is localised, so it can be any language). `SupportStatusLabel`
  maps the workflow's names (Received, Open, Waiting for support, Waiting for customer, In
  progress, Pending, Escalated, Resolved, Done, Closed, Canceled, Declined) to catalog
  labels (state reviewed, signed off for 3.0.1); any other name reads as its category's label (Open, In progress, Closed,
  Received) or "Status unknown". The close confirmation names the label too.
- The scheduling hub's footnote no longer says the sections are read-only: they write. It
  now reads "Anything these sections do not cover opens in a browser."
- The scheduling hand-off never mints an unbound code (S33). DistrictCore 7.0.1's
  `SchedulingHandoffFlow` no longer falls back to a mint without a nonce when leg 1 does not
  call back within 30 s (10 s before); it ends as `.noCallback`, and the hub shows
  `scheduling.hand_off_no_callback` ("Opening the page took too long. Try again.", the
  Mac's words) and takes the leg-1 sheet away so the notice is seen. The flow is the only
  minter and `ShellView.onOpenURL` routes `districtai://handoff` to it
  (`test_IOS_SCH_29`).
- Visual QA (3.0.1, from the iPhone and iPad capture walk and District AI for Mac #55):
  - Colour v3: `DistrictTheme` takes `tokens.css`'s accent, success, warning, destructive
    and info pairs in both themes (the logo's teal; text on the dark accent is `#0e1c1f`).
    `DistrictContrastTests`: the badge combinations below AA go from nineteen to six, the
    filled pairs measure 6.20:1 to 13.98:1.
  - Selected rows on iPad: the split view fills a selected row with the accent, on which the
    rows' own inks could not be read. `SelectionInk` reads `backgroundProminence` and, on a
    selected row, draws the name, the second line, the chips and the avatar in the accent's
    text colour (`districtForeground`, white on the light accent, `#0e1c1f` on the dark one),
    a chip as an outline. `SelectionInkTests` measures each against the accent.
  - The reply composer: the field takes the full width with no "Reply" eyebrow; under it one
    row of borderless icon controls (photo, a new file control through the Files picker,
    AI draft) and Send. Command-Return sends on a hardware keyboard; Return is a new line.
  - Numbers: the four pill buttons are a segmented `Picker` (a menu at accessibility text
    sizes). The menu is a `Menu` around an inline `Picker` with its own wrapping label: a
    `.menu` picker's button held « Mes numéros » to one line's height and cut it at AX5
    (after-shot run 38795483764).
  - AP-002: at an accessibility text size `DistrictEyebrow` drops its capitals and tracking,
    and the Overview and Analytics metric grids go to one column (`DistrictMetricRow`); the
    tracked capitals broke mid-word at AX5 ("TOTA / L CALL / S"). Normal sizes unchanged.
  - AP-004: the Analytics funnel's category axis is the bars' own labels
    (`AppWire.label(.funnelStage, _)`); it was the wire names, so French drew no bars under
    an English axis.
  - AP-005: a `DistrictBadge` wraps at an accessibility size; held to one line ("Managed by
    Distronode") it made Phone numbers wider than the iPhone.
  - AP-013: `DistrictAvatar`'s circle is a `@ScaledMetric` (36pt at the default size), so
    the initials no longer read "…" at AX5.
  - AP-014: on iPad in portrait a list section opens `.doubleColumn` (its list and the open
    row) instead of an empty "Select a call" with the list hidden; landscape is unchanged.
  - AP-019: when the Overview fails, its section rows stay under the error, gated by the
    workspace list's role.
- MARKETING_VERSION 3.0.1. DistrictCore `exactVersion` 7.0.1 (district-core-swift's 7.0.1
  tag, main d7bf46d).

### Release lane

- `asc_release.py submit` (the job of `scripts/release-submit.sh`) sets every
  localization's `supportUrl` and `marketingUrl` with its release notes, from `LISTING_URLS`
  by language (English as every version has carried them, fr-CA as
  `store-listing/fr-CA.json`), prints what was there before a change, and reads them back
  and compares before the build is attached; a language with no URLs stops the run before
  any write. A 409 already names `meta.associatedErrors`. The client refuses any path to the
  App Review detail, which holds the demo account's password, before a request is made.
- The release run creates its own Apple Development certificate (`scripts/asc_dev_cert.py
  create`, through App Store Connect, the id recorded before anything else) in a keychain
  of the run's own, so `xcodebuild archive` stops minting one per run, and revokes exactly
  that id in an `always()` step before the key is removed. Nothing lists certificates or
  matches one by name. `asc_dev_cert_test.py` runs in CI's release scripts job and the
  release job.

### Changed

- French: the call log's title is « Appels » (`calls.call_log`); « Journal des appels » was
  cut to « Journal des ap… » in the iPad split view's list column.
- `scripts/asc_localization.py` adds a language's App Store listing through the App Store
  Connect API (the version localization and the app info's name and subtitle), from
  `store-listing/<locale>.json` (fr-CA: the reviewed store copy, verbatim) and the
  version's What's New file. `--dry-run` prints every write and sends none; its tests run in
  CI's release scripts job.
- 3.0.0: Canadian French ships in every build. project.yml takes App/Localization
  (fr-CA.lproj) into the app and project.fr.yml is gone; the release workflow sets
  `DISTRICT_FRENCH=YES`, so the archive guard requires fr-CA.lproj's two tables and refuses
  any other French .lproj, and CI's bundle check does the same. The app follows the
  device's language (any French is Canadian French).
- The account's stored language follows the app's: `LocaleSync` writes
  `{profile:{locale:"fr"|"en"}}` (POST /api/settings) on sign-in and when the resolved
  language changes. Every request already sends `Accept-Language` (`fr-CA` or `en`).
- The detail placeholder's symbol is hidden from VoiceOver.
- DistrictCore 7.0.0, the release: 7.0.0-beta.3 plus the reviewed v3.0 French in its catalogs
  (« Annulés », the member roles « Administrateur » and « Membre »). swift-asn1 stays 1.7.3.

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

## [3.0.1] - 2026-10-15

Fixes for calls, notifications and labels.

- An incoming call now stops ringing as soon as it is answered on another device, the caller hangs up, or the ring times out, instead of ringing for up to 30 seconds. A call answered on another device is no longer listed as missed.
- Fixes a problem that could cut the sound of a call, or end it, just after it was answered.
- If you sign out and sign in to another account without closing the app, notifications now reach the new account.
- Statuses of calls, messages and numbers show their names, such as Completed, instead of their codes.
- Support requests show their status in your language.
- The reply box gives your reply the full width, with the photo, file and AI draft controls in one row. On a hardware keyboard, Command-Return sends and Return starts a new line.
- New colours from the District palette, and selected rows on iPad stay readable.
- At the largest text sizes, labels and numbers no longer break mid-word, and every screen fits its width. On iPad in portrait, a list now opens beside the item you select.
- The Analytics conversion funnel shows its bars in every language.

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
