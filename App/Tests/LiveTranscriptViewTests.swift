@testable import DistrictAI
import DistrictLive
import DistrictModel
import Foundation
import Testing

/// ⛔ THE LIVE TRANSCRIPT SECTION, DRAWN IN EVERY STATE ITS MODEL REACHES.
///
/// Each state is reached the way the app reaches it: the real model, the core's reducer and
/// runner, and the real socket adapter over a ``FakeWebSocketTask``, with the frames the
/// contract defines (§4.11, §4.12) and a manual clock, so the full transcript's backoff takes
/// no time. The section is drawn in a window and read back through accessibility
/// (``HostedAccessibility``): what is asserted is the words, labels and identifiers a person
/// or a UI test meets, and drawing them runs the view's body.
@MainActor
@Suite(.serialized)
struct LiveTranscriptViewTests {
    private let clock = ManualLiveClock()
    private let script = SocketScript()

    private func makeModel(_ transcripts: ScriptedTranscripts = .init([.success("")])) -> LiveTranscriptModel {
        LiveTranscriptModel(
            workspaceId: TranscriptWire.workspaceId,
            callId: TranscriptWire.callId,
            dependencies: LiveTranscriptModel.Dependencies(
                minter: ScriptedMinter(clock: clock),
                transport: script.transport(clock: clock),
                clock: clock,
                jitter: { 0 },
                fetchTranscript: { transcripts.next() }
            )
        )
    }

