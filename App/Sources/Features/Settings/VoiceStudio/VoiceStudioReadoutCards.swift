import DistrictData
import DistrictModel
import SwiftUI

/// A leg's number, a meter's headline: the words for each, never an estimate.
///
/// ⛔ FROM THE SERVICE'S TEMPLATES, IN THE PORTAL LANGUAGE (``VoiceStudioText``): the app types
/// none of these words (Sean, 2026-10-03: "Follow the portal language").
extension VoiceStudioLatencyText {
    /// The server's sentence, a measured median the server sent as a bare number, or the
    /// server's "not measured yet".
    func text(_ labels: VoiceStudioLabels) -> String {
        VoiceStudioText.latency(self, labels: labels)
    }
}

extension VoiceStudioMeterHeadline {
    /// ⛔ "AT LEAST" WHENEVER A STAGE IS MISSING, NEVER "ABOUT".
    func text(_ labels: VoiceStudioLabels) -> String {
        VoiceStudioText.headline(self, labels: labels)
    }
}

/// The signal chain: one block per leg (one for a realtime engine), each with its model, its
/// channel, where it is processed IN TEXT, and its own number. Tapping a block opens its editor.
struct VoiceStudioChainCard: View {
    let model: VoiceStudioModel
    let session: VoiceStudioSession

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var labels: VoiceStudioLabels {
        session.studio.labels
    }

    private var blocks: [VoiceStudioBlockView] {
        VoiceStudioReadout.blocks(session.held.engine, in: session.studio)
    }

    var body: some View {
        SettingsCard(eyebrow: labels.chainLabel) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { entry in
                block(entry.element)
            }
        }
    }

    private func block(_ block: VoiceStudioBlockView) -> some View {
        let leg = VoiceStudioLeg(rawValue: block.leg)
        let selected = leg == session.leg
        return Button {
            if let leg {
                model.selectLeg(leg)
            }
        } label: {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                HStack(spacing: DistrictSpacing.tight) {
                    Text(block.title)
                        .font(DistrictType.titleSmall)
                        .foregroundStyle(colors.foreground)
                    DistrictBadge(text: block.channelLabel, tone: VoiceStudioChannel.tone(block.channel))
                }
                caption(block.role)
                Text(block.model)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                caption(block.place)
                caption(block.latency.text(labels))
                if let note = block.note {
                    caption(note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DistrictSpacing.tight)
            .districtCardSurface(bordered: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(labels.edit)
        .accessibilityIdentifier(
            A11yID.VoiceStudio.handle(A11yID.VoiceStudio.blockKind, block.leg, selected: selected)
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Time to first word: the headline, each stage, and where the numbers come from.
///
/// ⛔ NEVER INVENTED. The server's own meter whenever it described the held engine; otherwise
/// the sum of the measured medians the same response carries, "at least" when a stage has none.
struct VoiceStudioMeterCard: View {
    let session: VoiceStudioSession

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        let labels = session.studio.labels
        let meter = VoiceStudioReadout.meter(session.held.engine, in: session.studio)
        return SettingsCard(eyebrow: labels.meterHeading) {
            Text(meter.headline.text(labels))
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
                .accessibilityIdentifier(A11yID.VoiceStudio.meter)
            caption(labels.meterDescription)
            ForEach(Array(meter.stages.enumerated()), id: \.offset) { entry in
                SettingsReadOnlyRow(label: entry.element.label, value: entry.element.value.text(labels))
            }
            if let note = meter.note {
                caption(note)
            }
            caption(session.studio.latency.sourceText)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Where the call is processed, and one line per leg that leaves the region.
struct VoiceStudioResidencyCard: View {
    let session: VoiceStudioSession

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        let residency = VoiceStudioReadout.residency(session.held.engine, in: session.studio)
        return SettingsCard(eyebrow: session.studio.labels.residencyHeading) {
            Text(residency.text)
                .font(DistrictType.bodySmall)
                .foregroundStyle(residency.inRegion ? colors.foreground : colors.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.VoiceStudio.residency)
            ForEach(residency.legsOut, id: \.self) { line in
                Text(line)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
