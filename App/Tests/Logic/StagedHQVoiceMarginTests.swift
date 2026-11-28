@testable import DistrictAI
import DistrictL10n
import DistrictModel
import Foundation
import XCTest

/// The staged HQ voice room of the screenshot lane: one scripted exchange in the person's
/// language, cut short by a disconnect. ⚠️ The script runs 3.4 s; the waits carry a margin.
@MainActor
final class StagedHQVoiceMarginTests: XCTestCase {
    override func tearDown() async throws {
        L10nRuntime.locale = .en
        try await super.tearDown()
    }

    private func runScript() async throws -> [HQVoiceEngineEvent] {
        let engine = StagedHQVoiceEngine()
        let collector = Task { await stagedDrain(engine.events) }
        try await engine.connect(url: "wss://staged.invalid", token: "t")
        try await Task.sleep(for: .milliseconds(4000))
        await engine.disconnect()
        return await collector.value
    }

    func testTheWholeScriptPlaysInOrderInEnglish() async throws {
        L10nRuntime.locale = .en
        let events = try await runScript()

        XCTAssertEqual(events.count, 8)
        XCTAssertEqual(events.first, .connected, "the join is reported at once")
        XCTAssertEqual(events[1], .agentState(.listening))
        XCTAssertEqual(events[2], .transcript(HQVoiceSegment(
            id: "seg-1",
            text: "Add a note to Maya Chen's contact.",
            isFinal: true,
            fromMember: true
        )))
        XCTAssertEqual(events[3], .agentState(.thinking))
        XCTAssertEqual(events[4], .agentState(.speaking))
        guard case let .transcript(reply) = events[5] else {
            return XCTFail("HQ's reply, got \(events[5])")
        }
        XCTAssertFalse(reply.fromMember)
        XCTAssertTrue(reply.isFinal)
        XCTAssertEqual(reply.id, "seg-2")
        guard case let .packet(.proposal(proposal)) = events[6] else {
            return XCTFail("the proposal, got \(events[6])")
        }
        XCTAssertEqual(proposal.proposalId, "prop-staged-1")
        XCTAssertEqual(proposal.tool, "add_contact_note")
        XCTAssertEqual(
            proposal.args,
            .object(["contactId": .string("c_maya"), "note": .string("Prefers morning visits.")])
        )
        XCTAssertEqual(proposal.summary, "Add the note \"Prefers morning visits\" to Maya Chen.")
        XCTAssertEqual(events.last, .agentState(.listening), "HQ listens again after proposing")
    }

    /// The words are French when the person's language is; the write itself is not translated.
    func testTheScriptIsFrenchInFrench() async throws {
        L10nRuntime.locale = .frCA
        let events = try await runScript()

        XCTAssertEqual(events.count, 8)
        guard case let .transcript(member) = events[2], case let .packet(.proposal(proposal)) = events[6] else {
            return XCTFail("the scripted shape, got \(events)")
        }
        XCTAssertEqual(member.text, "Ajoute une note à la fiche de Maya Chen.")
        XCTAssertEqual(proposal.summary, "Ajouter la note « Préfère les visites le matin » à Maya Chen.")
        XCTAssertEqual(proposal.tool, "add_contact_note", "the wire value never localizes")
    }

    /// ⛔ A disconnect stops the script and finishes the stream: nothing arrives after it.
    func testADisconnectCutsTheScriptShort() async throws {
        let engine = StagedHQVoiceEngine()
        let collector = Task { await stagedDrain(engine.events) }
        try await engine.connect(url: "", token: "")
        try await Task.sleep(for: .milliseconds(100))
        await engine.disconnect()
        let events = await collector.value

        // ⚠️ A bound, not an exact list: a slow simulator may overshoot the wait past a step.
        XCTAssertEqual(events.first, .connected)
        XCTAssertLessThan(events.count, 8, "the script did not run to its end")
        XCTAssertFalse(events.contains {
            if case .packet = $0 {
                true
            } else {
                false
            }
        }, "no proposal was made")
    }

    /// ⚠️ Hostile order: a disconnect before any connect finishes the stream, and a second is harmless.
    func testADisconnectBeforeConnectingFinishesTheStream() async {
        let engine = StagedHQVoiceEngine()
        let collector = Task { await stagedDrain(engine.events) }
        await engine.disconnect()
        await engine.disconnect()
        let events = await collector.value
        XCTAssertEqual(events, [])
    }

    func testTheMicrophoneIsWhateverWasAskedAndAlwaysGranted() async {
        let engine = StagedHQVoiceEngine()
        let on = await engine.setMicrophone(enabled: true)
        let off = await engine.setMicrophone(enabled: false)
        XCTAssertTrue(on)
        XCTAssertFalse(off)
        XCTAssertEqual(StagedHQVoiceEngine.microphone.status, .granted)
        let granted = await StagedHQVoiceEngine.microphone.request()
        XCTAssertTrue(granted)
    }
}
