@testable import DistrictAI
import SwiftUI
import UIKit
import XCTest

/// What a row's chips and text draw on a selected row (``SelectionInk``): the 3.0.1 visual QA
/// found the Calls list's name, date and status chip unreadable on the iPad's accent-filled
/// selection.
final class SelectionInkTests: XCTestCase {
    private static let palettes: [(DistrictColors, String)] = [(.light, "light"), (.dark, "dark")]

    /// ⛔ ON A SELECTED ROW EVERY TONE'S CHIP IS THE ACCENT'S TEXT COLOUR IN AN OUTLINE OF IT,
    /// ON NO FILL, in either contrast setting, whatever the tone said off the selection.
    func test_SELECTION_1_aSelectedRowsChipIsTheAccentsTextColour() {
        for (colors, name) in Self.palettes {
            for tone in Tone.allCases {
                for increased in [false, true] {
                    XCTAssertEqual(
                        SelectionInk.chipInk(tone, colors, increasedContrast: increased, prominence: .increased),
                        colors.districtForeground,
                        "\(name) \(tone) \(increased)"
                    )
                    XCTAssertEqual(
                        SelectionInk.chipFill(tone, colors, increasedContrast: increased, prominence: .increased),
                        .clear,
                        "\(name) \(tone) \(increased)"
                    )
                }
            }
            XCTAssertEqual(
                SelectionInk.chipOutline(colors, .increased),
                colors.districtForeground.opacity(SelectionInk.chipOutlineAlpha)
            )
        }
    }

    /// ⚠️ OFF THE SELECTION THE CHIP IS THE TONE'S OWN, Increase Contrast included, with no
    /// outline, and row text keeps the palette's colour.
    func test_SELECTION_2_anUnselectedRowKeepsItsColours() {
        for (colors, name) in Self.palettes {
            for tone in Tone.allCases {
                for increased in [false, true] {
                    XCTAssertEqual(
                        SelectionInk.chipInk(tone, colors, increasedContrast: increased, prominence: .standard),
                        tone.chipInk(colors, increasedContrast: increased),
                        "\(name) \(tone) \(increased)"
                    )
                    XCTAssertEqual(
                        SelectionInk.chipFill(tone, colors, increasedContrast: increased, prominence: .standard),
                        tone.fill(colors, increasedContrast: increased),
                        "\(name) \(tone) \(increased)"
                    )
                }
            }
            XCTAssertNil(SelectionInk.chipOutline(colors, .standard))
            XCTAssertEqual(
                SelectionInk.rowInk(colors.mutedForeground, .secondary, colors, prominence: .standard),
                colors.mutedForeground
            )
        }
    }

    /// ⚠️ ONLY `.increased` IS A SELECTION THE PALETTE CANNOT SIT ON.
    func test_SELECTION_3_onlyAnIncreasedBackgroundIsASelection() {
        XCTAssertTrue(SelectionInk.onSelection(.increased))
        XCTAssertFalse(SelectionInk.onSelection(.standard))
    }

    /// ⛔ ON THE ACCENT, IN BOTH THEMES: the name and the chip's label clear AA, the second line
    /// clears AA at its alpha, and the outline clears the 3:1 floor for a shape. The colours
    /// are read back through `UIColor`, not declared here.
    func test_SELECTION_4_everyInkClearsItsBarOnTheAccent() {
        for (colors, name) in Self.palettes {
            let accent = colors.district
            let primary = SelectionInk.rowInk(colors.foreground, .primary, colors, prominence: .increased)
            let secondary = SelectionInk.rowInk(colors.mutedForeground, .secondary, colors, prominence: .increased)
            XCTAssertGreaterThanOrEqual(Self.contrast(primary, over: accent), 4.5, "\(name) name")
            XCTAssertGreaterThanOrEqual(Self.contrast(secondary, over: accent), 4.5, "\(name) second line")
            let outline = SelectionInk.chipOutline(colors, .increased) ?? .clear
            XCTAssertGreaterThanOrEqual(Self.contrast(outline, over: accent), 3.0, "\(name) chip outline")
        }
    }

    /// ⚠️ AND THE REASON IT IS NOT WHITE, as on the Mac: white on the dark accent fails.
    func test_SELECTION_5_whiteWouldFailOnTheDarkAccent() {
        XCTAssertLessThan(Self.contrast(.white, over: DistrictColors.dark.district), 3.0)
    }

    // MARK: - The arithmetic (WCAG 2.1), with `ink`'s alpha composited over `background`

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        init(_ color: Color) {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            self.red = Double(red)
            self.green = Double(green)
            self.blue = Double(blue)
            self.alpha = Double(alpha)
        }

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            alpha = 1
        }

        var luminance: Double {
            func channel(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }
    }

    private static func contrast(_ ink: Color, over background: Color) -> Double {
        let front = RGBA(ink)
        let back = RGBA(background)
        let mixed = RGBA(
            red: front.red * front.alpha + back.red * (1 - front.alpha),
            green: front.green * front.alpha + back.green * (1 - front.alpha),
            blue: front.blue * front.alpha + back.blue * (1 - front.alpha)
        )
        let first = mixed.luminance
        let second = back.luminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
