import AuthenticationServices
@testable import DistrictAI
import DistrictAuthCore
import DistrictL10n
import XCTest

/// ``SessionModel``'s Apple door and code step, reached without the Apple sheet: a result with
/// no attempt in progress, the person closing the sheet, Apple's own failures and a foreign
/// error, and a code step that is not open. ⚠️ `ASAuthorization` has no public initialiser,
/// so only failure results are fed; the request is a real `ASAuthorizationAppleIDRequest`.
final class SessionAppleDoorMarginTests: ScreenSnapshotTestCase {
    private static let suite = "com.distronode.district.tests.session-apple-door"

    private func model() async throws -> (SessionModel, AppContainer) {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        let selection = WorkspaceSelectionStore(defaults: UserDefaults(suiteName: Self.suite) ?? .standard)
        let container = try await container(FixtureTransport())
        let push = PushRegistrar(container: container)
        return (SessionModel(container: container, push: push, selection: selection), container)
    }

    private func prepareAttempt(_ container: AppContainer) {
        container.appleLogin.prepare(ASAuthorizationAppleIDProvider().createRequest())
    }

    /// ⚠️ A result nobody asked for changes nothing: no phase, no sign-in counted.
    func testAResultWithNoAttemptInProgressChangesNothing() async throws {
        let (session, _) = try await model()
        await session.signInWithApple(.failure(ASAuthorizationError(.failed)))
        XCTAssertEqual(session.phase, .checking)
        XCTAssertEqual(session.epoch, 0)
        XCTAssertFalse(session.isBusy)
    }

    /// Closing the sheet is the second commonest outcome of a tap, and it is silent.
    func testClosingTheAppleSheetIsSilent() async throws {
        let (session, container) = try await model()
        await session.refreshPhase()
        XCTAssertEqual(session.phase, .signedIn)

        prepareAttempt(container)
        await session.signInWithApple(.failure(ASAuthorizationError(.canceled)))

        XCTAssertEqual(session.phase, .signedIn, "a cancel is not a state change")
        XCTAssertEqual(session.epoch, 0)
        XCTAssertNil(session.pendingMfa)
        XCTAssertFalse(session.isBusy)
    }

    /// Apple's own failure is worded with its code, so support can tell them apart.
    func testAnAppleFailureIsNotCompletedWithItsCode() async throws {
        L10nRuntime.locale = .en
        let (session, container) = try await model()
        for code in [ASAuthorizationError.Code.failed, .invalidResponse, .notHandled, .unknown] {
            prepareAttempt(container)
            await session.signInWithApple(.failure(ASAuthorizationError(code)))
            XCTAssertEqual(
                session.phase,
                .signedOut(SessionCopy.signInNotCompleted("apple_\(code.rawValue)")),
                "code \(code.rawValue)"
            )
        }
        XCTAssertEqual(session.epoch, 0, "a refusal is not a sign-in")
    }

    /// ⚠️ Hostile input: an error that is not Apple's still ends signed out, never signed in.
    func testAForeignErrorIsNotCompleted() async throws {
        L10nRuntime.locale = .en
        let (session, container) = try await model()
        prepareAttempt(container)
        await session.signInWithApple(.failure(URLError(.notConnectedToInternet)))
        XCTAssertEqual(session.phase, .signedOut(SessionCopy.signInNotCompleted("apple_failed")))
        XCTAssertEqual(session.phase, .signedOut("Sign-in was not completed (apple_failed)."))
    }

    /// ⛔ An attempt is spent by its first result: a second one is not in progress.
    func testASecondResultForOneAttemptChangesNothing() async throws {
        let (session, container) = try await model()
        prepareAttempt(container)
        await session.signInWithApple(.failure(ASAuthorizationError(.failed)))
        let afterFirst = session.phase

        await session.refreshPhase()
        XCTAssertEqual(session.phase, .signedIn)
        await session.signInWithApple(.failure(ASAuthorizationError(.failed)))

        XCTAssertNotEqual(afterFirst, .signedIn)
        XCTAssertEqual(session.phase, .signedIn, "the spent attempt's second answer is dropped")
    }

    /// With no code step open, a submit sends nothing and a cancel leaves nothing behind.
    func testACodeWithNoOpenStepSendsNothing() async throws {
        let (session, _) = try await model()
        await session.submitMfaCode("123456")
        await session.submitMfaCode("")
        session.cancelMfa()
        XCTAssertNil(session.pendingMfa)
        XCTAssertNil(session.mfaMessage)
        XCTAssertFalse(session.isVerifyingCode)
        XCTAssertEqual(session.phase, .checking)
        XCTAssertEqual(session.epoch, 0)
    }
}
