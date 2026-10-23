@testable import DistrictAI
import SwiftUI
import UIKit
import XCTest

/// WCAG 2.1 contrast, computed against the colours the app actually ships.
///
/// ⛔ THE COLOURS ARE READ BACK THROUGH `UIColor`, NEVER RE-DECLARED HERE. A table of
/// hex literals copied into a test is a table that drifts: it would keep passing
/// after somebody changed the palette, which is the one failure a contrast gate
/// exists to catch. `UIColor(Color(districtHex: 0x7D84F7))` (3.0.0's accent) was measured returning
/// 125.0/132.0/247.0 — an exact round trip — so reading the token is reading what
/// renders.
///
/// ⛔ AND THE INTERESTING CASE IS A COMPOSITE, NOT A TOKEN PAIR. A `DistrictBadge`
/// draws `tone.ink` over `tone.fill`, and `fill` is that SAME colour at
/// ``DistrictColors/containerAlpha`` (0.12) over whatever surface is behind it. So
/// the effective background is a blend that appears in no token, is never written
/// down, and is where this palette is thinnest. Comparing `ink` against the raw
/// surface — the obvious test — flatters every badge in the app by about half a
/// point of ratio.
final class DistrictContrastTests: XCTestCase {
    // MARK: - The bars

    /// Normal text. Badge labels are `DistrictType.label`, 12pt, which is not "large"
    /// by any reading of WCAG — 18pt, or 14pt bold, is the large-text floor — so this
    /// is the bar that applies to them.
    private static let aa: Double = 4.5
    /// Large text and non-text UI.
    private static let aaLarge: Double = 3.0

    // MARK: - Body text

    /// ⛔ THE ONE THAT WOULD BE UNFORGIVABLE. Body copy on every surface it can land on.
    func testForegroundClearsAAOnEverySurface() {
        for (palette, name) in Self.palettes {
            for (surface, surfaceName) in Self.surfaces(of: palette) {
                let ratio = Self.contrast(palette.foreground, surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.aa,
                    "\(name): foreground on \(surfaceName) is \(Self.round(ratio)):1, below AA"
                )
            }
        }
    }

    /// ⚠️ SECONDARY TEXT IS STILL TEXT. `mutedForeground` carries subtitles, captions
    /// and every list row's second line; "muted" is a visual weight, not a licence to
    /// drop below the bar.
    func testMutedForegroundClearsAAOnEverySurface() {
        for (palette, name) in Self.palettes {
            for (surface, surfaceName) in Self.surfaces(of: palette) {
                let ratio = Self.contrast(palette.mutedForeground, surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.aa,
                    "\(name): mutedForeground on \(surfaceName) is \(Self.round(ratio)):1, below AA"
                )
            }
        }
    }

    // MARK: - Field edges

    /// ⛔ A TEXT FIELD'S EDGE IS A CONTROL BOUNDARY, 3:1 (WCAG 1.4.11) ON EVERY SURFACE IT CAN
    /// SIT ON. It was ``DistrictColors/input``: 1.40:1 on `card` in dark, 1.62:1 in light.
    func testTheFieldEdgeClearsThreeToOneOnEverySurface() {
        for (palette, name) in Self.palettes {
            XCTAssertLessThan(Self.contrast(palette.input, palette.card), Self.aaLarge, "\(name): the old edge")
            for (surface, surfaceName) in Self.surfaces(of: palette) {
                let ratio = Self.contrast(palette.fieldEdge, surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.aaLarge,
                    "\(name): fieldEdge on \(surfaceName) is \(Self.round(ratio)):1, below 3:1"
                )
            }
        }
    }

    /// The figures the `fieldEdge` comment states, on the card.
    func testTheFieldEdgeOnTheCardIsAsDocumented() {
        XCTAssertEqual(Self.round(Self.contrast(DistrictColors.dark.fieldEdge, DistrictColors.dark.card)), "6.07")
        XCTAssertEqual(Self.round(Self.contrast(DistrictColors.light.fieldEdge, DistrictColors.light.card)), "7.41")
    }

