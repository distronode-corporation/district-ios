@testable import DistrictAI
import SwiftUI
import UIKit
import XCTest

/// The 3.0.2 visual walk's fixes (iMac, build 723334fef): the Desk settings label printed
/// twice, the developer removals drawn as plain text, the phone's list rows on a colour the
/// palette does not have, and the iPad Desk row that broke its subject mid-word. The look is
/// the walk's to prove; these hold the rules behind it.
final class VisualWalk302Tests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let file = try SourceScan.sourceRoot().appendingPathComponent(relative)
        return try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
    }

    /// ⛔ NO DESK SETTINGS CARD IS TITLED WITH THE WORDS ITS OWN CONTROL DRAWS. The brand
    /// name and the email switch each printed their label twice, as the card's eyebrow and
    /// as the field's or switch's label; the control keeps it, as its accessibility name.
    func test_VW_01_deskSettingsCardsDoNotRepeatTheirControlsLabel() throws {
        let code = try source("Features/Desk/DeskSettingsView.swift")
        let lines = code.components(separatedBy: "\n")
        let marker = "SettingsCard(eyebrow: "
        var cards = 0
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: marker) else { continue }
            cards += 1
            let eyebrow = String(line[range.upperBound...].prefix { $0 != ")" })
            let following = lines[(index + 1) ..< min(index + 6, lines.count)].joined(separator: "\n")
            XCTAssertFalse(following.contains(eyebrow), "\(eyebrow) titles a card and labels its control")
        }
        XCTAssertEqual(cards, 2, "the enabled and logo cards keep their eyebrows")
        // The controls still carry the label, which is what VoiceOver announces.
        XCTAssertTrue(code.contains("label: DeskCopy.brandNameLabel,"))
        XCTAssertTrue(code.contains("Toggle(\n                DeskCopy.notifyLabel,"))
    }

    /// ⛔ REVOKE KEY, REVOKE ACCESS AND DELETE WEBHOOK ARE DESTRUCTIVE-STYLED (as the Mac's
    /// AP-023), and each still only asks: its confirmation dialog is attached to the button.
    func test_VW_02_developerRemovalsAreDestructiveAndStillAsk() throws {
        let code = try source("Features/Scheduling/Writes/SchedulingDeveloperWriteEntry.swift")
        let removals = [
            ("keyRevokeAction", "schedulingRevokeKeyDialogC"),
            ("appRevokeAction", "schedulingRevokeAppDialogC"),
            ("webhookDeleteAction", "schedulingDeleteWebhookDialogC"),
        ]
        for (action, dialog) in removals {
            let after = try XCTUnwrap(
                code.components(separatedBy: "Button(SchedulingWriteCopyC.\(action), role: .destructive)").dropFirst()
                    .first,
                "\(action) is not a destructive-role button"
            )
            let button = String(after.prefix(400))
            XCTAssertTrue(button.contains(".buttonStyle(.districtDestructive)"), action)
            XCTAssertFalse(button.prefix(80).contains(".districtGhost"), action)
            XCTAssertTrue(button.contains(".\(dialog)("), "\(action) lost its confirmation")
        }
    }

    /// ⛔ ON THE PHONE A ROUTE ROW IS ON THE CARD, light and dark; a list that selects keeps
    /// the system's cell, which is what draws the iPad's open row.
    func test_VW_03_phoneRowsSitOnTheCard() {
        XCTAssertEqual(RouteListRowGround.ground(.light, selects: false), DistrictColors.light.card)
        XCTAssertEqual(RouteListRowGround.ground(.dark, selects: false), DistrictColors.dark.card)
        XCTAssertNil(RouteListRowGround.ground(.light, selects: true))
        XCTAssertNil(RouteListRowGround.ground(.dark, selects: true))
    }

    /// ⛔ CONTACTS, INBOX AND CALLS BUILD EVERY ROW THROUGH ``View/routeListRow(selects:)``,
    /// so no row is left on the opaque system cell.
    func test_VW_04_theListsUseTheRowGround() throws {
        let files = [
            "Features/Contacts/ContactsView.swift": 3,
            "Features/Inbox/InboxView.swift": 4,
            "Features/Calls/CallLogView.swift": 2,
        ]
        for (file, rows) in files {
            let code = try source(file)
            XCTAssertFalse(code.contains(".listRowInsets(EdgeInsets())"), file)
            XCTAssertEqual(
                code.components(separatedBy: ".routeListRow(selects: selection != nil)").count - 1,
                rows,
                file
            )
        }
    }

    /// ⛔ A ROUTE ROW DRAWS A PALETTE HAIRLINE BELOW IT (3.0.2 walk 2). Hidden, the card-ground
    /// rows ran together into one white block on the light page; the system's grey is not a
    /// palette colour, so the separator takes the border token in both schemes, and starts
    /// at the row's text column, past the avatar.
    ///
    /// ⛔ AND IT FOLLOWS A LIVE LIGHT/DARK SWITCH (3.0.2 walk 3): the tint is one dynamic
    /// colour resolved per trait collection, because a tint picked from `colorScheme` kept
    /// the old scheme's hex on the rows until the tab was rebuilt.
    func test_VW_06_routeRowsDrawAPaletteSeparator() throws {
        let ink = RouteListRowGround.separatorInk
        XCTAssertEqual(Self.hex(ink.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))), "C9D6D8")
        XCTAssertEqual(Self.hex(ink.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))), "24393D")
        XCTAssertEqual(Self.hex(ink.resolvedColor(with: UITraitCollection(userInterfaceStyle: .unspecified))), "C9D6D8")
        XCTAssertEqual(Self.hex(UIColor(DistrictColors.light.border)), "C9D6D8", "the light border token moved")
        XCTAssertEqual(Self.hex(UIColor(DistrictColors.dark.border)), "24393D", "the dark border token moved")
        let ground = try source("Navigation/RouteList.swift")
        XCTAssertFalse(ground.contains(".listRowSeparator(.hidden)"), "the route rows hide their separator again")
        XCTAssertTrue(ground.contains(".listRowSeparator(.visible)"))
        XCTAssertTrue(ground.contains(".listRowSeparatorTint(Self.separator)"))
        let tint = try XCTUnwrap(ground.components(separatedBy: ".listRowSeparatorTint(").dropFirst().first?
            .components(separatedBy: "\n").first)
        XCTAssertFalse(tint.contains("colorScheme"), "the separator tint is picked from colorScheme again")
        let provider = try XCTUnwrap(ground.components(separatedBy: "static var separatorInk").dropFirst().first?
            .components(separatedBy: "static func ground").first)
        XCTAssertTrue(provider.contains("UIColor { traits in"), "the separator is no longer a dynamic colour")
        XCTAssertFalse(provider.contains("colorScheme"), "the separator ink reads colorScheme")
        let row = try source("DesignSystem/DistrictListRow.swift")
        XCTAssertTrue(row.contains(".alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }"))
    }

    /// ⛔ THE DESK ROW'S BADGE SITS ON THE REFERENCE'S LINE, sized first, and the subject
    /// takes the row's whole width below them, so it breaks between words in the iPad's
    /// list column and the badge keeps its whole label.
    func test_VW_05_theDeskBadgeSharesTheReferenceLine() throws {
        let code = try source("Features/Desk/DeskView.swift")
        let row = try XCTUnwrap(
            code.components(separatedBy: "struct DeskTicketRow").dropFirst().first?
                .components(separatedBy: "static func requesterLine").first
        )
        let reference = try XCTUnwrap(row.range(of: "Text(ticket.displayReference)"))
        let badge = try XCTUnwrap(row
            .range(of: "DeskStatusBadge(status: ticket.status)\n                    .layoutPriority(1)"))
        let subject = try XCTUnwrap(row.range(of: "Text(ticket.subject)"))
        XCTAssertLessThan(reference.lowerBound, badge.lowerBound)
        XCTAssertLessThan(badge.upperBound, subject.lowerBound)
        XCTAssertFalse(row.contains("HStack(alignment: .top"), "the subject is beside the badge again")
    }

    /// A resolved colour as six upper-case sRGB hex digits, rounded to the nearest step.
    private static func hex(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let bytes = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
