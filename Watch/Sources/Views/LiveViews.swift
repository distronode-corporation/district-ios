import SwiftUI

/// A call in progress: its transcript as it is spoken, and the lines that steer the assistant.
///
/// ⛔ THE TRANSCRIPT IS HELD WHILE THIS SCREEN IS, AND NO LONGER: ``WatchLiveStore/open(_:)`` on
/// appear, ``WatchLiveStore/close()`` on disappear, which also tells the phone to stop.
///
/// ⛔ NO STEERING FOR A VIEWER (``WatchLiveCall/canWhisper``): the buttons are not drawn, rather
/// than drawn and refused.
struct LiveCallView: View {
    let store: WatchStore
    let call: WatchLiveCall
    @State private var draft = ""

    private static let bottom = "watch.live.bottom"

    private var transcript: WatchLiveTranscript? {
        store.live.transcript?.call.id == call.id ? store.live.transcript : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    status
                    lines
                    Color.clear
                        .frame(height: 1)
                        .listRowBackground(Color.clear)
                        .id(Self.bottom)
                }
                if call.canWhisper, transcript?.phase != .ended {
                    steering
                }
            }
            // ⚠️ THE NEWEST LINE STAYS IN VIEW: a wrist glances, it does not scroll to find it.
            .onChange(of: transcript?.lines.count) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: transcript?.interim?.text) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .navigationTitle(call.caller)
        .onAppear { store.live.open(call) }
        .onDisappear { store.live.close() }
    }

    @ViewBuilder
    private var status: some View {
        Label(statusText, systemImage: transcript?.phase == .live ? "waveform" : "phone")
            .font(.footnote)
            .foregroundStyle(transcript?.phase == .live ? Color.accentColor : .secondary)
        if let failure = transcript?.failure {
            // ⛔ SAID, NOT IMPLIED: a transcript that stopped moving would read as silence.
            VStack(alignment: .leading, spacing: 2) {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                if failure == WatchCopy.iphoneNotReachable {
                    Text(WatchCopy.iphoneNotReachableBody)
                        .font(.caption2)
                }
            }
            .accessibilityIdentifier("watch.live.failure")
        }
        if transcript?.complete == false {
            Text(WatchCopy.liveIncomplete)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch transcript?.phase ?? .connecting {
        case .connecting: WatchCopy.liveConnecting
        case .live: WatchCopy.liveNow
        case .ended: WatchCopy.liveEnded
        case .unavailable: WatchCopy.liveUnavailable
        }
    }

    @ViewBuilder
    private var lines: some View {
        if let transcript {
            if transcript.lines.isEmpty, transcript.interim == nil, transcript.phase != .unavailable {
                Text(WatchCopy.liveWaiting)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(transcript.lines) { line in
                LiveLineRow(line: line, provisional: false)
            }
            if let interim = transcript.interim {
                LiveLineRow(line: interim, provisional: true)
            }
        }
    }

    private var steering: some View {
        let key = WriteKey.whisper(call.id)
        let sending = store.writes[key] == .sending
        return Section(WatchCopy.steerHeader) {
            Button(WatchCopy.whisperCallBackToday) { send(WatchCopy.whisperCallBackToday) }
                .disabled(sending)
            Button(WatchCopy.whisperAskWhatAbout) { send(WatchCopy.whisperAskWhatAbout) }
                .disabled(sending)
            // ⚠️ DICTATION OR SCRIBBLE: the system's text input on the watch offers both.
            TextField(WatchCopy.whisperOther, text: $draft)
                .onSubmit {
                    send(draft)
                    draft = ""
                }
                .disabled(sending)
            WriteStatusRow(store: store, key: key)
        }
        .accessibilityIdentifier("watch.live.steer")
    }

    private func send(_ text: String) {
        Task { await store.whisper(text, on: call) }
    }
}

/// One line of the transcript: who, then what.
struct LiveLineRow: View {
    let line: WatchLiveLine
    /// An interim line, still being heard: drawn lighter, and replaced as it settles.
    let provisional: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(line.speaker)
                .font(.caption2)
                .foregroundStyle(line.fromCaller ? Color.secondary : Color.accentColor)
            Text(line.text)
                .font(.footnote)
                .foregroundStyle(provisional ? Color.secondary : Color.primary)
                .italic(provisional)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One call's card: who, how it went, the summary and what to do next, and "Call back".
///
/// ⚠️ THE SNAPSHOT'S ROW FIRST, WHEN THERE IS ONE, so Recent calls opens on something at once
/// and a phone too old to answer the card (``WatchCardState/failed(_:)``) still shows what the
/// list already knew.
///
/// ⛔ "CALL BACK" IS A HANDOFF, NOT A CALL: the watch places nothing, and the activity carries
/// the call id (``CallBackHandoff``), never the number. The phone looks the number up and only
/// fills its dialler.
struct CallCardView: View {
    let store: WatchStore
    let workspaceId: String
    let callId: String
    let seed: WatchSnapshot.Call?
    @State private var handingOff = false

    private var state: WatchCardState? {
        store.live.cards[callId]
    }

    private var card: WatchCallCard? {
        if case let .card(card, _) = state {
            return card
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                summary
                callBack
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding(.horizontal)
        }
        .navigationTitle(WatchCopy.callTitle)
        .task(id: callId) { await store.live.loadCard(workspaceId: workspaceId, callId: callId) }
        .userActivity(CallBackHandoff.activityType, isActive: handingOff) { activity in
            activity.isEligibleForHandoff = true
            activity.addUserInfoEntries(from: CallBackHandoff.userInfo(workspaceId: workspaceId, callId: callId))
        }
    }

    @ViewBuilder
    private var header: some View {
        if let caller = card?.caller ?? seed?.caller {
            Text(caller)
                .font(.headline)
        }
        if let direction = seed?.direction {
            Text(direction)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let time = card?.time ?? seed?.time {
            field(WatchCopy.when, time)
        }
        if let outcome = card?.outcome ?? seed?.outcome {
            field(WatchCopy.outcome, outcome)
        }
        if let duration = seed?.duration {
            field(WatchCopy.duration, duration)
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch state {
        case .none, .loading:
            ProgressView()
        case let .card(card, asking):
            if let summary = card.summary {
                field(WatchCopy.summary, summary)
            } else if card.summaryPending, asking {
                HStack {
                    ProgressView()
                        .frame(width: 20)
                    Text(WatchCopy.summaryOnItsWay)
                        .font(.footnote)
                }
                .accessibilityIdentifier("watch.card.pending")
            } else {
                Text(card.summaryNote ?? WatchCopy.noSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !card.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WatchCopy.actionItems)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(card.actionItems, id: \.self) { item in
                        Text("• \(item)")
                            .font(.footnote)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(seed == nil ? Color.red : Color.secondary)
        }
    }

    @ViewBuilder
    private var callBack: some View {
        if card?.canCallBack == true {
            Button(WatchCopy.callBack) { handingOff = true }
                .accessibilityIdentifier("watch.card.call-back")
            if handingOff {
                Text(WatchCopy.callBackHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote)
        }
        .accessibilityElement(children: .combine)
    }
}
