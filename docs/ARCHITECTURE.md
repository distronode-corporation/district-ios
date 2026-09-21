# Architecture

District AI for iOS is two halves with a hard line between them.

- **`Packages/DistrictCore`** is a Swift package that holds every decision that can be
  made without Apple's UI and device frameworks: the wire models, the API client, the
  repositories, authentication and the call state machines. It imports Foundation only,
  so it builds and tests on Linux as well as on a Mac.
- **`App/`** is the SwiftUI app. It holds the screens and the adapters for everything
  Darwin-only (Keychain, `ASWebAuthenticationSession`, CallKit, PushKit, LiveKit,
  Sentry), and it is deliberately thin.

The line is enforced, not agreed: CI greps `Packages/DistrictCore` for an import of
UIKit, SwiftUI, Security, AuthenticationServices, CallKit, PushKit or LiveKit and fails
on any hit. A capability the package needs from one of those frameworks is a protocol
declared in the package and implemented in `App/`.

## DistrictCore

| Module | Holds | Depends on |
| --- | --- | --- |
| `DistrictModel` | `Codable` types for every response, the single normalised error type, push and app-link payloads | nothing |
| `DistrictAuthCore` | PKCE, token refresh coordination, sign-out, and the `TokenStore`, `RefreshClient` and `RevokeClient` seams | `DistrictModel`, swift-crypto |
| `DistrictNetwork` | the endpoint catalogue, path construction, error-envelope normalisation and the `HTTPTransport` seam | `DistrictModel` |
| `DistrictData` | repositories and paging over the API client | `DistrictModel`, `DistrictNetwork` |
| `DistrictCall` | the `CallEngine` seam and the outbound and inbound call state machines | `DistrictModel` |

Dependencies point one way, towards `DistrictModel`. `DistrictCall` deliberately does
not depend on `DistrictNetwork`: its state machines never make a request. They emit
commands (join or leave the room, mute, ask the service to answer or hang up, tell
CallKit the call ended) and their owner in the app performs them, so a machine can be
driven in a test by a list of events with no clock, no network and no media server.

The package has one external dependency, apple/swift-crypto, for SHA-256 (CryptoKit is
Darwin-only). It is pinned `exact:` and `Package.resolved` is committed.

The seams and their app-side implementations:

| Protocol (package) | Implementation (`App/`) |
| --- | --- |
| `HTTPTransport` | `URLSessionHTTPTransport` |
| `TokenStore` | `KeychainTokenStore` |
| `CallEngine` | `LiveKitCallEngine` |
| `PushTokenMemory` | `UserDefaultsPushTokenMemory` |

## The app

`AppContainer` is the object graph, wired by hand and built once. `RootView` chooses
between the sign-in screen and the signed-in shell from the session's state; signing in
is not a navigation destination, so there is no back stack that could lead into the app
after sign-out.
`SessionModel` owns the account, and `WorkspaceSessionModel` the selected workspace and
the operator's role in it. Screens live under `App/Sources/Features/<Name>/`.

### Navigation

- **`Route`** enumerates every screen that can be pushed. Each workspace-scoped case
  carries its `workspaceId`, and its role where the screen has something to gate, so a
  restored stack or a deep link describes itself instead of reading whatever the
  session holds at render time.
- **`RouteDestinations`** is the one exhaustive `switch` from `Route` to a screen. It is
  registered once per navigation stack with `navigationDestination(for: Route.self)`;
  a new `Route` case does not compile until someone decides what it shows.
- **`RouteGate`** hides or disables what a role cannot use. It is a courtesy, not a
  security boundary: the service authorises every request. It fails closed: a role
  that could not be established is refused every gated action.
- **`AppLinkRouting`** and **`PushRouting`** turn universal links and notification taps
  into routes.

### One navigation state for both layouts

