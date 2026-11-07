import DistrictL10n
import SwiftUI

/// The line above every screen while the app shows its saved copy instead of live data:
/// « Hors ligne. Affichage des données enregistrées à 15 h 04 »
///
/// ⛔ IT NAMES WHEN THE COPY WAS SAVED, NOT JUST THAT IT IS OLD. Someone reading a call
/// list offline needs to know which calls could be missing, and the time is that answer.
///
/// ⚠️ IT GOES AWAY ON ITS OWN. ``OfflineStatus/servedLive()`` runs on the next read the
/// service answers, so there is nothing to dismiss and nothing to forget to dismiss.
struct OfflineBanner: View {
    let status: OfflineStatus

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        if let savedAt = status.showingSavedAt {
            HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
                Image(systemName: "wifi.slash")
                    .accessibilityHidden(true)
                Text(Self.text(savedAt: savedAt))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DistrictSpacing.gutter)
            .padding(.vertical, DistrictSpacing.tight)
            .background(colors.muted)
            .overlay(alignment: .bottom) {
                Rectangle().fill(colors.border).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11yID.Offline.banner)
        }
    }

    /// The sentence for a copy saved at `savedAt`: the time alone when it was saved
    /// today, the date and time otherwise.
    static func text(savedAt: Date, now: Date = Date(), zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(savedAt, inSameDayAs: now) {
            let time = L10nFormat.time(savedAt, timezone: zone.identifier)
            return SessionCopy.offlineSavedToday(WireDate.unbroken(time))
        }
        let stamp = L10nFormat.dateTime(savedAt, timezone: zone.identifier)
        return SessionCopy.offlineSavedEarlier(WireDate.unbroken(stamp))
    }
}
