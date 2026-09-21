import SwiftUI

/// The semantic tones. Mirrors the Android client's `Tone.kt` and the web's
/// `BadgeTone`.
///
/// ⚠️ ``Tone/district`` IS THE ACCENT TONE, NOT A SUCCESS TONE. The web keeps them
/// distinct because a workspace being SELECTED and an operation having SUCCEEDED
/// are different facts that happen to both be positive. Using the accent for
/// success would make "active" and "worked" indistinguishable at a glance, which is
/// the whole thing a tone is for.
enum Tone: String, CaseIterable {
    case neutral
    case district
    case success
    case warning
    case danger
    case info

    /// The 12%-alpha container fill: the web's `bg-district/12` and friends.
    ///
    /// ⚠️ ``Tone/neutral`` is the exception and uses the SOLID `muted` token rather
    /// than a tint. On the web that is `bg-muted`, deliberately: a 12% tint of a
    /// grey on a near-black background is invisible, so the neutral badge would
    /// lose its shape entirely.
    func fill(_ colors: DistrictColors) -> Color {
        switch self {
        case .neutral: colors.muted
        case .district: colors.district.opacity(DistrictColors.containerAlpha)
        case .success: colors.success.opacity(DistrictColors.containerAlpha)
        case .warning: colors.warning.opacity(DistrictColors.containerAlpha)
        case .danger: colors.destructive.opacity(DistrictColors.containerAlpha)
        case .info: colors.info.opacity(DistrictColors.containerAlpha)
        }
    }

    /// The solid ink drawn on ``fill(_:)``.
    func ink(_ colors: DistrictColors) -> Color {
        switch self {
        case .neutral: colors.mutedForeground
        case .district: colors.district
        case .success: colors.success
        case .warning: colors.warning
        case .danger: colors.destructive
        case .info: colors.info
        }
    }

    // MARK: - Increase Contrast

    /// ⛔ THE TINTED BADGE IS THE THINNEST THING IN THIS PALETTE, AND THE ARITHMETIC
    /// SAYS SO. A badge draws ``ink(_:)`` over ``fill(_:)``, and `fill` is the SAME
    /// colour at 12% over the surface behind it — so the two are separated only by
    /// what 12% of one colour does to another. Measured across both palettes and all
    /// five surfaces, nineteen of the thirty combinations land between 3:1 and 4.5:1:
    /// legible, and short of AA for a 12pt label. `DistrictContrastTests` pins the
    /// exact set.
    ///
    /// ⛔ SO WHEN THE SYSTEM ASKS FOR MORE CONTRAST, THE BADGE STOPS BEING A TINT AND
    /// BECOMES A SOLID. The pair it switches to is the fill-and-`on*` pair the filled
    /// controls already use, which the same tests measure at 5.36:1 to 12.58:1 — no
    /// colour is invented here, and nothing changes for a user who has not asked for
    /// it. Raising ``DistrictColors/containerAlpha`` cannot substitute: more tint
    /// moves the background TOWARDS the ink and makes it worse, and the dark
    /// `district` accent is 3.91:1 against `elevated` with no tint at all.
    func fill(_ colors: DistrictColors, increasedContrast: Bool) -> Color {
        guard increasedContrast else { return fill(colors) }
        switch self {
        case .neutral: return colors.muted
        case .district: return colors.district
        case .success: return colors.success
        case .warning: return colors.warning
        case .danger: return colors.destructive
        case .info: return colors.info
        }
    }

    /// ⚠️ ``Tone/neutral`` GOES TO FULL `foreground` RATHER THAN STAYING MUTED. Its
    /// tinted form already clears AA, so this is the one tone the switch is not
    /// rescuing — but a person who has asked for more contrast should not be given
    /// the one badge that deliberately recedes.
    func ink(_ colors: DistrictColors, increasedContrast: Bool) -> Color {
        guard increasedContrast else { return ink(colors) }
        switch self {
        case .neutral: return colors.foreground
        case .district: return colors.districtForeground
        case .success: return colors.onSuccess
        case .warning: return colors.onWarning
        case .danger: return colors.onDestructive
        case .info: return colors.onInfo
        }
    }
}

