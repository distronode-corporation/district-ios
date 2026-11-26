import AuthenticationServices
@testable import DistrictAI
import DistrictAuthCore
import SwiftUI
import XCTest

/// The signed-out screens: the sign-in screen on each of its two branches, and the two-step
/// code sheet an Apple sign-in can open.
final class SignInSnapshotTests: ScreenSnapshotTestCase {
    /// Signed out, as after a refresh token expired: the reason, Sign in and the Apple door.
    func testSignedOut() async throws {
        try await assertScreen { _ in
            SignInView(
                reason: SessionCopy.refreshTokenExpired,
                actionTitle: CommonCopy.signIn,
                isBusy: false,
                action: {},
                apple: AppleSignInHandlers(prepare: { _ in }, finish: { _ in })
            )
        }
    }

    /// A first launch: no reason to give, only the doors.
    func testFirstLaunch() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            SignInView(
                reason: SessionModel.text(for: ReauthReason.noSession),
                actionTitle: CommonCopy.signIn,
                isBusy: false,
                action: {},
                apple: AppleSignInHandlers(prepare: { _ in }, finish: { _ in })
            )
        }
    }

    /// A sign-in in flight.
    func testSigningIn() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            SignInView(
                reason: SessionCopy.refreshRejected,
                actionTitle: CommonCopy.signIn,
                isBusy: true,
                action: {},
                apple: AppleSignInHandlers(prepare: { _ in }, finish: { _ in })
            )
        }
    }

    /// The session could not be checked: Try again, and no Apple door (it would mint a second
    /// session for a handset that is still signed in).
    func testUnavailable() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            SignInView(
                reason: SessionCopy.storeUnavailable,
                actionTitle: CommonCopy.tryAgain,
                isBusy: false,
                action: {}
            )
        }
    }

    // MARK: - The two-step code sheet

    /// Asked for the authenticator code.
    func testMfaCodeSheet() async throws {
        try await assertScreen { _ in
            MfaCodeSheet(message: nil, isBusy: false, submit: { _ in }, cancel: {})
        }
    }

    /// A code the service refused, said above the field.
    func testMfaCodeSheetRefused() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            MfaCodeSheet(message: TwoStepCopy.errorLoad, isBusy: false, submit: { _ in }, cancel: {})
        }
    }

    /// The code being checked.
    func testMfaCodeSheetBusy() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            MfaCodeSheet(message: nil, isBusy: true, submit: { _ in }, cancel: {})
        }
    }
}
