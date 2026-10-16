import SwiftUI

/// What a row's own colours turn into when the row is selected.
///
/// ⛔ A SELECTED ROW IN AN iPad SPLIT VIEW LIST IS FILLED WITH THE TINT, WHICH IS THE ACCENT
/// (``DistrictColors/district``), AND THE PALETTE'S INKS ARE NOT MADE FOR IT. The Calls list
/// drew the caller's name in the foreground ink, the date in the muted one and the status chip
/// (green « Terminé » on a 12% green tint) on the accent fill, where none of them could be
/// read (3.0.1 visual QA, iPad fr-CA 07-call-detail, run 38771063483). Plain system text turns
/// light on its own there, because the system styles resolve against
/// ``EnvironmentValues/backgroundProminence``; a fixed `Color` does not. So everything a row
/// tints reads that value and, when it is `.increased`, draws in the accent's own text colour
/// (``DistrictColors/districtForeground``), and a chip keeps its shape as an outline.
///
/// ⛔ THE ACCENT'S TEXT COLOUR, NOT WHITE, which is where this differs from District AI for
/// Mac. The Mac's selection is the system's blue; here it is the tint, and the dark accent is
/// a LIGHT teal on which white measures 1.8:1. ``DistrictColors/districtForeground`` is the
/// pair `tokens.css` publishes for exactly this fill: white on the light accent (6.6:1), the
/// near-black `#0e1c1f` on the dark one (9.6:1). `SelectionInkTests` measures every value here
/// against the accent.
///
/// ⚠️ AN OUTLINE, NOT A TRANSLUCENT FILL. A fill of the ink colour over the accent lifts the
/// ground towards the label and costs the contrast the outline keeps.
enum SelectionInk {
    /// The chip's outline on a selected row: a shape, so held to the 3:1 non-text floor.
    static let chipOutlineAlpha: Double = 0.75

    /// A row's second line on a selected row: still text, so held to AA (5.3:1 light,
    /// 7.0:1 dark).
    static let secondaryAlpha: Double = 0.85

    /// Whether `prominence` is a selected row's, which the palette's colours cannot sit on.
    static func onSelection(_ prominence: BackgroundProminence) -> Bool {
        prominence == .increased
    }

    /// A ``DistrictBadge``'s (and a ``DistrictAvatar``'s) fill.
    static func chipFill(
        _ tone: Tone,
        _ colors: DistrictColors,
        increasedContrast: Bool,
        prominence: BackgroundProminence
    ) -> Color {
        guard onSelection(prominence) else { return tone.fill(colors, increasedContrast: increasedContrast) }
        return Color.clear
    }

    /// The chip's outline: the accent's text colour on a selected row, none elsewhere.
    static func chipOutline(_ colors: DistrictColors, _ prominence: BackgroundProminence) -> Color? {
        onSelection(prominence) ? colors.districtForeground.opacity(chipOutlineAlpha) : nil
    }

    /// A ``DistrictBadge``'s (and a ``DistrictAvatar``'s) ink.
    static func chipInk(
        _ tone: Tone,
        _ colors: DistrictColors,
        increasedContrast: Bool,
        prominence: BackgroundProminence
    ) -> Color {
        onSelection(prominence) ? colors.districtForeground : tone.chipInk(colors, increasedContrast: increasedContrast)
    }

    /// A row's text: `color` off the selection, the accent's text colour on it.
    static func rowInk(
        _ color: Color,
        _ level: RowInkLevel,
        _ colors: DistrictColors,
        prominence: BackgroundProminence
    ) -> Color {
        guard onSelection(prominence) else { return color }
        switch level {
        case .primary: return colors.districtForeground
        case .secondary: return colors.districtForeground.opacity(secondaryAlpha)
        }
    }
}

/// Which of a row's two text inks: the name, or the line under it.
enum RowInkLevel {
    case primary
    case secondary
}

extension View {
    /// Row text in the palette's `color`, or in the accent's text colour on a selected row
    /// (``SelectionInk``).
    func rowInk(_ color: Color, _ level: RowInkLevel) -> some View {
        modifier(RowInkModifier(color: color, level: level))
    }
}

private struct RowInkModifier: ViewModifier {
    let color: Color
    let level: RowInkLevel

    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.foregroundStyle(SelectionInk.rowInk(
            color,
            level,
            DistrictColors.resolve(colorScheme),
            prominence: prominence
        ))
    }
}
