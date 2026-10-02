import DistrictModel
import DistrictNetwork
import Foundation
import SwiftUI

/// The account surface: sign out, reach the device list, and start account
/// deletion. Ported from Android's `SettingsScreen.kt`, whose header decisions are
/// carried over below rather than re-derived.
///
/// ⛔ THIS SCREEN EXISTS BECAUSE THE STORES REQUIRE IT, NOT BECAUSE THE PRODUCT
/// ASKED FOR IT. App Store Review Guideline 5.1.1(v) requires an app that supports
/// account creation to offer an in-app route to INITIATE account deletion, and
/// reviewers check for sign-out in the same pass. Play's User Data policy says the
/// same thing, which is why Android grew this screen first. A submission missing
/// either route is a rejection, not a nit.
///
/// ⛔ SCROLLABLE, AND THAT IS A REVIEW FIX RATHER THAN POLISH. One more row is
/// enough to push the ACCOUNT card, whose only row is the mandatory deletion entry
/// point, off the bottom of a small screen, where neither a reviewer nor a user can
/// reach it. The container has to grow rather than clip, on every device and at
/// every Dynamic Type size.
///
/// ⚠️ FEW ROWS, AND DELIBERATELY NOT A SETTINGS TASK. There
/// is nothing here the app can CONFIGURE (no notification channels, no theme
/// choice), so anything more would be placeholders. Devices earned its row by
/// being real: it is the only place an account's live sessions are visible, and
/// without it the two revoke routes are unreachable because a `deviceId` is
/// client-generated and opaque.
///
/// ⚠️ DEVICES SITS IN THE SESSION CARD, NOT THE ACCOUNT ONE. Signing another
/// device out ends a session; the account card's only row starts an irreversible
/// deletion, and grouping a routine action beside it would borrow that weight.
///
/// ⛔ NO PURCHASE PATH ANYWHERE ON THIS SCREEN. App Store Review Guideline 3.1.3(b)
/// forbids one, and an account screen is exactly where a "manage subscription" or
/// "upgrade" row would look natural. Billing is read-only in this app and lives
/// behind ``Route/billing(workspaceId:role:)``.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and
/// registers `navigationDestination(for: Route.self)` exactly once inside it;
/// SwiftUI resolves that by TYPE, so a second stack here would be a runtime coin
/// toss rather than a compile error.
struct AccountView: View {
    let container: AppContainer
    let session: SessionModel

    /// ⚠️ READ-ONLY HERE. The Account screen reports what push registration DID; it
    /// never triggers one. Registration is owned by the session gate, and a screen
    /// that could retry it would be a second opinion about when a device claims an
    /// installation. See ``PushRegistrar``.
    let push: PushRegistrar

    /// ⚠️ `State(initialValue:)` in `init`, the `@Observable` equivalent of the old
    /// `StateObject(wrappedValue:)` autoclosure. Building it in `body` would be a
    /// new model, and a new read, on every redraw.
    ///
    /// ⛔ IT IS ABOUT THE SIGNED-IN PERSON IN ONE WORKSPACE, not the account, and it
    /// resolves that workspace itself.
    @State private var availability: AvailabilityModel

    @Environment(\.colorScheme) private var colorScheme

    /// ⛔ THE SYSTEM HAND-OFF, NOT `UIApplication.shared.open`. The latter needs
    /// `import UIKit` in a view layer that depends on SwiftUI alone, and it is the
    /// wrong layer: `openURL` is the environment's own answer and is what an
    /// `.onOpenURL`-style test double can replace.
    @Environment(\.openURL) private var openURL

    init(container: AppContainer, session: SessionModel, push: PushRegistrar) {
        self.container = container
        self.session = session
        self.push = push
        _availability = State(initialValue: AvailabilityModel(container: container))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                deviceCard
                availabilityCard
                accountCard
                footer
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        // ⛔ `.contain` BEFORE THE IDENTIFIER, ALWAYS. Applied alone to a container,
        // `.accessibilityIdentifier` PROPAGATES to every descendant and overwrites
        // theirs — measured on the sign-in screen from `app.debugDescription`, where
        // the button, the status line and three labels all reported the root's id.
        // `.contain` makes this an accessibility container so the children keep their own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Account.root)
        .navigationTitle("Account")
        // ⚠️ Keyed on the sign-in counter rather than bare, so a session that
        // completes while this tab is mounted re-reads instead of showing the
        // previous account's answer. See `SessionModel.epoch`.
        .task(id: session.epoch) {
            await availability.load()
        }
    }

    // ── Calls to you ─────────────────────────────────────────────────

