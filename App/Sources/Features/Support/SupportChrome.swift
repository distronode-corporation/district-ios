import DistrictModel
import SwiftUI

/// The pieces both Support screens draw.
///
/// ⚠️ ITS OWN FILE FOR THE `file_length` REASON `SettingsChrome` HAS ONE:
/// `swiftlint --strict` reports the 500-line warning as an error, and a list screen
/// with a compose form plus a thread screen with two writes do not fit beside their
/// layout.
enum SupportChrome {}

/// The notice a write leaves behind.
///
/// ⛔ ONE COMPONENT FOR SUCCESSES AND FAILURES, BECAUSE ON THIS SURFACE THEY ARE NOT
/// OPPOSITES. Raising a request has three successful outcomes and only one of them is
/// the ordinary "it worked": `deduplicated` and `pending` are true statements about a
/// request that exists and must not be drawn in the destructive colour, which is what
/// a separate "error strip" would have invited.
///
/// ⛔ DISMISS IS WITHHELD WHEN THE WRITE MAY HAVE LANDED. In that state the notice is
/// the only record that a reply or a close may already be in the customer's thread,
/// and ``SupportCopy/writeUnrepeatable`` under it is what tells them how to check.
struct SupportWriteNotice: View {
    let state: SupportWriteState
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        if let notice = state.notice {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                HStack(alignment: .top, spacing: DistrictSpacing.tight) {
                    Text(notice)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(state.isFailure ? colors.destructive : colors.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let onDismiss, !state.refusedRepeat {
                        Button(SupportCopy.dismiss, action: onDismiss)
                            .buttonStyle(.districtGhost)
                    }
                }
                if state.refusedRepeat {
                    Text(SupportCopy.writeUnrepeatable)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The provenance chips a request carries, in the list and on its thread.
///
/// ⚠️ BOTH ARE CONDITIONAL AND THE CONDITIONS ARE NOT SYMMETRIC. "From a phone call"
/// appears only for `voice-call`, because a request raised here or on the public form
/// is exactly what the reader expects and a chip saying so is noise. The region chip
/// appears only when the region is NOT the default, for the same reason: it answers
/// "why does this one look different", which only a non-default region raises.
struct SupportChips: View {
    let source: String
    let region: String

    var body: some View {
        if source == "voice-call" {
            DistrictBadge(text: SupportCopy.fromPhoneCall, tone: .info)
        }
        if region != SupportCopy.defaultRegion {
            DistrictBadge(text: RegionCopy.label(region), tone: .neutral)
        }
    }
}

extension SupportChrome {
    /// Which tone a request's status bucket wears.
    ///
    /// ⛔ SWITCHED ON THE CATEGORY, NEVER ON ``SupportRequestSummary/statusName``.
    /// The live desk workflow is localised — a real request's transitions can include
    /// `完成` and `等待客户` — so any implementation matching English words
    /// finds nothing and paints every request neutral. The category is Atlassian's own
    /// language-independent bucket.
    ///
    /// ⚠️ FAILS TO ``Tone/neutral`` RATHER THAN TO A GUESS, like
    /// ``Tone/forCallStatus(_:)``. Painting an unmodelled bucket green or red would
    /// assert something about a request this build does not understand.
    static func tone(for statusCategory: String) -> Tone {
        if SupportStatusCategory.isResolved(statusCategory) {
            return .success
        }
        switch statusCategory.uppercased() {
        case "NEW": return .info
        case "INDETERMINATE": return .district
        // ⚠️ The synthetic bucket an unfiled request carries. Not a verdict, so the
        // accent tone rather than a semantic one.
        case "PENDING": return .warning
        default: return .neutral
        }
    }
}