    // MARK: - Solid fills

    /// ⛔ THE `on*` PAIRS ARE THE BUTTON LABELS, and the palette's own comments claim
    /// specific numbers for them — "black clears 8.0:1 on the worst of them,
    /// `destructive`" in dark, "6.2:1 on the worst, `success`" in light. Those claims
    /// are measured here rather than trusted.
    func testEveryFilledControlClearsAA() {
        for (palette, name) in Self.palettes {
            for pair in Self.filledPairs(of: palette) {
                let ratio = Self.contrast(pair.ink, pair.fill)
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.aa,
                    "\(name): \(pair.name) is \(Self.round(ratio)):1, below AA"
                )
            }
        }
    }

    /// The two figures the palette's comments assert, pinned so an edit to a fill
    /// cannot leave a confident sentence describing a colour that no longer exists.
    func testThePaletteCommentsAreTellingTheTruth() {
        let darkWorst = Self.contrast(DistrictColors.dark.onDestructive, DistrictColors.dark.destructive)
        XCTAssertEqual(darkWorst, 8.0, accuracy: 0.05, "the dark comment claims 8.0:1 on destructive")

        let lightWorst = Self.contrast(DistrictColors.light.onSuccess, DistrictColors.light.success)
        XCTAssertEqual(lightWorst, 6.2, accuracy: 0.05, "the light comment claims 6.2:1 on success")

        // ⚠️ AND THE REJECTED ALTERNATIVE, which is the half of the claim that
        // justifies the choice: white on the dark `destructive` fill "fails outright".
        let whiteOnDark = Self.contrast(.white, DistrictColors.dark.destructive)
        XCTAssertLessThan(whiteOnDark, Self.aaLarge, "white on dark destructive should fail, as the comment says")
    }

    // MARK: - Tinted containers, which is where this palette is thin

    /// ⛔ EVERY TINTED BADGE CLEARS AA, all fifty pairs, both palettes. A badge's label is
    /// 12pt, so 4.5:1 is its bar. Until 3.0.2 six pairs sat between 3.91:1 and 4.44:1,
    /// pinned here as a known gap, because the label was drawn in the tone itself; the
    /// chip inks (``Tone/chipInk(_:)``) closed it, and this test is what keeps it closed.
    func testEveryTintedBadgeClearsAA() {
        for (palette, name) in Self.palettes {
            for case let (ratio, label) in Self.badgeMatrix(of: palette, named: name) {
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.aa,
                    "\(label) is \(Self.round(ratio)):1, below AA"
                )
            }
        }
    }

    /// ⛔ THE CHIP INKS ARE DERIVED, NOT CHOSEN: each is its tone moved
    /// ``DistrictColors/chipInkMix`` of the way towards `foreground`. They are written as hex
    /// literals like every other token, so this is what stops a palette edit from moving a
    /// tone and leaving its chip ink behind. Half a step of 8-bit rounding is allowed.
    func testEveryChipInkIsItsToneMovedTowardsForeground() {
        for (palette, name) in Self.palettes {
            for tone in Self.tones where tone != .neutral {
                let expected = Self.blend(
                    palette.foreground, over: tone.ink(palette), alpha: DistrictColors.chipInkMix
                )
                let want = Self.components(expected)
                let got = Self.components(tone.chipInk(palette))
                for (wanted, actual) in [(want.red, got.red), (want.green, got.green), (want.blue, got.blue)] {
                    XCTAssertEqual(actual, wanted, accuracy: 0.6 / 255, "\(name) \(tone) chip ink drifted")
                }
            }
        }
    }

    /// ⚠️ THE DESTRUCTIVE BUTTON IS A TINTED CONTAINER TOO: `destructive` at 10% under its
    /// label, which `DistrictButtonStyle` draws in the destructive chip ink (3.0.2). Its
    /// label is 14pt semibold, short of large text, so the bar is AA.
    func testTheDestructiveButtonsLabelClearsAA() {
        for (palette, name) in Self.palettes {
            for (surface, surfaceName) in Self.surfaces(of: palette) {
                let fill = Self.blend(palette.destructive, over: surface, alpha: 0.10)
                let ratio = Self.contrast(palette.destructiveChipInk, fill)
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.aa,
                    "\(name): the destructive button's label on \(surfaceName) is \(Self.round(ratio)):1"
                )
            }
        }
    }

    // MARK: - Increase Contrast

    /// ⛔ THE POINT OF THE WHOLE VARIANT, AND THE ONE ASSERTION THAT MAKES IT WORTH
    /// SHIPPING. With the system's Increase Contrast on, every badge, all thirty
    /// combinations, both palettes, is a solid fill with its `on*` ink and clears AA by a
    /// wide margin, for anyone who has asked for more contrast.
    ///
    /// ⚠️ AND THE SURFACE BEHIND IT NO LONGER MATTERS, because the fill is solid. That
    /// is why this loops the tones rather than the tone-by-surface matrix: a solid fill
    /// composites with nothing.
    func testEveryBadgeClearsAAUnderIncreasedContrast() {
        for (palette, name) in Self.palettes {
            for tone in Self.tones {
                let fill = tone.fill(palette, increasedContrast: true)
                let ink = tone.ink(palette, increasedContrast: true)
                let ratio = Self.contrast(ink, fill)
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.aa,
                    "\(name): \(tone) badge under Increase Contrast is \(Self.round(ratio)):1, below AA"
                )
            }
        }
    }

    /// ⚠️ AND IT CHANGES NOTHING FOR ANYONE WHO HAS NOT ASKED. A variant that quietly
    /// altered the default appearance would be a design change wearing an
    /// accessibility label.
    func testTheDefaultAppearanceIsUntouched() {
        for (palette, _) in Self.palettes {
            for tone in Self.tones {
                XCTAssertEqual(
                    Self.components(tone.fill(palette, increasedContrast: false)),
                    Self.components(tone.fill(palette)),
                    "\(tone)'s normal-contrast fill moved"
                )
                XCTAssertEqual(
                    Self.components(tone.ink(palette, increasedContrast: false)),
                    Self.components(tone.ink(palette)),
                    "\(tone)'s normal-contrast ink moved"
                )
            }
        }
    }

    // MARK: - Disabled controls

    /// ⚠️ WCAG 1.4.3 EXEMPTS INACTIVE COMPONENTS, so this is a measurement rather than
    /// a bar. `DistrictButton` applies the web's `disabled:opacity-50` to the WHOLE
    /// control, which halves the label AND its fill towards the surface behind: a
    /// disabled primary button's label sits near 2.5:1 against its own fill.
    ///
    /// ⛔ PINNED ANYWAY, BECAUSE ONE SCREEN DEPENDS ON READING IT. The dialer disables
    /// Call and puts the reason in a separate line — see the ⛔ on
    /// `DialerView.problem` — so a person has to be able to read the word "Call" to
    /// connect it to the sentence underneath. Dropping the opacity to 0.3 for a tidier
    /// look would break that, and nothing else in this suite would notice.
    func testTheDisabledPrimaryButtonStaysAboveTwoToOne() {
        for (palette, name) in Self.palettes {
            let fill = Self.blend(palette.district, over: palette.background, alpha: 0.5)
            let ink = Self.blend(palette.districtForeground, over: palette.background, alpha: 0.5)
            let ratio = Self.contrast(ink, fill)
            XCTAssertGreaterThan(
                ratio, 2.0,
                "\(name): a disabled primary button's label is \(Self.round(ratio)):1 against its own fill"
            )
        }
    }

    // MARK: - The palette under the microscope

    private static let tones: [Tone] = [.neutral, .district, .success, .warning, .danger, .info]

    private static let palettes: [(DistrictColors, String)] = [
        (.dark, "dark"),
        (.light, "light"),
    ]

    private static func surfaces(of palette: DistrictColors) -> [(Color, String)] {
        [
            (palette.background, "background"),
            (palette.surface, "surface"),
            (palette.card, "card"),
            (palette.muted, "muted"),
            (palette.elevated, "elevated"),
        ]
    }

    /// ⚠️ A NAMED TYPE RATHER THAN A THREE-TUPLE. `large_tuple` refuses the tuple, and
    /// it is right to: `(fill, ink, name)` and `(ink, fill, name)` are the same type,
    /// so a transposition at the destructuring site would compile and silently measure
    /// the pair backwards — which, contrast being symmetric, would still PASS.
    private struct FilledPair {
        let fill: Color
        let ink: Color
        let name: String
    }

    private static func filledPairs(of palette: DistrictColors) -> [FilledPair] {
        [
            FilledPair(
                fill: palette.district,
                ink: palette.districtForeground,
                name: "districtForeground on district"
            ),
            FilledPair(fill: palette.success, ink: palette.onSuccess, name: "onSuccess on success"),
            FilledPair(fill: palette.warning, ink: palette.onWarning, name: "onWarning on warning"),
            FilledPair(
                fill: palette.destructive,
                ink: palette.onDestructive,
                name: "onDestructive on destructive"
            ),
            FilledPair(fill: palette.info, ink: palette.onInfo, name: "onInfo on info"),
        ]
    }

    /// Every tinted tone against every surface it could sit on, as the blend actually
    /// renders: the tone at ``DistrictColors/containerAlpha`` over the surface, with the
    /// tone's chip ink on it. ⚠️ `.neutral` is excluded because it is not a blend at all, it
    /// is `mutedForeground` on the solid `muted` token, already covered above.
    private static func badgeMatrix(of palette: DistrictColors, named name: String) -> [(Double, String)] {
        tones.filter { $0 != .neutral }.flatMap { tone in
            surfaces(of: palette).map { surface, surfaceName in
                let background = blend(tone.ink(palette), over: surface, alpha: DistrictColors.containerAlpha)
                return (contrast(tone.chipInk(palette), background), "\(name) \(tone) badge on \(surfaceName)")
            }
        }
    }

    // MARK: - The arithmetic

    /// ⛔ THE WCAG 2.1 RELATIVE LUMINANCE FORMULA, NOT A PERCEPTUAL ONE. The 0.03928
    /// knee and the 2.4 exponent are the specification's; substituting a "better"
    /// colour space would produce numbers that are not the ones an accessibility
    /// audit computes.
    private static func luminance(_ color: Color) -> Double {
        let rgb = components(color)
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
    }

    private static func contrast(_ one: Color, _ other: Color) -> Double {
        let first = luminance(one)
        let second = luminance(other)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// ⚠️ BLENDED IN LINEAR-FREE sRGB SPACE, which is what a compositor does with
    /// `.opacity(_:)`: the channels are mixed as stored, and the gamma curve is applied
    /// afterwards by ``luminance(_:)``. Mixing after linearising would give a
    /// different — and wrong — answer for what is on the glass.
    private static func blend(_ foreground: Color, over background: Color, alpha: Double) -> Color {
        let front = components(foreground)
        let back = components(background)
        return Color(
            .sRGB,
            red: front.red * alpha + back.red * (1 - alpha),
            green: front.green * alpha + back.green * (1 - alpha),
            blue: front.blue * alpha + back.blue * (1 - alpha),
            opacity: 1
        )
    }

    private struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    private static func components(_ color: Color) -> RGB {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(red: Double(red), green: Double(green), blue: Double(blue))
    }

    private static func round(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
