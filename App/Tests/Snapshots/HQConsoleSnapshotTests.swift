@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The HQ console after a question: its answer, a proposed change waiting for the person's
/// decision, the change applied, and a refused question, each drawn from the service's
/// recorded replies to `POST /api/district/hq`.
///
/// ⚠️ THE MODEL IS DRIVEN AS THE PERSON WOULD DRIVE IT, in the view's own task (a question
/// asked, a change confirmed), so the harness's wait covers every request that sends.
final class HQConsoleSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let hq = "/api/district/hq"
    private static let question = "How many calls did we get this week?"

    private func console(
        _ container: AppContainer,
        role: WorkspaceRole = .client,
        _ step: @escaping @MainActor (HQModel) async -> Void
    ) -> some View {
        let model = HQModel(container: container, workspaceId: Self.workspace, role: role)
        return SnapshotPrepared(
            HQView(container: container, workspaceId: Self.workspace, role: role, model: model)
        ) {
            await step(model)
        }
    }

    func testAnAnswer() async throws {
        try await assertScreen([Self.hq: .fixture("district-hq-answer")]) { container in
            self.console(container) { await $0.ask(Self.question) }
        }
    }

    /// A proposed change shows the confirm card for a client, who may apply it.
    func testAProposedChange() async throws {
        try await assertScreen([Self.hq: .fixture("district-hq-pending-write")]) { container in
            self.console(container) { await $0.ask("Change the greeting") }
        }
    }

    /// A viewer gets the same proposal and no way to apply it.
    func testAProposedChangeForAViewer() async throws {
        try await assertScreen([Self.hq: .fixture("district-hq-pending-write")], devices: [.iPhone]) { container in
            self.console(container, role: .viewer) { await $0.ask("Change the greeting") }
        }
    }

    /// Confirmed: the card goes and the console says the change was applied.
    func testTheChangeApplied() async throws {
        try await assertScreen(
            sequences: [Self.hq: [.fixture("district-hq-pending-write"), .fixture("district-hq-confirm")]],
            devices: [.iPhone]
        ) { container in
            self.console(container) { model in
                await model.ask("Change the greeting")
                await model.confirmPending()
            }
        }
    }

    /// A confirmation the service refuses keeps the card, with the failure under it.
    func testTheConfirmationRefused() async throws {
        try await assertScreen(
            sequences: [
                Self.hq: [.fixture("district-hq-pending-write"), .json(#"{"error":"Internal error"}"#, status: 500)],
            ],
            devices: [.iPhone]
        ) { container in
            self.console(container) { model in
                await model.ask("Change the greeting")
                await model.confirmPending()
            }
        }
    }

    /// A refused question leaves the person's message in the transcript, with a retry.
    func testARefusedQuestion() async throws {
        try await assertScreen(
            [Self.hq: .json(#"{"error":"Internal error"}"#, status: 500)],
            devices: [.iPhone]
        ) { container in
            self.console(container) { await $0.ask(Self.question) }
        }
    }
}
