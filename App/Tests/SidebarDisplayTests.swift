@testable import DistrictAI
import DistrictModel
import XCTest

/// How the sidebar's rows read, held against the two surfaces they must agree with: the
/// tab bar, and the Overview's entry column.
final class SidebarDisplayTests: XCTestCase {
    private let workspaceId = "ws_1"

    /// ⛔ A TAB'S ROW IS THE TAB: the same word and the same glyph, so a rotation from one
    /// layout to the other does not look like a move to somewhere else.
    func test_IOS_SIDEBAR_DISPLAY_01_aTabsRowReadsAsTheTab() {
        for tab in Tab.allCases {
            let item = SidebarItem(tab: tab)
            XCTAssertEqual(item.sidebarTitle, tab.label, "\(tab)")
            XCTAssertEqual(item.sidebarSymbol, tab.systemImage, "\(tab)")
        }
    }

    /// ⛔ A HUB'S ROW SAYS WHAT ITS OVERVIEW ROW SAYS, with the one pinned exception: the
    /// Overview's HQ row is a call to action, and the sidebar names the place.
    func test_IOS_SIDEBAR_DISPLAY_02_aHubsRowReadsAsItsOverviewRow() {
        let entries = OverviewEntry.all(workspaceId: workspaceId, role: .agency)
        for entry in entries {
            guard case let .route(route) = entry.target, let item = SidebarItem.hubItem(forRoot: route) else {
                continue
            }
            let expected = item == .hq ? "Open \(item.sidebarTitle)" : item.sidebarTitle
            XCTAssertEqual(entry.title, expected, "\(item)")
        }
    }

    func test_IOS_SIDEBAR_DISPLAY_03_everyRowHasItsOwnGlyphAndIdentifier() {
        let symbols = SidebarItem.allCases.map(\.sidebarSymbol)
        let identifiers = SidebarItem.allCases.map(\.accessibilityID)
        XCTAssertFalse(symbols.contains(""))
        XCTAssertEqual(Set(symbols).count, symbols.count, "two rows share a glyph: \(symbols)")
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("district-sidebar-") }, "\(identifiers)")
    }

    /// ⛔ A PLACEHOLDER EXISTS FOR EXACTLY THE LIST SECTIONS. Anything else fills the
    /// detail column with its own screen.
    func test_IOS_SIDEBAR_DISPLAY_04_onlyAListSectionHasADetailPlaceholder() {
        for item in SidebarItem.allCases {
            XCTAssertEqual(item.detailPlaceholder != nil, item.isListSection, "\(item)")
        }
    }
}