    /// Whether this person's phone rings for one workspace's calls.
    ///
    /// ⛔ IT IS A PER-WORKSPACE FACT ABOUT YOU AND THE ROW NAMES THE WORKSPACE. An
    /// unqualified "Available for calls" switch on an account screen reads as an
    /// account-wide setting, and the same person can be available in one workspace and
    /// not in another — so the unqualified version would be wrong in the one direction
    /// that matters. See ``AvailabilityCopy/rowSubtitle(_:)``.
    ///
    /// ⛔ AND A `reason` RENDERS AS A SENTENCE RATHER THAN A DEAD SWITCH. The route
    /// answers a **200** carrying `false` plus a reason for a viewer and for somebody
    /// with no membership row, so a toggle drawn from `available` alone would be a
    /// control that silently does nothing. The two reasons get two different sentences:
    /// one of them is a permission nobody can change, the other is a gap an
    /// administrator can fix.
    ///
    /// ⚠️ THE WHOLE CARD IS ABSENT WHEN NO WORKSPACE RESOLVES, which this screen has
    /// to survive: sign-out and account deletion live here and must be reachable with
    /// no workspace at all.
    @ViewBuilder
    private var availabilityCard: some View {
        switch availability.state {
        case .loading:
            card(title: AvailabilityCopy.cardTitle) { SkeletonBlock(height: 56) }
        case .noWorkspace:
            EmptyView()
        case let .ready(status):
            card(title: AvailabilityCopy.cardTitle) { availabilityRow(status) }
        case let .failed(failure):
            card(title: AvailabilityCopy.cardTitle) { availabilityFailure(failure) }
        }
    }

    /// ⚠️ A `Toggle` WRAPPING THE ROW RATHER THAN A TRAILING SWITCH IN A `Button`,
    /// which is the one place on this screen a platform control is the right answer: a
    /// switch has to reflect state as well as accept a tap, and SwiftUI's own gives the
    /// accessibility traits and the animation for free.
    @ViewBuilder
    private func availabilityRow(_ status: AvailabilityStatus) -> some View {
        if status.canToggle {
            Toggle(isOn: availabilityBinding(status)) {
                DistrictListRow(
                    title: AvailabilityCopy.rowTitle,
                    subtitle: AvailabilityCopy.rowSubtitle(status.workspaceName)
                )
            }
            .padding(.trailing, DistrictSpacing.gutter)
            .disabled(availability.saving)
            if let failure = availability.writeFailure {
                availabilityNote(failure.message, colors.destructive)
            }
        } else {
            DistrictListRow(
                title: AvailabilityCopy.rowTitle,
                subtitle: AvailabilityCopy.rowSubtitle(status.workspaceName)
            )
            availabilityNote(Self.reasonSentence(status.reason), colors.mutedForeground)
        }
    }

