# Security model

District AI for iOS holds a District AI session and shows a workspace's calls, messages and
contacts; it places and answers calls through CallKit, and embeds an Apple Watch app and a
notification service extension. This document says what it protects, who it defends against,
what it trusts, and how the code holds each line. The control-by-control summary is "What the
app does to protect you" in [SECURITY.md](SECURITY.md#what-the-app-does-to-protect-you), and how
the parts fit together is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Much of what follows is enforced in
[district-core-swift](https://github.com/distronode-corporation/district-core-swift), the
DistrictCore package this app pins by `exactVersion` in `project.yml` (8.5.0 as of this
writing), which has its own
[SECURITY-MODEL.md](https://github.com/distronode-corporation/district-core-swift/blob/main/SECURITY-MODEL.md).
Where a test lives there, the table says "core:" before its path.

## Assets

- **The session**: the access and refresh tokens, in the app's private Keychain only.
- **The notify token**: a scoped, read-only token the notification extension uses to put a
  sender's name on a message alert, in a shared Keychain group.
- **Customer data**: callers' numbers, transcripts, messages and contacts, which belong to the
  workspace and its customers, and the saved copies of the first screens kept for offline
  reading.
- **Billed and destructive actions**: placing or answering a call, sending a message, deleting
  the account.
- **The microphone and camera**, and a call's media.
- **The release**: the App Store Connect key that signs and uploads a build.

## Threat model

| Actor | What they can do | What stops them |
|---|---|---|
| A web page or another app | Open a universal link or try to finish a sign-in it did not start. | Sign-in in `ASWebAuthenticationSession` with PKCE (S256) and a fresh `state` per attempt; a callback with a foreign `state` is refused without spending the code; links resolve only the service's hosts. |
| A thief of a refresh token | Present it to the service directly. | Not an app control: the service treats a refresh token presented twice as stolen ([SECURITY.md](SECURITY.md#what-the-app-does-to-protect-you)), which this document assumes. The app's part is never to present one twice itself (next row). |
| A crash or a race mid-refresh | Make the app present a spent token, which the service would treat as theft. | One refresh coordinator per process; a marker written before sending, and a refresh whose marker cannot be written is not sent; the next attempt after an ambiguous failure signs in again rather than replay. |
| Someone with a device backup, or a later install | Restore the tokens elsewhere, or inherit an old session. | Tokens are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they do not restore to another device; a fresh install wipes any session left in the Keychain and queues its revoke. |
| A sign-out racing a refresh | Leave a working token behind. | A refresh that lands after sign-out writes nothing and its successor is revoked. |
| Anyone who can see the screen or the notifications | Read an alert, including the sender's name the extension puts on it. | Accepted: what an alert shows on a locked screen follows the device's notification preview settings. What is limited is the extension's access: it holds only the scoped, read-only notify token, never the session. |
| A hostile or compromised server response | Return any shape. | Strict decoding against the server's recorded responses, unknown keys rejected. |
| Someone who reads crash reports | Read whatever the app sent. | Crash reporting is off in any build without a DSN; when on, `sendDefaultPii` is false and tracing is off. |
| Someone who ships a modified release | Sign and upload a build as Distronode. | No signing material in this repository or in GitHub; the release job borrows the key for one run through workload identity pinned to this repository, a `release` environment and its refs; no pull request can run it. |

Out of scope, as [SECURITY.md](SECURITY.md#scope) lists: the District AI service itself, a
jailbroken device or an attacker who has the unlocked device, and a control shown to a role
the service then refuses.

## Trust boundaries

| Party | Trusted? | Why |
|---|---|---|
| The person holding the unlocked device | **Yes** | Every billed or destructive action waits for their tap. |
| iOS and the Keychain | **Yes** | They hold the tokens and enforce app sandboxing. |
| The District AI service | Yes, for what it answers about the account | It authorises every request; the app's role checks are a courtesy, and its responses are decoded strictly. |
| The watch app and the notification extension | Partly | Neither holds the session: the watch asks the phone, and the extension holds only the read-only notify token. |
| Other apps, web pages and links | **No** | Sign-in needs PKCE and `state`; links are matched by host. |
| Customers, callers and model output | **No** | Shown as text. |
| The network | **No** | App Transport Security's defaults (HTTPS only); the project sets no exception. |

## Secure design principles applied

- **Least privilege.** The watch app and the extension never hold the session; the extension's
  token is scoped and read only. Microphone and camera are asked for where a call or a room
  needs them.
- **Fail closed.** A refresh whose marker cannot be written is not sent; a callback with a
  foreign `state` is refused before the code is spent; a release archive containing the UI-test
  hooks is deleted.
- **Complete mediation.** Every request goes through DistrictCore's one client and one refresh
  coordinator; the service authorises each one.
- **Economy of mechanism.** DistrictCore is Foundation-only and holds the logic; this repository
  adds the Darwin adapters (`KeychainTokenStore`, `URLSessionHTTPTransport`, CallKit, LiveKit)
  behind the core's protocols.
- **Safe defaults.** A build from a plain checkout reports no crashes; the UI-test session hooks
  compile only in Debug.
- **Separation of secrets.** The session only in the private Keychain; the notify token in its
  own shared group; release credentials only borrowed by the release job.

## Assurance case

Each control is held by a test CI runs on every pull request
([.github/workflows/ci.yml](.github/workflows/ci.yml)), by a test in DistrictCore's CI at the
pinned release, or, where no test can hold it, says so. Weaknesses are mapped to the CWE Top 25
and the OWASP Top 10.

| Weakness | How it is countered | Tests |
|---|---|---|
| Authentication bypass by a forged callback (CWE-287, CWE-352) | PKCE (S256) with a fresh verifier and `state` per attempt; a foreign `state` refused before the code is spent. | core: `Tests/DistrictAuthCoreTests/PKCETests.swift` (`testEveryAttemptGetsFreshSecrets`), core: `PKCEVectorTests.swift` (`testFixtureIncludesTheRFC7636ReferenceVector`), `App/Tests/ReauthSheetControllerTests.swift` (`testAForeignStateIsRefusedWithoutSpendingTheCode`) |
| Sign in with Apple replay (CWE-294) | A hashed nonce per attempt; an absent or empty identity token is refused without a request. | `App/Tests/AppleSignInControllerTests.swift` (`testEachPrepareMintsAFreshNonce`, `testAnAbsentIdentityTokenIsRefusedWithoutARequest`) |
| Replay of a spent refresh token (CWE-294) | One refresh at a time; a marker before sending; sign in again after an ambiguous failure. | core: `Tests/DistrictAuthCoreTests/TokenRefreshConcurrencyTests.swift` (`testNoTokenIsEverPresentedTwiceUnderRepeatedRaces`), core: `TokenRefreshStoreBoundaryTests.swift` (`testAFailedMarkerWriteAbortsInsteadOfSendingAnUnprotectedRefresh`) |
| A session surviving sign-out or an uninstall (CWE-613) | A refresh landing after sign-out writes nothing and is revoked; a fresh install wipes an old session. | core: `Tests/DistrictAuthCoreTests/SignOutRaceTests.swift` (`testARefreshLandingAfterSignOutWritesNothingAndRevokesItsSuccessor`), core: `FreshInstallTokenStoreTests.swift` (`testAnOwedWipeHidesTheOldSessionAndQueuesItsRevoke`), `App/Tests/SessionCredentialWiringTests.swift` (`testAFreshInstallOwesAWipeUntilSettled`) |
| Cleartext storage of credentials (CWE-312, CWE-922) | Keychain only, this device only. | Mechanism only: `App/Sources/KeychainTokenStore.swift` sets `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; the Keychain cannot run in CI's unsigned build. |
| A broader credential in the extension (CWE-250) | The extension holds a scoped, read-only notify token that a sign-out clears. | `App/Tests/NotifyTokenRenewalTests.swift` (`testASignOutClearsTheTokenAndDropsTheMintInFlight`, `testNothingIsMintedWhenTheTokenCannotBeKept`) |
| Customer data kept or shown across a sign-out (CWE-200, CWE-524) | Only reads are saved, with the language in the key, hashed file names, an age limit, and nothing kept from before a clear. | `App/Tests/OfflineReadCacheTests.swift` (`test_OFF_02_writesAndOtherPathsAreNeverKept`, `test_OFF_04_anOldCopyIsNotShownAndClearRemovesEverything`, `test_OFF_17_aReadFromBeforeAClearIsServedNothing`) |
| Opening untrusted links (CWE-601, CWE-939) | Only the service's hosts resolve in the app. | core: `Tests/DistrictModelTests/AppLinkTests.swift` (`testAnotherHostEntirelyIsRefused`) |
| A server shape the client does not expect (CWE-20) | Strict decoding of the server's recorded responses. | core: `Tests/ContractFixtureTests/ContractFixtureTests.swift` (`testEveryImplementedFixturePassesTheStrictGate`) |
| A notification action without a session (CWE-862) | A signed-out device sends nothing; the service decides every write. | `App/Tests/NotificationActionHandlerTests.swift` (`testASignedOutHandsetSendsNothingAndSaysSo`) |
| Debug code in a release (CWE-489) | UI-test hooks compile in Debug only, and the release script deletes an archive whose binary carries them. | `scripts/archive-imac.test.sh` ("a binary carrying DISTRICT_UITEST fails the script") |
| Personal data in crash reports (CWE-532, OWASP A09) | No DSN, no reporting; `sendDefaultPii` false; tracing off. | Mechanism only: `App/Sources/Platform/DistrictSentry.swift`; `project.yml` ships the DSN empty. |
| Committed secrets (CWE-798) | gitleaks over the full history on every push to `main` and every pull request, with `.gitleaks.toml`. | `.github/workflows/ci.yml` (**gitleaks**) |
| Vulnerable and outdated components (OWASP A06) | Every package pinned `exactVersion` and checked as resolved; dependency review on pull requests (for a pull request from a fork, the Swift packages are not submitted to the dependency graph, so dependency review cannot see a change to them there); the dependency graph; CodeQL over the workflows and the app's Swift. | `.github/workflows/ci.yml`, `codeql.yml`, `codeql-swift.yml` |
| Release credential theft (CWE-522) | No stored credential; per-run borrowing pinned to repository, environment and refs. | Mechanism only: `.github/workflows/release.yml` and `submit.yml`; the release scripts are tested against stubs (`scripts/release-preflight.test.sh`, `scripts/asc-key.test.sh`, `scripts/github-release.test.sh`). |
| Improper certificate validation (CWE-295) | App Transport Security's defaults; no exception in the project. | Mechanism only. |

## How the project is run

Who decides, who can merge and release, and how the project continues are in the
organization's
[GOVERNANCE.md](https://github.com/distronode-corporation/.github/blob/main/GOVERNANCE.md).
