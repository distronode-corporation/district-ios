import SwiftUI
import WidgetKit

/// The availability complication, in each accessory family. Compiled into the widget and,
/// for the debug preview screen only, into the watch app.
///
/// ⛔ AVAILABILITY ONLY: the unread count is its own, opt-in complication
/// (``UnreadComplicationView``). See ``ComplicationState``.
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

/// The opt-in unread complication, in each accessory family. Compiled like
/// ``ComplicationView``.
///
/// ⛔ A COUNT AND NOTHING ELSE: no sender, no preview, no workspace name. ⛔ AND THE COUNT IS
/// `.privacySensitive()`, so watchOS redacts it on a lowered wrist and a locked watch. The
/// words around it ("Unread", the signed-out sentence) say nothing about anybody.
struct UnreadComplicationView: View {
    let state: ComplicationState
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(Self.inline(for: state))
                .privacySensitive()
        case .accessoryCorner:
            corner
        default:
            circular
        }
    }

    /// The count to draw, or nil when there is none to show (signed out, or unknown).
    static func count(for state: ComplicationState) -> Int? {
        guard state.signedIn else { return nil }
        return state.unreadCount
    }

    /// ⚠️ TWO DIGITS AT MOST: a circular complication has room for no more.
    static func badge(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }

    /// The inline family's line, and the spoken label of the other two.
    static func inline(for state: ComplicationState) -> String {
        guard state.signedIn else { return WatchCopy.signedOut }
        guard let count = state.unreadCount else { return WatchCopy.openIphoneShort }
        return WatchCopy.unreadMessages(count)
    }

    private static let symbol = "envelope.fill"

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let count = Self.count(for: state) {
                VStack(spacing: 0) {
                    Image(systemName: Self.symbol)
                        .font(.caption2)
                        .widgetAccentable()
                    Text(Self.badge(count))
                        .font(.title3.bold())
                        .minimumScaleFactor(0.6)
                        .privacySensitive()
                }
            } else {
                Image(systemName: Self.symbol)
                    .font(.title3)
                    .widgetAccentable()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.inline(for: state))
    }

    private var corner: some View {
        Group {
            if let count = Self.count(for: state) {
                Text(Self.badge(count))
                    .font(.title2.bold())
                    .minimumScaleFactor(0.6)
                    .privacySensitive()
            } else {
                Image(systemName: Self.symbol)
                    .font(.title3)
            }
        }
        .widgetAccentable()
        .widgetLabel(WatchCopy.unread)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.inline(for: state))
    }
}
