import SwiftUI

/// The hidden switch for the Apple Watch relay spike (W0): record timings, force the held
/// socket, and share the log.
///
/// ⛔ NOT A SETTINGS SCREEN, AND NOT FOR CUSTOMERS. It is reached by seven taps on the version
/// line on Account, and only in a Debug or TestFlight build (``WatchRelayDiagnostics/isAvailable()``);
/// the testers who run the spike are told where it is. See ``WatchRelayDiagnostics``.
struct WatchDiagnosticsView: View {
    let diagnostics: WatchRelayDiagnostics
    @State private var recording: Bool
    @State private var forceSocket: Bool
    @State private var count: Int

    init(diagnostics: WatchRelayDiagnostics = .shared) {
        self.diagnostics = diagnostics
        _recording = State(initialValue: diagnostics.recording)
        _forceSocket = State(initialValue: diagnostics.forceSocket)
        _count = State(initialValue: diagnostics.entries.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(WatchDiagnosticsCopy.recording, isOn: Binding(
                        get: { recording },
                        set: { value in
                            recording = value
                            diagnostics.recording = value
                        }
                    ))
                } footer: {
                    Text(WatchDiagnosticsCopy.recordingNote)
                }
                Section {
                    Toggle(WatchDiagnosticsCopy.forceSocket, isOn: Binding(
                        get: { forceSocket },
                        set: { value in
                            forceSocket = value
                            diagnostics.forceSocket = value
                        }
                    ))
                } footer: {
                    Text(WatchDiagnosticsCopy.forceSocketNote)
                }
                Section {
                    LabeledContent(WatchDiagnosticsCopy.entries) {
                        Text(count, format: .number)
                    }
                    if count > 0 {
                        ShareLink(item: export()) {
                            Label(WatchDiagnosticsCopy.share, systemImage: "square.and.arrow.up")
                        }
                        Button(WatchDiagnosticsCopy.clear, role: .destructive) {
                            diagnostics.clear()
                            count = 0
                        }
                    } else {
                        Text(WatchDiagnosticsCopy.empty)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(WatchDiagnosticsCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { count = diagnostics.entries.count }
        }
    }

    /// The header names the build and the switch, so a log read later says what produced it.
    private func export() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return diagnostics.export(header: [
            "District AI \(version) (\(build)), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "watch relay mode: \(diagnostics.forceSocket ? "socket" : "snapshot")",
        ])
    }
}