On compact width (iPhone, and narrow iPad multitasking) the shell is a tab bar of five
tabs (Overview, Inbox, Calls, Contacts, Account), each with its own stack, and the hub
sections (Billing, Desk, the dialler and the rest) are screens pushed onto the Overview
tab. On regular width the shell is a sidebar with every section as a row
(`RegularShellView`); list sections (Calls, Inbox, Contacts and others) get three
columns, the sidebar, the list and the selected row's detail.

A rotation, a Split View resize or a Stage Manager drag can switch between the two at
any moment, and the controls of a live call or meeting are themselves a pushed screen.
So neither layout owns navigation state. `ShellPaths`, held once above both, stores one
`[Route]` stack per `SidebarItem`, the current selection and the hub open on the
Overview tab, and projects that one value into each layout (`compactPath(for:)`,
`regularPath(for:)`). A size-class change changes which view reads the state, never the
state itself, so nothing is translated and nothing can be dropped.

`ShellPaths` also records which workspace its stacks belong to. Switching workspace
clears every stack through the one method that changes it, so no screen from the
previous workspace survives under the new workspace's name.

## Calls

A phone call has three layers:

1. **State machines** in `DistrictCall`: `SoftphoneSession` for outbound calls
   (idle, dialling, connecting, ringing, connected, ended) and `IncomingCallController`
   for inbound ones (idle, ringing, answering, in call, ended). They consume
   `CallEngineEvent`s and emit commands. This is where every decision lives, and it is
   tested on Linux.
2. **Media**: `LiveKitCallEngine` is the only file that talks to the LiveKit SDK. It
   forwards commands and maps SDK callbacks to events, and decides nothing. One engine
   (one LiveKit room) exists per call.
3. **The system**: `CallKitBridge` owns the app's single `CXProvider`. Requests that
   start on surfaces the app does not draw (the lock screen, a headset button, a car)
   arrive as `CallKitRequest`s and drive the same state machines as the in-app buttons.

`CallStack` assembles these with the right lifetimes: one provider for the life of the
app, one engine per call, and one `AudioSessionCoordinator` shared by CallKit and the
engine, so the object CallKit activates is the one the speaker toggle writes to.

Outbound: the dialler asks the service to place the call, receives a room credential,
and joins the room; the phase stays `ringing` until the callee answers. Inbound: a VoIP
push arrives through PushKit (`VoIPPushHandler`) and a call is reported to CallKit
before the payload is interpreted, because iOS requires every VoIP push to report one;
any outcome other than ringing is expressed by ending that call. Answering fetches the
credential and joins the room.

Meeting rooms also use LiveKit but not CallKit. They share the device's one audio session
and microphone with calls, and `CallStack` is where each side can see the other.

## The contract gate

`contracts/` holds recorded API responses generated by the service's own test suite.
`ContractFixtureTests` decodes each fixture that has a model into it, re-encodes it and
requires the same keys at every level, which catches both a field the service added
that the app does not model and a hand-written `Codable` that does not round-trip. It
also asserts the exact fixture count and an explicit list of fixtures with no model yet.
The app's own decoders stay lenient, so an installed app ignores a new field rather
than failing. See [contracts/README.md](../contracts/README.md).

## Tests

| Suite | Runs | Covers |
| --- | --- | --- |
| DistrictCore (`swift test`) | Linux and macOS | the package, with per-module line-coverage floors in `ci/coverage-gate.sh` |
| `DistrictAITests` | simulator | app-level wording and decisions the package cannot reach |
| `DistrictAIUITests` | simulator | CI runs the signed-out classes; the signed-in ones need a session supplied locally |
| `DistrictSmokeUITests` | simulator | an end-to-end pass that needs a demo account from the environment and skips without one |

The default home for a new test is the package. `App/Tests` exists for what cannot live
there, such as `SourceBanTests`, which keeps `UIScreen.main` out of `App/Sources`
entirely and `userInterfaceIdiom` out of every file there except
`Platform/SpeakerToggleRule.swift`: layout follows the available width, not the device
type.