    /// The section for `model`, on screen, with its socket open and subscribed.
    private func open(_ model: LiveTranscriptModel) async throws -> (HostedAccessibility, FakeWebSocketTask) {
        let screen = try HostedAccessibility(LiveTranscriptSection(model: model))
        model.activate()
        _ = await screen.elements { _ in
            script.tasks.first?.sent.count == 2 && model.connection == .open
        }
        return try (screen, #require(script.tasks.first))
    }

    /// Move the manual clock in steps until `condition` holds, letting the waits each step
    /// wakes run. ⚠️ Steps, not one jump: a wait that starts after a jump is timed from after it.
    private func advance(until condition: () -> Bool) async {
        for _ in 0 ..< 400 where !condition() {
            clock.advance(by: 1000)
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func has(_ label: String) -> ([HostedAccessibility.Element]) -> Bool {
        { $0.labels.contains(label) }
    }

    private static func lacks(_ label: String) -> ([HostedAccessibility.Element]) -> Bool {
        { !$0.labels.contains(label) }
    }

    // MARK: - Before the first line

    /// Subscribed, the snapshot not in yet (the server holds it until the first line, up to
    /// 30 s): the heading and "Connecting…", nothing else, inside the pane's identifier.
    @Test func `connecting shows the heading and connecting`() async throws {
        let model = makeModel()
        let (screen, _) = try await open(model)
        defer { screen.close() }

        let shown = await screen.elements(when: Self.has(LiveTranscriptCopy.connecting))

        #expect(shown.identified(A11yID.Calls.liveTranscript) != nil)
        #expect(shown.labels.contains("Live transcript"))
        #expect(shown.labels.contains("Connecting…"))
        #expect(!shown.labels.contains(LiveTranscriptCopy.waiting), "not live yet, so not 'nothing said'")
        #expect(shown.identified(A11yID.Calls.liveIncomplete) == nil)
        #expect(shown.identified(A11yID.Calls.transcript) == nil)
        model.deactivate()
    }

    // MARK: - Live

    /// The lines as they are spoken: the persona's name on an assistant line, "Caller", a
    /// fallback for an unnamed assistant and an unknown speaker, "Interrupted" under a line
    /// that was cut off, and an interim line drawn among them.
    @Test func `live lines name their speakers and mark an interruption`() async throws {
        let model = makeModel()
        let (screen, task) = try await open(model)
        defer { screen.close() }

        task.deliver(TranscriptWire.snapshot(
            [
                TranscriptWire.greeting,
                TranscriptWire.segment("item_b2", index: 1, seq: 2, text: "A cleaning, please."),
            ],
            lastSeq: 2
        ))
        task.deliver(TranscriptWire.live(TranscriptWire.segment(
            "item_c3", index: 2, seq: 3, speaker: "agent", text: "Of course", interrupted: true
        )))
        task.deliver(TranscriptWire.live(TranscriptWire.segment(
            "item_d4", index: 3, seq: 4, speaker: "agent", speakerName: nil, text: "One moment."
        )))
        task.deliver(TranscriptWire.live(TranscriptWire.segment(
            "item_e5", index: 4, seq: 5, speaker: "supervisor", text: "Joining now."
        )))
        task.deliver(TranscriptWire.live(TranscriptWire.segment(
            "item_f6", index: 5, seq: 6, text: "Tuesday if you", final: false
        )))
        let shown = await screen.elements { $0.labels.contains { $0.contains("Tuesday if you") } }

        #expect(shown.labels.contains("Live"))
        let lines = shown.labels.filter { label in
            ["Good afternoon.", "A cleaning", "Of course", "One moment.", "Joining now.", "Tuesday"]
                .contains { label.contains($0) }
        }
        #expect(lines == [
            "Ava, Good afternoon.",
            "Caller, A cleaning, please.",
            "Ava, Of course, Interrupted",
            "Assistant, One moment.",
            "Other speaker, Joining now.",
            "Caller, Tuesday if you",
        ])
        #expect(!shown.labels.contains(LiveTranscriptCopy.waiting))
        #expect(shown.identified(A11yID.Calls.liveIncomplete) == nil)
        // Italic and muted are not in the accessibility tree; the flag that draws them is.
        #expect(LiveTranscriptContent(model).lines.map(\.provisional) == [false, false, false, false, false, true])
        model.deactivate()
    }

    /// ⛔ D3: A SNAPSHOT THAT DOES NOT REACH BACK TO THE CALL'S FIRST LINE SAYS SO, under its
    /// own identifier, above the lines it does have.
    @Test func `an incomplete snapshot says earlier lines come after the call`() async throws {
        let model = makeModel()
        let (screen, task) = try await open(model)
        defer { screen.close() }

        task.deliver(TranscriptWire.snapshot(
            [TranscriptWire.segment("item_k9", index: 9, seq: 14, text: "And the address?")],
            lastSeq: 14,
            complete: false
        ))
        let shown = await screen.elements { $0.identified(A11yID.Calls.liveIncomplete) != nil }

        #expect(shown.identified(A11yID.Calls.liveIncomplete)?.label == LiveTranscriptCopy.incomplete)
        #expect(shown.labels.contains("Earlier lines will appear in the full transcript after the call."))
        #expect(shown.labels.contains("Caller, And the address?"))
        #expect(shown.labels.contains("Live"))
        model.deactivate()
    }

    // MARK: - Reconnecting and the end

    /// ⛔ `agent_error` IS NOT THE END: "Reconnecting…", the lines stay, nothing is fetched.
    @Test func `an agent error shows reconnecting and keeps the lines`() async throws {
        let transcripts = ScriptedTranscripts([.success("never asked")])
        let model = makeModel(transcripts)
        let (screen, task) = try await open(model)
        defer { screen.close() }
        task.deliver(TranscriptWire.snapshot([TranscriptWire.greeting], lastSeq: 1))
        _ = await screen.elements(when: Self.has("Live"))

        task.deliver(TranscriptWire.ended(seq: 2, reason: "agent_error"))
        let shown = await screen.elements(when: Self.has(LiveTranscriptCopy.reconnecting))

        #expect(shown.labels.contains("Reconnecting…"))
        #expect(shown.labels.contains("Ava, Good afternoon."))
        #expect(!shown.labels.contains(LiveTranscriptCopy.loadingFull))
        #expect(!shown.labels.contains("Call ended"))
        #expect(transcripts.count == 0)
        model.deactivate()
    }

    /// The call ended: "Call ended" and a spinner with "Loading the full transcript…" while it
    /// is fetched (it is written only after the call's session closes), then the full
    /// transcript in place of the spinner, under the identifier a UI test reads.
    @Test func `the end loads the full transcript then shows it`() async throws {
        let transcripts = ScriptedTranscripts([.success(""), .success("Ava: Good afternoon.\nCaller: Hi.")])
        let model = makeModel(transcripts)
        let (screen, task) = try await open(model)
        defer { screen.close() }
        task.deliver(TranscriptWire.snapshot([TranscriptWire.greeting], lastSeq: 1))
        _ = await screen.elements(when: Self.has("Live"))

        task.deliver(TranscriptWire.ended(seq: 2))
        let loading = await screen.elements(when: Self.has(LiveTranscriptCopy.loadingFull))
        #expect(loading.labels.contains("Call ended"))
        #expect(loading.labels.contains("Loading the full transcript…"))
        #expect(loading.labels.contains("Ava, Good afternoon."), "the live lines stay while it loads")
        #expect(loading.identified(A11yID.Calls.transcript) == nil)

        await advance { model.finalTranscript == .loaded("Ava: Good afternoon.\nCaller: Hi.") }
        let loaded = await screen.elements { $0.identified(A11yID.Calls.transcript) != nil }

        #expect(loaded.labels(identified: A11yID.Calls.transcript) == [
            "Transcript",
            "Ava: Good afternoon.\nCaller: Hi.",
        ])
        #expect(!loaded.labels.contains(LiveTranscriptCopy.loadingFull))
        #expect(loaded.labels.contains("Call ended"))
    }

    /// Still empty after every attempt: "No transcript for this call."
    @Test func `an empty full transcript says there is none`() async throws {
        let transcripts = ScriptedTranscripts([.success("  ")])
        let model = makeModel(transcripts)
        let (screen, task) = try await open(model)
        defer { screen.close() }
        task.deliver(TranscriptWire.snapshot([TranscriptWire.greeting], lastSeq: 1))
        task.deliver(TranscriptWire.ended(seq: 2, reason: "handed_off"))
        _ = await screen.elements(when: Self.has(LiveTranscriptCopy.loadingFull))

        await advance { model.finalTranscript == .empty }
        let shown = await screen.elements(when: Self.has(LiveTranscriptCopy.noTranscript))

        #expect(shown.labels.contains("No transcript for this call."))
        #expect(shown.labels.contains("Call ended"))
        #expect(!shown.labels.contains(LiveTranscriptCopy.loadingFull))
        #expect(transcripts.count == TranscriptReducer.finalFetchAttempts)
    }

    /// A fetch refused for good: the failure's words, in place of the transcript.
    @Test func `a failed full transcript says why`() async throws {
        let refusal = ApiError.http(status: 404, message: "Call not found")
        let model = makeModel(ScriptedTranscripts([.failure(refusal)]))
        let (screen, task) = try await open(model)
        defer { screen.close() }
        task.deliver(TranscriptWire.snapshot([TranscriptWire.greeting], lastSeq: 1))
        task.deliver(TranscriptWire.ended(seq: 2))
        _ = await screen.elements(when: Self.has(LiveTranscriptCopy.loadingFull))

        await advance { model.finalTranscript == .failed(refusal) }
        let message = FailureText.from(refusal).message
        let shown = await screen.elements(when: Self.has(message))

        #expect(message == "Call not found")
        #expect(!shown.labels.contains(LiveTranscriptCopy.loadingFull))
        #expect(shown.identified(A11yID.Calls.transcript) == nil)
    }

    // MARK: - No live transcript

    /// ⛔ `not_live`: the model falls back, which is what makes the call's screen swap this
    /// section for the transcript after the call (`CallDetailView.transcriptSection`). Drawn
    /// anyway, it keeps its heading and draws no line and no fetch.
    @Test func `not live falls back to the transcript after the call`() async throws {
        let model = makeModel()
        let (screen, task) = try await open(model)
        defer { screen.close() }

        task.deliver(TranscriptWire.error("not_live"))
        await advance { model.fallsBack }
        let shown = await screen.elements(when: Self.has(LiveTranscriptCopy.heading))

        #expect(model.fallsBack)
        #expect(model.phase == .unavailable(.notLive))
        #expect(shown.labels.contains("Live transcript"))
        #expect(!shown.labels.contains(LiveTranscriptCopy.waiting))
        #expect(!shown.labels.contains(LiveTranscriptCopy.loadingFull))
        #expect(shown.identified(A11yID.Calls.transcript) == nil)
    }

    // MARK: - Retracted and purged

    /// ⛔ A RETRACTED LINE COMES OFF THE SCREEN, and once every line is retracted the live
    /// pane says nothing has been said rather than keeping a stale line.
    @Test func `retracted lines come off the screen`() async throws {
        let model = makeModel()
        let (screen, task) = try await open(model)
        defer { screen.close() }
        task.deliver(TranscriptWire.snapshot(
            [
                TranscriptWire.greeting,
                TranscriptWire.segment("item_b2", index: 1, seq: 2, text: "My card is 4111."),
            ],
            lastSeq: 2
        ))
        _ = await screen.elements(when: Self.has("Caller, My card is 4111."))

        task.deliver(TranscriptWire.retracted(["item_b2"], seq: 3))
        let one = await screen.elements(when: Self.lacks("Caller, My card is 4111."))
        #expect(one.labels.contains("Ava, Good afternoon."))
        #expect(!one.labels.contains(LiveTranscriptCopy.waiting))

        task.deliver(TranscriptWire.retracted([], all: true))
        let none = await screen.elements(when: Self.has(LiveTranscriptCopy.waiting))
        #expect(!none.labels.contains("Ava, Good afternoon."))
        #expect(none.labels.contains("Nothing has been said yet."))
        #expect(none.labels.contains("Live"))
        model.deactivate()
    }

    /// ⛔ §4.12 Q12: THE SNAPSHOT AFTER A PURGE HAS NO EPOCH AND NO LINE. The pane is live and
    /// empty, and the next line sets the baseline and is drawn.
    @Test func `a purged snapshot is live and empty until the next line`() async throws {
        let model = makeModel()
        let (screen, task) = try await open(model)
        defer { screen.close() }

        task.deliver(TranscriptWire.purgedSnapshot)
        let empty = await screen.elements(when: Self.has(LiveTranscriptCopy.waiting))
        #expect(empty.labels.contains("Live"))

        task.deliver(TranscriptWire.live(TranscriptWire.segment("item_z1", index: 7, seq: 12, text: "Still there?")))
        let line = await screen.elements(when: Self.has("Caller, Still there?"))
        #expect(!line.labels.contains(LiveTranscriptCopy.waiting))
        model.deactivate()
    }
}
