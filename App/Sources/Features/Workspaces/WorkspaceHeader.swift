import SwiftUI

/// The workspace band at the top of the Overview tab: which tenant these numbers
/// belong to, where its rows live, and the way to a different one.
///
/// ⛔ THE NAME AND THE NUMBERS MUST BE THE SAME WORKSPACE. This header is drawn
/// directly above four metric tiles, so a name from the workspace list sitting over
/// figures the server produced for a different tenant is a silent, confident lie.
/// ``OverviewModel`` refuses a response whose echoed `workspaceId` is not the one
/// asked for precisely because this view exists.
///
/// ⚠️ SCALARS, NOT THE SESSION MODEL. The read-only flag comes from the OVERVIEW's
/// effective role and the switcher's availability from the workspace LIST, which
/// are two different sources; taking them as arguments is what stops this view
/// picking the wrong one of the two.
struct WorkspaceHeader: View {
    let name: String
    /// Data residency, which is a product promise here rather than a detail.
    let region: String
    /// ⛔ TRUE FOR AN UNPARSED ROLE AS WELL AS FOR `viewer`, because
    /// ``WorkspaceRole/fromWire(_:)`` fails closed: nil means "the role could not
    /// be established", never "assume client". See ``WorkspaceRole/allowsMutation(_:)``.
    let isReadOnly: Bool
    let canSwitch: Bool
    let onSwitch: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    @ScaledMetric(relativeTo: .title2) private var headingTracking: CGFloat = DistrictType.headingTracking

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: "Workspace")
            Text(name)
                .font(DistrictType.headline)
                // ⚠️ SCALED, for the same reason as the eyebrow's: tracking is
                // points, so a fixed -0.6 against glyphs twice the size reads as a
                // heading whose letters have been squeezed together. Anchored to
                // `.title2`, which is what `DistrictType.headline` uses.
                .tracking(headingTracking)
                .foregroundStyle(colors.foreground)
                // ⚠️ ON THE NAME ALONE, SO ITS LABEL IS THE WORKSPACE'S NAME. Tagging the
                // band instead would mean combining it into one element, which folds the
                // "Switch workspace" button into it and takes it away from VoiceOver.
                .accessibilityIdentifier(A11yID.Workspace.header)
            HStack(spacing: DistrictSpacing.tight) {
                DistrictBadge(text: region.uppercased(), tone: .district)
                if isReadOnly {
                    // ⚠️ STATED UP FRONT rather than discovered by tapping
                    // something that 403s. The server excludes viewers from every
                    // mutating route.
                    DistrictBadge(text: "Read-only access", tone: .neutral)
                }
                Spacer(minLength: 0)
                if canSwitch {
                    Button("Switch workspace", action: onSwitch)
                        .buttonStyle(.districtGhost)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sentence that goes wherever a PARTIAL workspace list is shown.
///
/// ⛔ A CAPTION, NOT AN ERROR, AND IT LIVES IN ONE PLACE ON PURPOSE. The rows on
/// screen are real; they are simply not all of them. Presenting this as a failure
/// would be as wrong as presenting it as a complete account — and two copies of the
/// sentence would drift, with the copy that drifted being the one on the rarer
/// path. ``ShellView``'s placeholder tabs, the Overview tab and the workspace
/// picker all render THIS view.
struct PartialWorkspacesCaption: View {
    let regions: [String]

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        Text("Some workspaces are missing: we could not reach \(named).")
            .font(DistrictType.caption)
            .foregroundStyle(Tone.warning.ink(colors))
            .multilineTextAlignment(.center)
    }

    /// ⚠️ NAMES THE REGIONS WHEN THE SERVER NAMED THEM. "One or more regions" is
    /// true and useless.
    private var named: String {
        regions.map { $0.uppercased() }.joined(separator: ", ")
    }
}
