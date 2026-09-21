import DistrictModel
import SwiftUI

/// The Connect controls for the two OAuth calendar providers, plus the browser
/// sheet the round trip happens in.
///
/// ⛔ THE HAND-OFF URL GOES STRAIGHT INTO THE SHEET AND NOWHERE ELSE. It carries a
/// 60-second single-use token, so `sheet(item:)` is what guarantees it is dropped
/// the moment the browser closes — SwiftUI writes nil back through the binding
/// itself. The model answers it rather than storing it.
///
/// ⛔ AND A NEW ONE IS MINTED PER PRESS. The code is single-use and lives about
/// sixty seconds, so a cached one is stale exactly when somebody needs it — and a
/// stale code lands on a page saying the link has expired, which reads as a broken
/// app rather than as a code that did its job.
///
/// ⚠️ THE APP IS NOT TOLD WHAT HAPPENED IN THE BROWSER. The provider's callback
/// appends `calendar=connected` or `calendar=error` to a page this process never
/// sees, so the sheet's dismissal triggers a re-read and the status is what says
/// which accounts are connected. That is why there is no success sentence here.
struct SchedulingCalendarConnectSection: View {
    let model: SchedulingCalendarConnectModel
    let status: SchedulingCalendarStatus

    @State private var handOff: SchedulingHandOff?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var providers: [String] {
        SchedulingCalendarConnectModel.offeredProviders(status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            content
            if let failure = model.failure {
                SchedulingWriteFailureLineC(failure: failure, onDismiss: model.dismissFailure)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $handOff, onDismiss: model.handOffFinished) { target in
            SafariView(url: target.url)
        }
    }

    @ViewBuilder
    private var content: some View {
        if providers.isEmpty {
            // ⚠️ ONE SENTENCE AND NO CONTROL. An instance with no calendar
            // credentials cannot be fixed from a phone, and a button that could only
            // fail is worse than none.
            Text(SchedulingWriteCopyC.connectNotConfigured)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        } else {
            Text(SchedulingWriteCopyC.connectHandOffNote)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            ForEach(providers, id: \.self) { provider in
                Button(SchedulingWriteCopyC.connectProvider(provider)) {
                    connect(provider)
                }
                .buttonStyle(.districtSecondary)
                .disabled(model.busy)
                .accessibilityIdentifier(A11yID.SchedulingCalendarWrites.connect(provider))
            }
        }
    }

    private func connect(_ provider: String) {
        Task {
            guard let url = await model.connect(provider: provider) else { return }
            handOff = SchedulingHandOff(url: url)
        }
    }
}
