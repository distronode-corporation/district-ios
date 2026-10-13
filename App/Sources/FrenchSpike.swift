import SwiftUI

/// SPIKE (do not merge): how the bundle resolves French, shown on screen so a UI test
/// can read it back after launching with `-AppleLanguages (xx)`.
enum FrenchSpike {
    static let launchArgument = "-FrenchSpikeProbe"

    static var isArmed: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The run-time choice a `*Copy` computed var would make.
    static var isFrench: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("fr") == true
    }
}

struct FrenchSpikeProbeView: View {
    private struct Row: Identifiable {
        let id: String
        let value: String
    }

    private var rows: [Row] {
        let bundle = Bundle.main
        let mic = bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        return [
            Row(id: "spike.preferred", value: bundle.preferredLocalizations.first ?? "nil"),
            Row(id: "spike.preferredAll", value: bundle.preferredLocalizations.joined(separator: ",")),
            Row(id: "spike.localizations", value: bundle.localizations.joined(separator: ",")),
            Row(id: "spike.developmentLocalization", value: bundle.developmentLocalization ?? "nil"),
            Row(id: "spike.preferredLanguages", value: Locale.preferredLanguages.joined(separator: ",")),
            Row(id: "spike.pushMessageTitle", value: NSLocalizedString("push.message.title", comment: "")),
            Row(id: "spike.pushCallBody", value: NSLocalizedString("push.call.body", comment: "")),
            Row(id: "spike.pushGenericBody", value: NSLocalizedString("push.generic.body", comment: "")),
            Row(id: "spike.mic", value: mic ?? "nil"),
            Row(id: "spike.deskSubtitle", value: DeskCopy.subtitle),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    Text(row.value.isEmpty ? "(empty)" : row.value)
                        .font(.caption2)
                        .accessibilityIdentifier(row.id)
                }
            }
        }
    }
}
