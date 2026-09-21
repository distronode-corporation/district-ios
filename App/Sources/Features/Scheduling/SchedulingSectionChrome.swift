import DistrictData
import SwiftUI

/// What one scheduling section's read is doing.
///
/// ⛔ A FAILED READ IS ITS OWN CASE AND IS NEVER RENDERED AS "there is nothing here",
/// which is the same rule ``SchedulingScreenState`` states for the hub and matters more
/// on these nine screens: an empty list is an ORDINARY answer on every one of them (a
/// tenancy with no bookings, no recordings, no webhooks), so a read that did not happen
/// and a workspace that has nothing would otherwise be the same picture.
enum SchedulingSectionState<Value> {
    case loading
    case ready(Value)
    case failed(FailureText)
}

extension SchedulingSectionState {
    /// ⚠️ THE VALUE IF THERE IS ONE, for a screen that wants to keep drawing a stale list
    /// under a refresh. Nothing uses it: the pull-to-refresh handlers all
    /// re-enter `.loading` because these reads are fast and unpaged.
    var value: Value? {
        guard case let .ready(value) = self else { return nil }
        return value
    }
}

/// Turning a scheduling admin refusal into a sentence and a recovery.
///
/// ⛔ FIVE CODES, FIVE SENTENCES, AND THEY ARE THE BROWSER'S OWN. The web client
/// performs this exact collapse, and the two clients have to agree: a person
/// shown two different explanations of one refusal depending on which device they picked
/// it up on will report a bug against whichever they saw second. The strings below are
/// copied from the web client rather than written here.
///
/// ⛔ AND THE MODULE DELIBERATELY CARRIES NO COPY. ``SchedulingAdminFailureCode`` is the
/// DECISION — which of five recoveries applies — and `DistrictCore` is Linux-testable and
/// locale-free, so the sentence is the App's. This enum is the seam.
enum SchedulingFailureCopy {
    static let unavailable = "The booking system did not answer. Try again in a minute."
    static let slotTaken = "That time was just taken. Pick another."
    static let forbidden = "You can view this but not change it."
    static let notReady = "Scheduling is not set up for this workspace yet."
    static let unknown = "That did not save. Try again."

    /// The sentence and the recovery for one refusal.
    ///
    /// ⛔ ONLY `unavailable` OFFERS A RETRY. Pressing again cannot change a role
    /// (`forbidden`), cannot provision a tenancy (`notReady`), cannot un-take a slot
    /// (`slotTaken`) and cannot fix a shape this client does not understand (`unknown`) —
    /// so a "Try again" on any of the other four is a button that produces the identical
    /// refusal for as long as somebody keeps pressing it. ``FailureView`` draws no action
    /// at all for `.none`, which is the honest answer.
    ///
    /// ⚠️ THERE IS NO `signIn` ARM. A missing credential arrives as
    /// ``SchedulingAdminError/forbidden`` alongside a genuine role refusal — the
    /// repository collapses 401 and 403 together — so this surface cannot tell them apart
    /// and must not offer a sign-in that may be irrelevant. The session's own 401 handling
    /// runs on the shared ``ApiClient`` regardless.
    static func text(for error: SchedulingAdminError) -> FailureText {
        switch error.uiCode {
        case .unavailable: FailureText(message: unavailable, action: .retry)
        case .slotTaken: FailureText(message: slotTaken, action: .none)
        case .forbidden: FailureText(message: forbidden, action: .none)
        case .notReady: FailureText(message: notReady, action: .none)
        case .unknown: FailureText(message: unknown, action: .none)
        }
    }

    /// ⚠️ THE SAME MAPPING FOR A THROWN `Error` OF ANY TYPE, so a screen's `catch` has one
    /// call rather than a cast at every site. Anything that is not a
    /// ``SchedulingAdminError`` is genuinely unknown to this surface and says so.
    static func text(forAny error: any Error) -> FailureText {
        guard let admin = error as? SchedulingAdminError else {
            return FailureText(message: unknown, action: .none)
        }
        return text(for: admin)
    }
}

extension SchedulingStatusKind {
    /// The design system's tone for a status the module classified.
    ///
    /// ⛔ THE MAPPING LIVES HERE AND NOT IN `DistrictData`, WHICH IS THE WHOLE REASON
    /// ``SchedulingStatusKind`` EXISTS. `Tone` is built on `Color` and cannot leave the
    /// app target; the module answers WHICH KIND of status a row is in and this is the one
    /// place that turns six kinds into five tones.
    ///
    /// ⚠️ `pending` AND `inProgress` BOTH LAND ON `.info`, WHICH IS A REAL COLLAPSE AND
    /// NOT AN OVERSIGHT. This design system has no distinct "in progress" tone, and the
    /// two are told apart by their LABELS ("Recording" against "Unknown"), which is where
    /// the difference is legible anyway. ⛔ Neither may be mapped to `.warning`: a consent
    /// nobody answered and a recording still running are both ordinary states, and
    /// painting them as warnings would report a fault that did not happen — the same
    /// argument ``SchedulingPresentation/isFailure`` makes for the hub's card.
    var tone: Tone {
        switch self {
        case .success: .success
        case .error: .danger
        case .info: .info
        case .stopped: .neutral
        case .pending, .inProgress: .info
        }
    }
}

extension SchedulingStatusLabel {
    /// ⚠️ A CONVENIENCE SO A ROW READS `badge(label)` RATHER THAN REBUILDING THE PAIR. The
    /// label and the tone always travel together; splitting them at a call site is how one
    /// of the two comes to be computed from a different value.
    var badge: SchedulingBadge {
        SchedulingBadge(label: label, tone: kind.tone)
    }
}

/// A titled panel for one section's content, on the scheduling surface's own spacing.
///
/// ⚠️ IT WRAPS ``SettingsCard`` RATHER THAN RESTATING IT. Both draw an eyebrow over a
/// card and there is no reason for two; the alias exists so that a scheduling screen does
/// not read as if it were part of the workspace-settings feature, and so that if the two
/// surfaces ever diverge visually there is one place to change.
typealias SchedulingCard = SettingsCard

/// A `label: value` line, for the many read-only fields on these nine screens.
typealias SchedulingReadOnlyRow = SettingsReadOnlyRow

/// The standard scroll container every scheduling section sits in.
///
/// ⛔ ONE CONTAINER FOR ALL NINE, so that the gutter, the section spacing and the
/// pull-to-refresh behave identically. Nine screens each writing their own `ScrollView`
/// is nine chances for one of them to forget `refreshable`, and a section that cannot be
/// re-read is indistinguishable from one whose data never changes.
struct SchedulingSectionScroll<Content: View>: View {
    let title: String
    let identifier: String
    let onRefresh: () async -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .districtRefreshable { await onRefresh() }
        .accessibilityIdentifier(identifier)
    }
}

/// The empty state every scheduling list shares the shape of.
///
/// ⚠️ THE GLYPH IS THE SAME ON ALL NINE AND THE WORDS ARE NOT. An empty bookings table and
/// an empty webhooks table mean completely different things and the web words each one
/// separately; only the furniture is shared.
struct SchedulingEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        EmptyStateView(systemImage: "calendar", title: title, message: message)
    }
}
