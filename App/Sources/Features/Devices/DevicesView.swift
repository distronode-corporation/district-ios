import DistrictModel
import SwiftUI

/// Every install signed in to this account, and the two ways to end one. Ported
/// from Android's `DevicesScreen.kt`, whose header decisions are carried over
/// rather than re-derived.
///
/// ⛔ BOTH DESTRUCTIVE ACTIONS ARE CONFIRMED, AND THEY ARE NOT EQUALLY
/// DESTRUCTIVE. Signing out one device is recoverable by signing back in on it;
/// "sign out everywhere" includes the phone in the user's hand and logs them out
/// mid-tap. Neither is a mis-tap away, and the three prompts say different things
/// because a shared confirmation would understate the second.
///
/// ⛔ REVOKING THIS DEVICE, OR EVERYWHERE, RUNS THE LOCAL SIGN-OUT TOO. The server
/// has no way to tell this process that its credential just died — it will simply
/// 401 on the next request — so this screen drives ``SessionModel/signOut()``
/// itself and the app returns to the sign-in gate rather than sitting on a dead
/// session. ⚠️ Revoking ANOTHER device must not touch the local session, which is
/// why ``DevicesModel`` answers which case happened instead of assuming.
///
/// ⛔ THE ROW FOR THIS DEVICE IS MARKED, AND THAT MARKING IS SAFETY RATHER THAN
/// POLISH. Device names are client-supplied free text, so two identical handsets
/// on one account produce two identical-looking rows; without the marker, "sign
/// out the one that is not mine" is a coin flip, and losing it means signing out
/// the phone you are holding while the lost one stays live. The marker is derived
/// from the opaque installation id, never from the name.
///
/// ⚠️ "Last active" IS DELIBERATELY VAGUE AND UNDERSTATES ON PURPOSE. The server
/// stamps `lastUsedAt` only when a refresh token ROTATES, so the value trails real
/// use by up to about ten minutes and stops moving entirely on a device that is
/// signed in but unopened. Calling it "last used" would be a claim the data cannot
/// support.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and
/// registers `navigationDestination(for: Route.self)` on it exactly once; SwiftUI
/// resolves that by TYPE, so a second registration here would be a runtime coin
/// toss rather than a compile error.
struct DevicesView: View {
    /// ⚠️ THE ACCOUNT SESSION, NOT THE WORKSPACE ONE. This screen is
    /// account-scoped and has to stay reachable when no workspace resolves at
    /// all, and the only thing it needs from the session is the local sign-out.
    let session: SessionModel

    @State private var model: DevicesModel

