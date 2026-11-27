@testable import DistrictAI
import DistrictAuthCore
import DistrictL10n
import XCTest

/// ``SessionModel``'s phase as the shell reads it, over a real container: signed in, signed
/// out, deleted, and the sentence for every reason the coordinator can give.
final class SessionModelPhaseTests: ScreenSnapshotTestCase {
    private static let suite = "com.distronode.district.tests.session-phase"

    private func model(_ container: AppContainer) -> (SessionModel, WorkspaceSelectionStore) {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        let selection = WorkspaceSelectionStore(defaults: UserDefaults(suiteName: Self.suite) ?? .standard)
        let push = PushRegistrar(container: container)
        return (SessionModel(container: container, push: push, selection: selection), selection)
    }

    func testASignedInContainerIsSignedIn() async throws {
        let (session, _) = try await model(container(FixtureTransport()))
        XCTAssertEqual(session.phase, .checking)
        await session.refreshPhase()
        XCTAssertEqual(session.phase, .signedIn)
    }

    /// Signing out ends signed out with its sentence, forgets the chosen workspace and asks
    /// the service to revoke the session.
    func testSigningOut() async throws {
        let transport = FixtureTransport(["/api/auth/native/revoke": .json(#"{"success":true}"#)])
        let (session, selection) = try await model(container(transport))
        selection.setSelectedWorkspaceId("ws-contract-test")
        await session.refreshPhase()

        await session.signOut()

        XCTAssertEqual(session.phase, .signedOut(SessionCopy.signedOut))
        XCTAssertNil(selection.selectedWorkspaceId())
        XCTAssertFalse(session.isBusy)
        await session.refreshPhase()
        guard case .signedOut = session.phase else {
            return XCTFail("a signed-out container read back as \(session.phase)")
        }
    }

    /// A deleted account says so, with the erasure note when the service still has work to do.
    func testADeletedAccount() async throws {
        for (pending, sentence) in [
            (false, DeleteAccountCopy.deleted),
            (true, DeleteAccountCopy.deletedErasurePending),
        ] {
            let (session, selection) = try await model(container(FixtureTransport()))
            selection.setSelectedWorkspaceId("ws-contract-test")
            await session.finishDeletedAccount(externalErasurePending: pending)
            XCTAssertEqual(session.phase, .signedOut(sentence), "pending \(pending)")
            XCTAssertNil(selection.selectedWorkspaceId())
        }
    }

    /// Without an adopted session, the phase is signed out with no sentence (nobody signed
    /// out; there was never a session).
    func testNoSessionIsSignedOutWithoutASentence() async throws {
        let container = try await container(FixtureTransport())
        await container.coordinator.forget()
        let (session, _) = model(container)
        await session.refreshPhase()
        XCTAssertEqual(session.phase, .signedOut(""))
    }

    /// Every reason has its own sentence, in both languages, and only "no session" is silent.
    func testEveryReasonHasItsSentence() {
        let reauth: [ReauthReason] = [.interruptedRefresh, .refreshTokenExpired, .refreshRejected, .refreshUnreachable]
        let retry: [RetryReason] = [.refreshThrottled, .refreshNotSent, .storeUnavailable, .markerNotDurable]
        for locale in [L10nLocale.en, .frCA] {
            L10nRuntime.withLocale(locale) {
                XCTAssertEqual(SessionModel.text(for: ReauthReason.noSession), "")
                let sentences = reauth.map { SessionModel.text(for: $0) } + retry.map { SessionModel.text(for: $0) }
                XCTAssertFalse(sentences.contains(""), "\(locale)")
                XCTAssertEqual(Set(sentences).count, sentences.count, "each reason reads differently in \(locale)")
            }
        }
    }
}
