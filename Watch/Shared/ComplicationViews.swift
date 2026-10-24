import SwiftUI
import WidgetKit

/// The complication, in each accessory family. Compiled into the widget and, for the
/// debug preview screen only, into the watch app.
///
/// ⛔ AVAILABILITY ONLY. See ``ComplicationState``.
struct ComplicationView: View {
    let state: ComplicationState
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            Text(inline)
        default:
            circular
        }
    }

    private var symbol: String {
        guard state.signedIn, let available = state.available else { return "phone.badge.questionmark" }
        return available ? "phone.fill" : "phone.down.fill"
    }

    /// One word for the state, with no workspace.
    private var word: String {
        guard state.signedIn else { return WatchCopy.signedOut }
        guard let available = state.available else { return WatchCopy.openIphone }
        return available ? WatchCopy.available : WatchCopy.notAvailable
    }

    /// The rectangular family's one-line headline: ``word``, except that the full "Open
    /// District AI on your iPhone" cannot fit one line there, so it takes the short form.
    static func headline(for state: ComplicationState) -> String {
        guard state.signedIn else { return WatchCopy.signedOut }
        guard let available = state.available else { return WatchCopy.openIphoneShort }
        return available ? WatchCopy.available : WatchCopy.notAvailable
    }

    private var inline: String {
        guard state.signedIn, let available = state.available, let name = state.workspaceName else { return word }
        return available ? WatchCopy.availableIn(name) : WatchCopy.notAvailableIn(name)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: symbol)
                .font(.title3)
                .widgetAccentable()
        }
        .accessibilityLabel(inline)
    }

    private var rectangular: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.headline(for: state))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if state.signedIn, let name = state.workspaceName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