    private func availabilityFailure(_ failure: FailureText) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            availabilityNote(AvailabilityCopy.loadFailed, colors.foreground)
            availabilityNote(failure.message, colors.mutedForeground)
        }
    }

    private func availabilityNote(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DistrictSpacing.gutter)
            .padding(.bottom, DistrictSpacing.hairline)
    }

    /// ⚠️ THE SWITCH IS NOT THE SOURCE OF TRUTH. Its `get` reads the last value the
    /// server confirmed, so a refused write leaves it where it was rather than where the
    /// thumb left it.
    private func availabilityBinding(_ status: AvailabilityStatus) -> Binding<Bool> {
        Binding(
            get: { status.available },
            set: { next in Task { await availability.setAvailable(next) } }
        )
    }

    /// ⛔ TWO REASONS, TWO SENTENCES, AND A THIRD FOR ONE THIS BUILD HAS NOT LEARNED.
    /// `role` is a permission the person cannot change; `no_member_row` is a gap an
    /// administrator can close. Collapsing them would leave the second person with no
    /// idea what to ask for.
    private static func reasonSentence(_ reason: String?) -> String {
        switch reason {
        case AvailabilityReason.role: AvailabilityCopy.reasonRole
        case AvailabilityReason.noMemberRow: AvailabilityCopy.reasonNoMemberRow
        default: AvailabilityCopy.reasonUnknown
        }
    }

    // ── This device ──────────────────────────────────────────────────────────

    private var deviceCard: some View {
        card(title: "This device") {
            notificationsRow
            DistrictRowDivider()
            signOutRow
            DistrictRowDivider()
            linkRow(
                route: .devices,
                identifier: A11yID.Account.devices,
                title: "Devices",
                subtitle: "See where you are signed in, and sign out a device you no longer have."
            )
        }
    }

    /// ⛔ SERVER-SIDE REVOCATION IS NOT A GAP. `AppContainer.signOut()` calls
    /// `POST /api/auth/native/revoke` with the stored refresh token before anything
    /// wipes it, and writes that token to
    /// ``TokenStore``'s revoke outbox FIRST so a 503 is retried on a later launch rather
    /// than stranding a live credential. ``SignOutCoordinator`` owns the ordering and
    /// states why the local wipe happens either way.
    ///
    /// ⚠️ THE CAPTION IS RIGHT AND MUST NOT BE "FIXED" INTO CLAIMING MORE. This
    /// button ends THIS device's session and only this one:
    /// `revoke` matches on the presented token's hash alone, not on its family and not
    /// on the user, so the sessions on a customer's other handsets survive it
    /// deliberately. "on this device" is the truth about the scope of the action rather
    /// than a hedge about how well it worked, and Devices is the row that reaches the
    /// other ones.
    /// ⛔ THE ONE SURFACE IN THIS APP THAT CAN SAY PUSH IS NOT WORKING. Without it, a
    /// handset whose registration was refused, or whose device token was never issued,
    /// looks exactly like one that is set up, and a push outage goes unnoticed.
    ///
    /// ⚠️ NOT A CONTROL, AND NOT A LINK. There is nothing to tap: every remedy these
    /// lines name lives somewhere else (iOS Settings, a fresh sign-in, support), and a
    /// row that looked tappable would promise an action the app cannot perform.
    private var notificationsRow: some View {
        DistrictListRow(
            title: PushStatusCopy.title,
            subtitle: PushStatusCopy.subtitle(
                authorization: push.authorization,
                registration: push.registration
            )
        )
        .accessibilityIdentifier(A11yID.Account.notifications)
    }

    private var signOutRow: some View {
        Button(action: signOut) {
            DistrictListRow(
                title: "Sign out",
                subtitle: "Sign out of District AI on this device."
            )
        }
        .buttonStyle(.plain)
        .disabled(session.isBusy)
        // ⛔ IN `UITestApp.forbiddenSurfaces`: a test that tapped this would end the
        // session the rest of its own run depends on. Identified so a case can ASSERT
        // it is present without being able to press it.
        .accessibilityIdentifier(A11yID.Account.signOut)
    }

    // ── Your account ─────────────────────────────────────────────────────────

    /// ⚠️ ONE ROW, ON ITS OWN CARD. See the ⚠️ about Devices in the header: the only
    /// row here starts an irreversible process and nothing routine should sit
    /// beside it.
    private var accountCard: some View {
        card(title: "Your account") {
            deleteAccountRow
        }
    }

    /// ⚠️ DELETION IS A LINK, NOT A BUTTON THAT DELETES. The flow is
    /// identity-verified and irreversible and the web already owns it;
    /// reimplementing it natively would duplicate that verification on the least
    /// reviewable surface. Policy asks that the app let the user START the process,
    /// which a hand-off to the live page does.
    ///
    /// ⚠️ AND IT IS NOT PAINTED RED. It is destructive, but it does not delete
    /// anything on tap: it opens a page. A `destructive` tint would promise
    /// irreversibility one tap early and make the row look like it had already
    /// failed, which is the same reason ``DistrictButtonVariant/destructive`` is a
    /// tinted outline rather than a solid fill. The caption carries the warning.
    private var deleteAccountRow: some View {
        Button(action: openDeletionPage) {
            DistrictListRow(
                title: "Delete account",
                subtitle: "Request deletion of your account and its data. Opens in your browser.",
                trailing: { glyph("arrow.up.right") }
            )
        }
        .buttonStyle(.plain)
        // ⛔ IN `UITestApp.forbiddenSurfaces`. Tapping it starts an irreversible
        // deletion of a real account against the live workspace.
        .accessibilityIdentifier(A11yID.Account.delete)
    }

    // ── Footer ───────────────────────────────────────────────────────────────

    /// The build, and the id this installation sends on token exchange.
    ///
    /// ⛔ IT IS AN INSTALLATION ID AND THE COPY MUST KEEP SAYING SO. ``DeviceIdentity``
    /// stores it in `UserDefaults` rather than the Keychain precisely so that
    /// deleting the app ends it, and its own ⚠️ says it must never become a device
    /// fingerprint. Labelling it "Device id" here would describe a stable
    /// cross-install identifier we do not create and do not claim.
    ///
    /// ⚠️ SELECTABLE, BECAUSE ITS ONLY USE IS BEING READ OUT TO SUPPORT. A 36
    /// character UUID that cannot be copied is a transcription error waiting to
    /// happen.
    private var footer: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text("District AI \(Self.appVersion) (\(Self.appBuild))")
            Text("Installation id \(container.deviceId)")
                .textSelection(.enabled)
            Text("An opaque id for this install. It is cleared when you delete the app, and it identifies no hardware.")
        }
        .font(DistrictType.caption)
        .foregroundStyle(colors.mutedForeground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DistrictSpacing.gutter)
    }

    // ── Pieces ───────────────────────────────────────────────────────────────

    /// One card: an eyebrow and its rows, on ``DistrictColors/card`` inside the
    /// standard 1pt border.
    ///
    /// ⚠️ A `VStack` IN A `ScrollView`, NOT A `List`/`Form`. `List` would give free
    /// separators and disclosure chevrons, and would also impose its own section
    /// backgrounds, insets and row heights over a palette that is deliberately not
    /// the platform's. ``DistrictListRow`` and ``DistrictRowDivider`` already carry
    /// the metrics; the chevron is supplied explicitly below, which is the piece a
    /// `List` would otherwise have drawn.
    ///
    /// ⚠️ AN OPAQUE PARAMETER (`() -> some View`) RATHER THAN A NAMED GENERIC, AND
    /// SWIFTFORMAT'S `opaqueGenericParameters` RULE REQUIRES IT: a named
    /// `<Rows: View>` here reds `swiftformat --lint`. That is also the safer
    /// spelling, because a generic or nested type called `Body`, `Content`,
    /// `Label`, `ID`, `Value` or `Configuration` inside a type conforming to a
    /// protocol that declares that associated type becomes the WITNESS and breaks
    /// the conformance; with no name at all there is nothing to collide. See the
    /// ⛔ in `DistrictButton.swift`. The shape (a result-builder closure parameter
    /// returning an opaque type, with an `if` branch inside it) was compiled and
    /// run under `-swift-version 6` on Linux against a hand-rolled protocol before
    /// it was committed.
    private func card(title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DistrictEyebrow(text: title)
                .padding(.horizontal, DistrictSpacing.gutter)
                .padding(.top, DistrictSpacing.card)
            rows()
        }
        .padding(.bottom, DistrictSpacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .districtCardSurface()
    }

    /// ⚠️ A `NavigationLink` WRAPPING THE ROW, WHICH IS WHAT ``DistrictListRow``'s
    /// own ⛔ ASKS FOR. It has no `onTap` parameter on purpose: a gesture attached
    /// inside would lose the press highlight and the accessibility button trait
    /// that the enclosing link supplies for free.
    /// ⚠️ `identifier` IS REQUIRED RATHER THAN OPTIONAL-WITH-A-DEFAULT. A default of
    /// `nil` would mean applying `.accessibilityIdentifier("")` to the rows nobody
    /// addresses, and an EMPTY identifier on a container is the same propagation
    /// problem as a real one: it overwrites what the children carry. Making every
    /// call site say the id is cheaper than a modifier that is conditional.
    private func linkRow(
        route: Route,
        identifier: String,
        title: String,
        subtitle: String
    ) -> some View {
        NavigationLink(value: route) {
            DistrictListRow(title: title, subtitle: subtitle, trailing: { glyph("chevron.right") })
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// ⚠️ BOTH GLYPHS ARE DECORATION HERE, INCLUDING THE `arrow.up.right`. That one
    /// does carry a fact a person is entitled to before pressing — that the row leaves
    /// the app — but its single call site is ``deleteAccountRow``, whose subtitle
    /// already ends "Opens in your browser." and which ``DistrictListRow`` now folds
    /// into the row's own announcement. Labelling the arrow too would say it twice.
    ///
    /// ⛔ A SECOND `arrow.up.right` ROW WITHOUT THAT SENTENCE IN ITS SUBTITLE WOULD
    /// NEED A LABEL HERE. The glyph is silent because of what the copy already says,
    /// not because leaving the app is unimportant. ⚠️ And the label would have to be
    /// worded around "browser", which `StoreCopyTests` forbids outside its allow-list
    /// — the subtitle above is on that list by exact text.
    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(DistrictType.label)
            .foregroundStyle(colors.mutedForeground)
            .accessibilityHidden(true)
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    private func signOut() {
        Task { await session.signOut() }
    }

    private func openDeletionPage() {
        openURL(Self.accountDeletionURL)
    }

    // ── Constants ────────────────────────────────────────────────────────────

    /// The live, public deletion page.
    ///
    /// ⚠️ THE PRODUCTION HOST, NOT THE API BASE THIS BUILD IS CONFIGURED WITH. This is
    /// a marketing and legal page that must resolve for a reviewer with no session and
    /// no app build config, and it is the URL declared in each store listing's
    /// data-deletion field, so the two have to be the same address. Android holds the
    /// identical string in `ACCOUNT_DELETION_URL`; changing one without the other is a
    /// broken link on one platform and a store-listing mismatch on both.
    /// `ModerationCopyTests` pins the full string.
    static let accountDeletionURL = ApiClient.productionBaseURL.appending(path: "privacy/account-deletion")

    /// ⚠️ READ FROM THE BUNDLE, NEVER HARDCODED. `MARKETING_VERSION` and
    /// `CURRENT_PROJECT_VERSION` live in `project.yml`, and the release script
    /// overrides the build number at archive time, so a literal here would be wrong
    /// on every TestFlight build. The fallbacks exist because a preview and a unit
    /// host have no such keys, not because a shipped app can be missing them.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}
