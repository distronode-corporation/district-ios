@testable import DistrictAI
import DistrictData
import DistrictModel
import SwiftUI
import XCTest

/// Voice Studio's leg editor for each leg of the recorded chained engine and for a realtime
/// one, and the save card in each outcome, drawn from the service's recorded studio.
///
/// ⚠️ EACH LEG IS DRAWN WITH ITS ADVANCED LIST BELOW IT, as the editor's "Show advanced"
/// button reveals it: the list is ``VoiceStudioTuningList`` over the leg's `advanced` keys,
/// the same keys the editor passes it. The button's own flag is view-private state.
final class SettingsVoiceStudioSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let persona = "PATCH /api/district/workspace/persona"

    // MARK: - The legs

    /// The ear: provider, model and the key terms box.
    func testEarLeg() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.leg(container) { model in model.selectLeg(.stt) }
        }
    }

    /// The ear with key terms typed, which the box shows one per line.
    func testEarLegWithKeyTerms() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            Self.leg(container) { model in
                model.selectLeg(.stt)
                model.editMix { mix in
                    var next = mix
                    next.stt.keyterms = ["Distronode", "Etobicoke"]
                    return next
                }
            }
        }
    }

    /// Turn-taking: speak sooner, then the end-of-turn and interruption sliders.
    func testTurnLeg() async throws {
        try await assertScreen { container in
            Self.leg(container) { model in model.selectLeg(.turn) }
        }
    }

    /// Turn-taking tuned off its defaults: speak sooner on and a held minimum delay, so the
    /// slider is live and its "use default" toggle is off.
    func testTurnLegTuned() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            Self.leg(container) { model in
                model.selectLeg(.turn)
                model.editMix { mix in
                    var next = mix
                    next.preemptiveTts = true
                    next.turn.minDelay = 0.6
                    return next
                }
            }
        }
    }

    /// The brain: its model, its location, its thinking level and temperature.
    func testBrainLeg() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.leg(container) { model in model.selectLeg(.llm) }
        }
    }

    /// The mouth: provider, model, the voice, and its speed and stability.
    func testMouthLeg() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.leg(container) { model in model.selectLeg(.tts) }
        }
    }

    /// A realtime engine is one leg: its model, its voice, temperature and voice style.
    func testRealtimeLeg() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.leg(container) { model in
                model.applyRecipe("realtime")
                model.selectLeg(.realtime)
            }
        }
    }

    // MARK: - Saving

    /// A recipe picked and not saved: the card says so and offers Save.
    func testUnsavedRecipe() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.cards(container) { model in model.applyRecipe("natural") }
        }
    }

    /// ⛔ THE SERVICE ACCEPTED THE WRITE BUT READ BACK THE OLD ENGINE: "saved" is not said.
    func testSaveTheServiceDidNotKeep() async throws {
        try await assertScreen([Self.persona: .fixture("district-persona-patch")], devices: [.iPhone]) { container in
            Self.cards(container) { model in
                model.applyRecipe("natural")
                await model.saveChanges()
            }
        }
    }

    /// The service refused the engine mix, in its own words.
    func testSaveRefusedAsAnInvalidMix() async throws {
        let refusal = FixtureTransport.Reply.json(
            #"{"success":false,"code":"invalid_engine_mix","error":"That voice is not offered on that model"}"#,
            status: 400
        )
        try await assertScreen([Self.persona: refusal], devices: [.iPhone], locales: [.en]) { container in
            Self.cards(container) { model in
                model.applyRecipe("natural")
                await model.saveChanges()
            }
        }
    }

    /// A model the region does not offer, refused with no sentence: the screen's own stands in.
    func testSaveRefusedForTheRegion() async throws {
        let refusal = FixtureTransport.Reply.json(
            #"{"success":false,"code":"model_unavailable_in_region"}"#,
            status: 400
        )
        try await assertScreen([Self.persona: refusal], devices: [.iPhone]) { container in
            Self.cards(container) { model in
                model.applyRecipe("natural")
                await model.saveChanges()
            }
        }
    }

    // MARK: - The screen

    func testVoiceStudioFailed() async throws {
        try await assertScreen(
            ["/api/district/workspace/persona/voice-studio": .refused(500)],
            devices: [.iPhone]
        ) { container in
            SettingsDestinations.view(
                for: .voiceStudio, container: container, workspaceId: Self.workspace, role: .client
            )
        }
    }

    // MARK: - Helpers

    private static func leg(
        _ container: AppContainer,
        drive: @escaping @MainActor @Sendable (VoiceStudioModel) async -> Void
    ) -> some View {
        let model = VoiceStudioModel(container: container, workspaceId: workspace, role: .client)
        return VoiceStudioLegHost(model: model)
            .task {
                await model.loadStudio()
                await drive(model)
            }
    }

    private static func cards(
        _ container: AppContainer,
        drive: @escaping @MainActor @Sendable (VoiceStudioModel) async -> Void
    ) -> some View {
        let model = VoiceStudioModel(container: container, workspaceId: workspace, role: .client)
        return VoiceStudioCardsHost(model: model)
            .task {
                await model.loadStudio()
                await drive(model)
            }
    }
}

/// The selected leg's editor, and its advanced list as the editor reveals it.
private struct VoiceStudioLegHost: View {
    let model: VoiceStudioModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                if let session = model.session {
                    VoiceStudioLegEditor(model: model, session: session)
                    let advanced = VoiceStudioTuning.keys(
                        for: session.leg,
                        engine: session.held.engine,
                        in: session.studio
                    ).filter { $0.section == "advanced" }
                    if !advanced.isEmpty {
                        SettingsCard(eyebrow: session.studio.labels.advanced) {
                            VoiceStudioTuningList(model: model, session: session, keys: advanced)
                        }
                    }
                }
            }
            .padding(DistrictSpacing.gutter)
        }
    }
}

/// The save card over the recipe tiles, the two a save is judged by.
private struct VoiceStudioCardsHost: View {
    let model: VoiceStudioModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                if let session = model.session {
                    VoiceStudioSaveCard(model: model, session: session)
                    VoiceStudioRecipesCard(model: model, session: session)
                }
            }
            .padding(DistrictSpacing.gutter)
        }
    }
}
