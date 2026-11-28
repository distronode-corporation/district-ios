@testable import DistrictAI
import SwiftUI
import XCTest

/// The tone a call's status is drawn in, from every spelling the carriers and the service use and
/// from input that is none of them; and what each tone becomes under Increase Contrast.
final class ToneMappingTests: XCTestCase {
    func testEveryKnownStatusHasItsTone() {
        for status in ["completed", "complete", "answered"] {
            XCTAssertEqual(Tone.forCallStatus(status), .success, status)
        }
        for status in ["failed", "busy", "no-answer", "noanswer", "canceled", "cancelled"] {
            XCTAssertEqual(Tone.forCallStatus(status), .danger, status)
        }
        for status in ["in-progress", "in_progress", "inprogress", "ringing", "queued", "initiated"] {
            XCTAssertEqual(Tone.forCallStatus(status), .district, status)
        }
    }

    /// Trimmed and case-blind, as the carriers' webhooks spell them.
    func testAStatusIsReadTrimmedAndCaseBlind() {
        XCTAssertEqual(Tone.forCallStatus("  Completed\n"), .success)
        XCTAssertEqual(Tone.forCallStatus("NO-ANSWER"), .danger)
        XCTAssertEqual(Tone.forCallStatus("\tRinging "), .district)
    }

    /// ⚠️ ANYTHING ELSE IS NEUTRAL, never a guess at success or failure.
    func testAnUnknownStatusIsNeutral() {
        for status in [nil, "", "   ", "voicemail", "completed!", "in progress", "succeeded"] {
            XCTAssertEqual(Tone.forCallStatus(status), .neutral, status ?? "nil")
        }
    }

    /// Increase Contrast fills with the solid colour and draws the ink that sits on it.
    func testIncreasedContrastIsTheSolidPair() {
        for colors in [DistrictColors.light, DistrictColors.dark] {
            let solid: [Tone: (fill: Color, ink: Color)] = [
                .neutral: (colors.muted, colors.foreground),
                .district: (colors.district, colors.districtForeground),
                .success: (colors.success, colors.onSuccess),
                .warning: (colors.warning, colors.onWarning),
                .danger: (colors.destructive, colors.onDestructive),
                .info: (colors.info, colors.onInfo),
            ]
            for tone in Tone.allCases {
                XCTAssertEqual(tone.fill(colors, increasedContrast: true), solid[tone]?.fill, "\(tone)")
                XCTAssertEqual(tone.ink(colors, increasedContrast: true), solid[tone]?.ink, "\(tone)")
                XCTAssertEqual(tone.chipInk(colors, increasedContrast: true), solid[tone]?.ink, "\(tone)")
            }
        }
    }

    /// Without it, the ordinary tinted container and its ink.
    func testOrdinaryContrastIsTheTint() {
        let colors = DistrictColors.light
        for tone in Tone.allCases {
            XCTAssertEqual(tone.fill(colors, increasedContrast: false), tone.fill(colors), "\(tone)")
            XCTAssertEqual(tone.ink(colors, increasedContrast: false), tone.ink(colors), "\(tone)")
            XCTAssertEqual(tone.chipInk(colors, increasedContrast: false), tone.chipInk(colors), "\(tone)")
        }
        XCTAssertEqual(Tone.neutral.fill(colors), colors.muted)
        XCTAssertEqual(Tone.danger.ink(colors), colors.destructive)
        XCTAssertEqual(Tone.danger.chipInk(colors), colors.destructiveChipInk)
        XCTAssertEqual(Tone.neutral.chipInk(colors), colors.mutedForeground)
    }
}
