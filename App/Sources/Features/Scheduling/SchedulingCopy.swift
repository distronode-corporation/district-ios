import DistrictModel
import Foundation

/// The status pill's label and tone.
///
/// ⚠️ A NAMED TYPE RATHER THAN A LABELLED TUPLE, which is a compile-risk decision
/// rather than a style one. ``SchedulingPresentation/badge`` is a switch EXPRESSION
/// with a `nil` branch (the shape ``OverviewEntry/caption`` already proves builds),
/// and an unlabelled tuple literal in the other branches would ask the type checker
/// to add tuple labels AND inject into an Optional across branches at the same time
/// — an error that surfaces only in the full SwiftUI build.
struct SchedulingBadge {
    let label: String
    let tone: Tone
}

/// Every sentence this screen can say.
///
/// ⚠️ HOISTED TO `String` CONSTANTS RATHER THAN WRITTEN INLINE, for the reason
/// `DevicesView` records: a `+` concatenation handed straight to an API with both
/// a `LocalizedStringKey` and a `StringProtocol` overload is an inference question
/// at the call site, and the error surfaces only in the full SwiftUI build. A
/// named `String` picks the second unambiguously.
///
/// ⚠️ ONE PLACE, SHARED WITH ``SchedulingModel``. The enable route's 403 means the
/// workspace is not on the allowlist, which is the same fact ``notEligible``
/// states, and two copies of that sentence is two copies that drift.
enum SchedulingCopy {
    static func setupFailed(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else {
            return setupFailedNoReason
        }
        return setupFailedBecause(reason)
    }

    static func lastReadyLine(_ stamp: String) -> String {
        lastChecked(WireDate.display(stamp))
    }
}

extension SchedulingPresentation {
    var sentence: String {
        switch self {
        case .notEligible: SchedulingCopy.notEligible
        case .legacy: SchedulingCopy.legacy
        case .provisioning: SchedulingCopy.provisioning
        case .live: SchedulingCopy.live
        // ⚠️ The reason itself is drawn by ``SchedulingView/detail(_:)`` so it can
        // carry the danger tone on its own line.
        case .failedProvision: SchedulingCopy.failedProvision
        case .switchedOff: SchedulingCopy.switchedOff
        }
    }

    /// ⚠️ ONLY THE ONE STATE WHERE SOMETHING WENT WRONG. "not admitted" and
    /// "switched off" are ordinary answers and painting them red would report a
    /// fault that did not happen.
    var isFailure: Bool {
        if case .failedProvision = self {
            return true
        }
        return false
    }

    /// ⚠️ A BADGE ONLY WHERE THERE IS A TENANCY ROW, matching the web card: the
    /// pill reports the ROW's status, and there is nothing to report without one.
    var badge: SchedulingBadge? {
        switch self {
        case .notEligible, .legacy: nil
        case .provisioning: SchedulingBadge(label: SchedulingCopy.settingUp, tone: .info)
        case .live: SchedulingBadge(label: SchedulingCopy.live2, tone: .success)
        case .failedProvision: SchedulingBadge(label: SchedulingCopy.needsAttention, tone: .danger)
        case .switchedOff: SchedulingBadge(label: SchedulingCopy.switchedOff2, tone: .neutral)
        }
    }
}

extension SchedulingCopy {
    /// One row's title. ⚠️ The web's own section names, so an operator who has used the
    /// dashboard finds the same word here.
    static func sectionTitle(_ section: SchedulingSection) -> String {
        switch section {
        case .hub: sectionTitleHub
        case .overview: sectionTitleOverview
        case .eventTypes: sectionTitleEventTypes
        case .eventType: sectionTitleEventType
        case .hours: sectionTitleHours
        case .bookings: sectionTitleBookings
        case .booking: sectionTitleBooking
        case .calendar: sectionTitleCalendar
        case .team: sectionTitleTeam
        case .settings: sectionTitleSettings
        case .developer: sectionTitleDeveloper
        }
    }

    /// One row's second line.
    ///
    /// ⛔ EACH ONE SAYS WHAT THE SECTION HOLDS RATHER THAN RESTATING ITS TITLE. A subtitle
    /// that paraphrases the row above it is a line of text that costs a thumb-scroll and
    /// tells nobody anything; these are compressed from the web pages' own subtitles, which
    /// were written for the same job.
    static func sectionSubtitle(_ section: SchedulingSection) -> String? {
        switch section {
        case .hub, .eventType, .booking: nil
        case .overview: sectionSubtitleOverview
        case .eventTypes: sectionSubtitleEventTypes
        case .hours: sectionSubtitleHours
        case .bookings: sectionSubtitleBookings
        case .calendar: sectionSubtitleCalendar
        case .team: sectionSubtitleTeam
        case .settings: sectionSubtitleSettings
        case .developer: sectionSubtitleDeveloper
        }
    }
}
