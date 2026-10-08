import DistrictAuthCore
import SwiftUI

/// The authenticator-code step after Sign in with Apple, for an account with an
/// authenticator app enrolled.
///
/// ⛔ IT COLLECTS A SECOND FACTOR, NEVER A FIRST ONE. The Apple sheet has already
/// verified who this is; this asks only for the 6-digit code (or a recovery code), which
/// the server checks against the same enrolment the web sign-in uses. Nothing here
/// offers to create an account or leaves the app.
///
/// ⚠️ THE INPUTS ARE ``SessionModel``'S, LIKE ``SignInView``'S. The sheet owns only what
/// is being typed and which kind of code it is; the ticket, the request and the outcome
/// live in the session gate and ``AppleSignInController``.
struct MfaCodeSheet: View {
    /// The sentence under the field: a wrong code, offline, too many attempts.
    let message: String?
    let isBusy: Bool
    let submit: (String) -> Void
    let cancel: () -> Void

    @State private var kind: NativeMfaCodeKind = .authenticator
    @State private var input = ""
    @FocusState private var focused: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// The value Verify would send, or nil while the field cannot hold a code.
    private var code: String? {
        NativeMfaCode.normalized(input, as: kind)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                    Text(kind == .authenticator ? MfaCopy.authenticatorPrompt : MfaCopy.recoveryPrompt)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    field
                    if let message {
                        Text(message)
                            .font(DistrictType.bodySmall)
                            .foregroundStyle(Tone.warning.ink(colors))
                            .accessibilityIdentifier(A11yID.SignIn.mfaMessage)
                    }
                    Button(MfaCopy.verify, action: send)
                        .buttonStyle(.districtPrimary)
                        .disabled(code == nil || isBusy)
                        .accessibilityIdentifier(A11yID.SignIn.mfaVerify)
                    if isBusy {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                    Button(kind == .authenticator ? MfaCopy.useRecovery : MfaCopy.useAuthenticator, action: toggleKind)
                        .buttonStyle(.districtGhost)
                        .disabled(isBusy)
                        .accessibilityIdentifier(A11yID.SignIn.mfaKind)
                }
                .padding(DistrictSpacing.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(MfaCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MfaCopy.cancel, action: cancel)
                        .accessibilityIdentifier(A11yID.SignIn.mfaCancel)
                }
            }
        }
        // ⚠️ A SWIPE WOULD DROP THE TICKET MID-REQUEST; while a code is in flight the
        // only way out is waiting for the answer.
        .interactiveDismissDisabled(isBusy)
        .onAppear { focused = true }
        .accessibilityIdentifier(A11yID.SignIn.mfaSheet)
    }

    @ViewBuilder
    private var field: some View {
        if kind == .authenticator {
            TextField(MfaCopy.authenticatorPlaceholder, text: $input)
                // ⛔ `.oneTimeCode` LETS THE KEYBOARD OFFER THE CODE from Passwords or a
                // message, and the number pad keeps the field to digits.
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(DistrictType.headline)
                .monospacedDigit()
                .onChange(of: input) { _, typed in
                    let digits = NativeMfaCode.authenticatorInput(typed)
                    if digits != typed {
                        input = digits
                    }
                }
                .districtField()
                .focused($focused)
                .disabled(isBusy)
                .accessibilityIdentifier(A11yID.SignIn.mfaCode)
        } else {
            TextField(MfaCopy.recoveryPlaceholder, text: $input)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .font(DistrictType.body)
                .districtField()
                .focused($focused)
                .disabled(isBusy)
                .onSubmit(send)
                .accessibilityIdentifier(A11yID.SignIn.mfaCode)
        }
    }

    private func send() {
        guard let code, !isBusy else { return }
        submit(code)
    }

    private func toggleKind() {
        kind = kind == .authenticator ? .recovery : .authenticator
        input = ""
        focused = true
    }
}
