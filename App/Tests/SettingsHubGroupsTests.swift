@testable import DistrictAI
import XCTest

/// The settings hub's groups: which rows sit under District Studio, in what order, and what
/// they are called.
///
/// ⛔ THE ORDER IS THE WEB'S, and the web is not visible from here, so the expected lists are
/// written out rather than derived. The web's District Studio pages are, in order: Studio home,
/// Persona, Voice, Call handling, Skills, Knowledge, Integrations, Video. Call handling is three
/// screens in this app (how calls are answered, the dynamic persona rules, the transfer
/// directory, in the web page's own order); Integrations and Video have no screen here.
final class SettingsHubGroupsTests: XCTestCase {
    private var groups: [SettingsHubGroup] {
        SettingsHubView.groups
    }

    func test_IOS_HUB_01_theStudioGroupComesFirstAndFollowsTheWebsPages() {
        XCTAssertEqual(groups.map(\.title), ["District Studio", "Workspace"])
        XCTAssertEqual(
            groups.first?.entries.map(\.section),
            [.persona, .voiceStudio, .calls, .routing, .directory, .capabilities, .knowledge]
        )
        XCTAssertEqual(groups.last?.entries.map(\.section), [.messaging, .members, .scheduling])
    }

    /// ⛔ EVERY SECTION BUT THE HUB ITSELF IS A ROW, EXACTLY ONCE. A section added to the enum
    /// and to no group would be a screen nothing can open.
    func test_IOS_HUB_02_everySectionButTheHubIsOneRow() {
        let listed = groups.flatMap { $0.entries.map(\.section) }
        XCTAssertEqual(listed.count, Set(listed).count, "a section is listed twice")
        XCTAssertEqual(Set(listed), Set(SettingsSection.allCases).subtracting([.hub]))
    }

    /// The rows the web names the same way are called what the web calls them.
    func test_IOS_HUB_03_theStudioRowsUseTheWebsPageNames() {
        let titles = Dictionary(uniqueKeysWithValues: groups.flatMap(\.entries).map { ($0.section, $0.title) })
        XCTAssertEqual(titles[.persona], "Persona")
        XCTAssertEqual(titles[.voiceStudio], "Voice")
        XCTAssertEqual(titles[.capabilities], "Skills")
        XCTAssertEqual(titles[.knowledge], "Knowledge")
    }

    /// ⚠️ THE VOICE SCREEN'S TITLE IS THE ROW'S AND THE WIRE HEADING'S. The service sends
    /// "Voice", so the title before the read lands says the same, or it would change word
    /// mid-load.
    func test_IOS_HUB_04_theVoiceScreenTitleIsTheWireHeadingsName() {
        XCTAssertEqual(VoiceStudioCopy.title, "Voice")
        XCTAssertEqual(VoiceStudioCopy.title, SettingsCopy.voiceStudioTitle)
    }
}