    /// ⚠️ Held as the device being confirmed rather than only as a flag, so the
    /// prompt can say whether it is about to end THIS session and so a stale
    /// confirmation cannot apply to a different row.
    @State private var pending: DeviceSession?
    @State private var confirmingDevice = false
    @State private var confirmingAll = false

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, session: SessionModel) {
        self.session = session
        // ⚠️ `State(initialValue:)` in `init`, the `@Observable` equivalent of the
        // old `StateObject(wrappedValue:)` autoclosure. Building it in `body`
        // would be a new model, and a new device read, on every redraw.
        _model = State(initialValue: DevicesModel(container: container))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                notices
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle("Devices")
        // ⚠️ NOT KEYED ON `session.epoch`, UNLIKE THE ACCOUNT TAB. This view's
        // identity cannot outlive a session change: ``RootView`` swaps the whole
        // subtree out on a sign-out and builds a new ``ShellView`` on a sign-in,
        // so there is no case where a stale read would survive to be re-run.
        .task {
            await model.load()
        }
    }

    // MARK: - Notices

    /// ⚠️ ONE COMPONENT FOR BOTH, TONED BY A FLAG. A failed revoke and a
    /// `revoked: 0` look alike on screen and are not alike in meaning — the second
    /// is not an error at all — so the colour is the only thing that differs and
    /// the wording carries the rest.
    @ViewBuilder
    private var notices: some View {
        if let failure = model.mutationFailure {
            DeviceNotice(message: failure.message, destructive: true, onDismiss: model.dismissNotices)
        }
        if model.nothingRevoked {
            DeviceNotice(
                message: "That device was already signed out. The list has been refreshed.",
                destructive: false,
                onDismiss: model.dismissNotices
            )
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.list {
        case .loading:
            skeleton
        case let .ready(devices):
            deviceList(devices)
        case let .failed(failure):
            listFailure(failure)
        }
    }

    /// ⚠️ SKELETON ROWS, NOT A CENTRED SPINNER. The list that is arriving has a
    /// known shape, so drawing that shape says what is loading and stops the
    /// layout jumping when it lands.
    private var skeleton: some View {
        VStack(spacing: DistrictSpacing.row) {
            ForEach(0 ..< 3, id: \.self) { _ in
                SkeletonBlock(height: 96)
            }
        }
    }

    /// ⚠️ THE "sign out everywhere" CONTROL IS RENDERED EVEN WHEN THE LIST IS
    /// EMPTY. An empty list can mean a chain is mid-rotation rather than that
    /// nothing is signed in, and this is exactly the control someone reaches for
    /// when they believe a device is live that the list is not showing.
    private func deviceList(_ devices: [DeviceSession]) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            if devices.isEmpty {
                empty
            } else {
                ForEach(devices, id: \.deviceId) { device in
                    DeviceCard(
                        device: device,
                        isThisDevice: device.deviceId == model.thisDeviceId,
                        busy: model.busy,
                        onRequestRevoke: { request(device) }
                    )
                    // ⚠️ ON EACH CARD, PRESENTED ONLY FOR THE PENDING ONE, so the popover
                    // a regular-width layout draws points at the device it names. See
                    // ``SwiftUI/Binding/dialog(_:onDismiss:)``.
                    .confirmationDialog(
                        devicePrompt,
                        isPresented: .dialog(confirmingDevice && pending?.deviceId == device.deviceId) {
                            confirmingDevice = false
                        },
                        titleVisibility: .visible
                    ) {
                        Button("Sign out", role: .destructive, action: confirmDevice)
                        Button("Cancel", role: .cancel) { pending = nil }
                    }
                }
            }
            revokeAllButton
        }
    }

    private var empty: some View {
        EmptyStateView(
            systemImage: "iphone",
            title: "No other devices",
            message: "Nothing else is signed in to this account right now. "
                + "A device that just signed in can take a few minutes to appear."
        )
    }

    /// ⚠️ A TINTED OUTLINE RATHER THAN A RED FILL, which is what
    /// ``DistrictButtonVariant/destructive`` is: it reads as "this one is
    /// destructive" without looking like the screen's primary action.
    private var revokeAllButton: some View {
        Button("Sign out everywhere") { confirmingAll = true }
            .buttonStyle(.districtDestructive)
            .disabled(model.busy)
            .confirmationDialog(Self.confirmAllPrompt, isPresented: $confirmingAll, titleVisibility: .visible) {
                Button("Sign out", role: .destructive, action: confirmAll)
                Button("Cancel", role: .cancel) {}
            }
            .padding(.top, DistrictSpacing.tight)
    }

    /// ⛔ A FAILURE, NEVER AN EMPTY LIST. The headline names what could not be
    /// done and ``FailureView`` decides what may be OFFERED — a retry only where
    /// retrying could honestly change the answer, and a sign-in where the session
    /// is the thing that ended.
    private func listFailure(_ failure: FailureText) -> some View {
        VStack(spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: "Could not list your devices")
            FailureView(failure: failure, onRetry: reload, onSignIn: signIn)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Prompts

    /// ⚠️ HOISTED TO `String` CONSTANTS RATHER THAN WRITTEN INLINE. A `+`
    /// concatenation passed straight to `.confirmationDialog` forces the type
    /// checker to choose between the `LocalizedStringKey` overload and the
    /// `StringProtocol` one at the call site, which is exactly the kind of
    /// inference question that produces an unreadable error. A named `String` picks
    /// the second unambiguously.
    private static let confirmOtherDevice =
        "Sign this device out? It will need to sign in again to use District AI."

    /// ⚠️ SIGNING OUT THIS DEVICE ENDS THE SESSION IN THE USER'S HAND, which the
    /// generic wording above would not warn about.
    private static let confirmThisDevice =
        "This is the device you are using. Signing it out will return you to the sign-in screen."

    private static let confirmAllPrompt =
        "Sign out of District AI on every device, including this one?"

    private var devicePrompt: String {
        guard let pending, pending.deviceId == model.thisDeviceId else { return Self.confirmOtherDevice }
        return Self.confirmThisDevice
    }

    // MARK: - Actions

    private func request(_ device: DeviceSession) {
        pending = device
        confirmingDevice = true
    }

    /// ⛔ THE SIGN-OUT IS DRIVEN BY THE MODEL'S ANSWER, NOT BY THE ID THIS VIEW
    /// HAPPENS TO HOLD. A `revoked: 0` still ends this session when the id was
    /// ours, and the model owns that rule; re-deciding it here would be the same
    /// rule in two places.
    private func confirmDevice() {
        guard let device = pending else { return }
        pending = nil
        Task {
            if await model.revoke(deviceId: device.deviceId) {
                await session.signOut()
            }
        }
    }

    private func confirmAll() {
        Task {
            if await model.revokeAll() {
                await session.signOut()
            }
        }
    }

    private func reload() {
        Task { await model.load() }
    }

    private func signIn() {
        Task { await session.signIn() }
    }
}

/// One install.
///
/// ⚠️ A CARD RATHER THAN A `List` ROW, matching the Account tab: `List` would
/// impose its own section backgrounds, insets and row heights over a palette that
/// is deliberately not the platform's.
private struct DeviceCard: View {
    let device: DeviceSession
    let isThisDevice: Bool
    let busy: Bool
    let onRequestRevoke: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            // ⚠️ THE EYEBROW IS THE MARKER, and it is the ONLY place "this device"
            // is asserted — derived from the installation id, never from the name.
            if isThisDevice {
                DistrictEyebrow(text: "This device")
            }
            Text(name)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
            Text(platform)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            Text(lastActive)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            Button("Sign out this device", action: onRequestRevoke)
                .buttonStyle(.districtGhost)
                .disabled(busy)
                .padding(.top, DistrictSpacing.tight)
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
    }

    /// ⚠️ A NEUTRAL PLACEHOLDER RATHER THAN THE RAW ID. The id is an opaque UUID
    /// that means nothing to a person, and showing it invites them to treat it as
    /// an identifier they should recognise.
    private var name: String {
        let trimmed = device.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unnamed device" : trimmed
    }

    private var platform: String {
        let trimmed = device.platform.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown platform" : trimmed
    }

    /// ⛔ "Last active", NEVER "last used" — see the ⚠️ on the screen. A device
    /// that has not refreshed yet has no value at all, which is every device for
    /// its first ten minutes, so the absent case gets its own sentence rather than
    /// an empty line.
    private var lastActive: String {
        guard let stamp = device.lastUsedAt else { return "Signed in recently" }
        return "Last active \(stamp)"
    }
}

/// A dismissible sentence above the list.
private struct DeviceNotice: View {
    let message: String
    let destructive: Bool
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(destructive ? colors.destructive : colors.mutedForeground)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.districtGhost)
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }
}
