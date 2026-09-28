# Security Policy

## Reporting a vulnerability

Please report privately, not in a public issue.

- **Preferred:** GitHub's private vulnerability reporting. Open the repository's
  **Security** tab and choose **Report a vulnerability**, or go straight to
  <https://github.com/distronode-corporation/district-ios/security/advisories/new>.
- **Fallback:** email **opensource@distronode.com** if you cannot use GitHub.

Include what you did, what happened, and what you expected, with the app version and the
device or simulator. A proof of concept is welcome but not required. Never include a
real token, session or anyone's personal data; if one is part of the problem, say where
it appeared, not what it was. Test only against accounts and workspaces that are yours.

Expect an acknowledgement within a few working days. There is no paid bug bounty; what
you get is credit in the changelog entry for the fix, if you want it.

## Supported versions

Only the current App Store release is supported. Fixes ship in a new release rather than
being backported.

| Version | Supported |
| --- | --- |
| 1.2 (current App Store release) | Yes |
| Anything older | No |

## What the app does to protect you

So a report can say which of these it breaks:

- **Sign-in** runs in `ASWebAuthenticationSession`, not an embedded web view, with PKCE
  (S256), or through Sign in with Apple.
- **Tokens** are stored only in the Keychain, as
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they are not restored to another
  device from a backup. One refresh coordinator exists per process, because the service
  treats a refresh token presented twice as stolen.
- **Role checks in the app are a courtesy.** Hiding a control a role cannot use is a
  user-experience decision; the service authorises every request. An app that offers a
  control is not a vulnerability; a service that accepts the request is.
- **Test hooks never ship.** The UI-test session hooks compile only in Debug, and the
  release script deletes the archive if their strings appear in the release binary.
- **No crash reporting unless configured.** Sentry starts only when a DSN is supplied at
  build time, and `project.yml` ships it empty.

## Scope

In scope, in rough order of damage:

- A token or session reaching a log, the pasteboard, a crash report, a notification, a
  file outside the Keychain, or any host other than the District AI service.
- A universal link, notification or VoIP push that makes the app act (place or answer a
  call, open the microphone or camera, send a message, change a setting) without the
  user doing it.
- One workspace's data shown under another workspace, or after sign-out.
- The microphone or camera staying live after the user ended a call or left a room.
- The UI-test hooks, or any other Debug-only path, reachable in a release build.
- `scripts/archive-imac.sh` exposing its credentials in a log, a file or a process
  listing.

Out of scope for this repository:

- The District AI service itself. Its vulnerabilities are still welcome at the address
  above, but its code is not here.
- Anything that needs a jailbroken device, or an attacker who already has the unlocked
  device.
- A control the app shows to a role that the service then refuses (see above).