extension Tone {
    /// Which tone a call's status wears. Ported from Android's `CallTone.kt`.
    ///
    /// ⛔ THIS EXISTS SO STATE IS SCANNABLE WITHOUT READING. As the same grey body
    /// text, a `completed` call and a `failed` one are typographically identical and
    /// the only difference is reading the word. A badge with a tone means the eye
    /// sorts the list before the reader does.
    ///
    /// ⚠️ FAILS TO ``Tone/neutral``, NOT TO A GUESS. The server's status column is a
    /// plain string with no enum behind it, so an unmodelled value is a real
    /// possibility. Painting an unknown status green or red would assert something
    /// about a call this client does not understand; neutral says "this is a status,
    /// and I am not interpreting it".
    ///
    /// ⚠️ LOWERCASED BEFORE MATCHING. Nothing normalises the column on write, and
    /// `subscriptionTier` in the same database is verified mixed-case (`VoicePro`),
    /// so assuming lowercase is exactly the bug that makes a comparison silently
    /// never match.
    static func forCallStatus(_ status: String?) -> Tone {
        let normalised = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if terminalOK.contains(normalised ?? "") {
            return .success
        }
        if terminalBad.contains(normalised ?? "") {
            return .danger
        }
        if inFlight.contains(normalised ?? "") {
            return .district
        }
        return .neutral
    }

    /// Terminal and fine.
    private static let terminalOK: Set<String> = ["completed", "complete", "answered"]

    /// Terminal and not fine. `busy` and `no-answer` are Twilio's spellings;
    /// `failed` and `canceled` are the provider-agnostic ones the route can emit.
    private static let terminalBad: Set<String> = [
        "failed",
        "busy",
        "no-answer",
        "noanswer",
        "canceled",
        "cancelled",
    ]

    /// Still happening. The accent tone rather than a semantic one: in progress is
    /// not a verdict.
    private static let inFlight: Set<String> = [
        "in-progress",
        "in_progress",
        "inprogress",
        "ringing",
        "queued",
        "initiated",
    ]
}

/// A status pill: 12%-alpha fill, solid ink, 6pt radius.
///
/// ⛔ PLAIN GREY BODY TEXT PINNED TO THE FAR RIGHT OF A ROW MAKES a failed transfer
/// and a completed call typographically identical. A tinted
/// pill makes state scannable without reading, which is the entire job of a call
/// log.
///
/// ⛔ A PILL IS AN ATOM: ITS LABEL NEVER WRAPS. A wrapped pill reads as two pills and
/// a mid-word break ("Transferr/ed") reads as corruption, which is what a two-pill
/// call log row renders without this. `lineLimit(1)` plus a horizontal
/// `fixedSize` makes the label report one width and hold it, so an `HStack` that is
/// short of space compresses something else. The other half of that fix is
/// `layoutPriority` on ``DistrictListRow``'s trailing slot; this alone is not enough,
/// because a slot proposed less than its ideal would then clip rather than wrap.
///
/// ⚠️ SAFE ONLY BECAUSE A PILL IS SHORT BY CONSTRUCTION. `fixedSize` on anything that
/// can carry arbitrary text is how a row overflows its own bounds. If a badge ever
/// needs to hold user-supplied copy, truncate it at the call site rather than removing
/// this.
struct DistrictBadge: View {
    let text: String
    var tone: Tone = .neutral

    @Environment(\.colorScheme) private var colorScheme
    /// ⚠️ THE SYSTEM'S "Increase Contrast" SWITCH, read straight from the environment.
    /// See the ⛔ on ``Tone/fill(_:increasedContrast:)``.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var increased: Bool {
        colorSchemeContrast == .increased
    }

    var body: some View {
        Text(text)
            .font(DistrictType.label)
            .foregroundStyle(tone.ink(colors, increasedContrast: increased))
            .lineLimit(1)
            // ⚠️ HORIZONTAL ONLY. `fixedSize()` on both axes would also pin the height
            // against Dynamic Type, which is the one direction a pill must be free to
            // grow in.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, DistrictSpacing.tight)
            .padding(.vertical, 2)
            .background(
                tone.fill(colors, increasedContrast: increased),
                in: RoundedRectangle(cornerRadius: DistrictRadius.badge)
            )
    }
}

/// A 6pt dot, for presence and health.
struct DistrictStatusDot: View {
    var tone: Tone = .neutral

    @Environment(\.colorScheme) private var colorScheme

    /// ⚠️ IT GROWS WITH THE TEXT IT SITS BESIDE. Every caller pairs the dot with a
    /// `caption` or `bodySmall` label in an HStack, and a 6pt speck against type that
    /// has scaled to five times its size does not read as a status marker at all —
    /// it reads as a rendering fault. Anchored to `.caption`, the smaller of the two
    /// companions, so the dot never outgrows the word it marks.
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 6

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        Circle()
            .fill(tone.ink(colors))
            .frame(width: diameter, height: diameter)
    }
}
