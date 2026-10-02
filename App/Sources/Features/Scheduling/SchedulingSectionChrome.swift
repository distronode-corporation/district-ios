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

/// Turning a scheduling admin refusal into a sentence and a recovery, for every read
/// and every write on the scheduling surface.
///
/// ⛔ ONE MAPPING, AND THE FIVE CODE SENTENCES ARE THE BROWSER'S OWN, copied from its
/// `SCHEDULING_ERROR_SENTENCES` rather than written here. The web client performs this
/// exact collapse, and the two clients have to agree: a person shown two different
/// explanations of one refusal depending on which device or which sheet they picked it
/// up on will report a bug against whichever they saw second. ⚠️ Changing one of the
/// five means changing the web's copy in the same breath.
///
/// ⛔ AND THE MODULE DELIBERATELY CARRIES NO COPY. ``SchedulingAdminFailureCode`` is the
/// DECISION (which of five recoveries applies) and `DistrictCore` is Linux-testable and
/// locale-free, so the sentence is the App's. This enum is the seam.
enum SchedulingFailureCopy {
    static let unavailable = "The booking system did not answer. Try again in a minute."
    static let slotTaken = "That time was just taken. Pick another."
    static let forbidden = "You can view this but not change it."
    static let notReady = "Scheduling is not set up for this workspace yet."
    static let unknown = "That did not save. Try again."

    /// ⚠️ NO WEB ORIGINAL: the browser maps a failed `fetch` to `unavailable`. The app
    /// already says this for an ``ApiError/transport(_:)`` (``FailureText/from(_:)``),
    /// and one cause worded two ways inside one app would be worse than diverging here.
    static let offline = "You appear to be offline. Check your connection and try again."
    /// ⚠️ NO WEB ORIGINAL EITHER: the browser never decodes `body.data`, so it cannot
    /// have this problem. A shape this build cannot parse is not "that did not save"
    /// (the write may well have landed), and the app's `ApiError.decoding` sentence is
    /// the honest one.
    static let staleBuild = "This version of the app could not read that response. Please update."

    /// The sentence and the recovery for one refusal.
    ///
    /// ⛔ `transport`, `decoding` AND `invalidParams` ARE LIFTED OUT AHEAD OF THE
    /// COLLAPSE, and they are the only three arms that are. Everything else answers by
    /// its ``SchedulingAdminError/uiCode``. `invalidParams` keeps the web's sentence and
    /// drops only the offer.
    /// The field names an `invalidParams` carries are never shown: they are zod paths,
    /// identifiers to look up and not prose.
    ///
    /// ⚠️ THERE IS NO `signIn` ARM. A missing credential arrives as
    /// ``SchedulingAdminError/forbidden`` alongside a genuine role refusal (the
    /// repository collapses 401 and 403 together), so this surface cannot tell them apart
    /// and must not offer a sign-in that may be irrelevant. The session's own 401 handling
    /// runs on the shared ``ApiClient`` regardless.
    static func text(for error: SchedulingAdminError) -> FailureText {
        switch error {
        case .transport: FailureText(message: offline, action: .retry)
        case .decoding: FailureText(message: staleBuild, action: .none)
        // ⛔ THE WEB'S SENTENCE AND NO OFFER: a 400 against a body this client composed
        // is refused again when it is re-sent unchanged. The form's own Save is the retry.
        case .invalidParams: FailureText(message: unknown, action: .none)
        default: text(for: error.uiCode)
        }
    }

    /// One code's sentence and offer.
    ///
    /// ⛔ THE OFFER FOLLOWS THE WEB'S SENTENCE. The browser draws no button, so its
    /// retry policy is what its words tell the person to do: `unavailable` and `unknown`
    /// both end "Try again", and a ``FailureText/Action/retry`` beside either is the
    /// same advice made pressable. The other three cannot change on a second attempt:
    /// pressing again cannot change a role (`forbidden`), provision a tenancy
    /// (`notReady`) or un-take a slot (`slotTaken`), so ``FailureView`` draws nothing.
    static func text(for code: SchedulingAdminFailureCode) -> FailureText {
        switch code {
        case .unavailable: FailureText(message: unavailable, action: .retry)
        case .slotTaken: FailureText(message: slotTaken, action: .none)
        case .forbidden: FailureText(message: forbidden, action: .none)
        case .notReady: FailureText(message: notReady, action: .none)
        case .unknown: FailureText(message: unknown, action: .retry)
        }
    }

    /// ⚠️ THE SAME MAPPING FOR A THROWN `Error` OF ANY TYPE, so a screen's `catch` has one
    /// call rather than a cast at every site. `SchedulingAdminRepository.perform` throws
    /// nothing else, but `throws` erases that; a throw nobody has classified lands on the
    /// `unknown` code, never on a specific sentence it has not earned.
    static func text(forAny error: any Error) -> FailureText {
        text(for: (error as? SchedulingAdminError) ?? .unknown)
    }

    /// ⚠️ True for the one refusal a reschedule recovers from by RE-READING the slots
    /// rather than by telling the operator to try again. The web performs the same
    /// re-fetch; keeping the test here means a sheet does not have to pattern-match an
    /// error type it otherwise never touches.
    static func isSlotTaken(_ error: any Error) -> Bool {
        (error as? SchedulingAdminError)?.uiCode == .slotTaken
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
