import Foundation

/// How a scheduling status reads: the shape of the badge, without the colour.
///
/// ⛔ NO COLOUR AND NO COPY DECISION LIVES HERE, ONLY THE CLASSIFICATION. `DistrictData`
/// is Linux-testable and knows nothing about SwiftUI; `Tone` is an App-target type built
/// on `Color`. So the formatters below answer WHICH KIND of status a row is in and the
/// App maps that to a tone in one place. The same cut ``SchedulingAdminFailureCode``
/// already makes for failures: the module carries the decision, the app carries the
/// sentence.
///
/// ⚠️ THE CASES ARE CLOUDSCAPE'S `StatusIndicator` TYPES, WHICH IS WHY THERE ARE SIX AND
/// NOT FOUR. The web's tables are built on that component and its vocabulary is what the
/// ported functions were written against — `stopped` and `pending` are genuinely
/// different from `error` and `info` there (an archived host is stopped, not failed; a
/// consent nobody answered is pending, not an error). Collapsing them would lose a
/// distinction the copy beside them relies on.
public enum SchedulingStatusKind: String, Equatable, Sendable, CaseIterable {
    case success
    case error
    case info
    case stopped
    case pending
    case inProgress
}

/// A status label and its kind, as one value.
///
/// ⚠️ A NAMED TYPE RATHER THAN A LABELLED TUPLE, for the reason ``SchedulingBadge`` in
/// the App target records: these are returned from switch EXPRESSIONS and a tuple
/// literal asks the type checker to add labels across every branch at once.
public struct SchedulingStatusLabel: Equatable, Sendable {
    public let label: String
    public let kind: SchedulingStatusKind

    public init(label: String, kind: SchedulingStatusKind) {
        self.label = label
        self.kind = kind
    }
}
