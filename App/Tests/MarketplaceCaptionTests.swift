@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// Phone numbers states each piece of its help once.
///
/// ⛔ THE BUG: a role that can change numbers read "New numbers cannot be purchased in this
/// app. Everything else about a number ... is here." and then "Everything else about your
/// numbers is on the other tabs."; a viewer on Registrations or Carrier read "needs an agency
/// or client role. Ask someone on this workspace who has one." twice. The Mac fixed the first
/// in 3.0.2 (AP-031); these hold both, as the Mac's `MacMarketplaceTests` do.
@MainActor
final class MarketplaceCaptionTests: XCTestCase {
    private func model(_ role: WorkspaceRole?) -> MarketplaceModel {
        MarketplaceModel(
            container: AppContainer(baseURL: URL(string: "https://api.invalid")!),
            workspaceId: "ws_1",
            role: role
        )
    }

    /// A role that can change numbers gets no second line under ``MarketplaceCopy/purchaseElsewhere``.
    func testARoleThatCanChangeNumbersGetsNoSecondLine() {
        for role in [WorkspaceRole.agency, .client] {
            let model = model(role)
            for tab in MarketplaceTab.allCases {
                model.selectTab(tab)
                XCTAssertNil(model.readOnlyCaption, "\(role) on \(tab)")
            }
        }
    }

    /// A viewer is told who can make a change once per screen: by the caption on the tabs that
    /// do not say it themselves, by the tab's own content on the two that do.
    func testAViewerIsToldWhoCanChangeNumbersOnce() {
        for role in [WorkspaceRole.viewer, nil] {
            let model = model(role)
            for tab in MarketplaceTab.allCases {
                model.selectTab(tab)
                let expected = tab.statesTheViewerRefusal ? nil : MarketplaceCopy.readOnlyViewer
                XCTAssertEqual(model.readOnlyCaption, expected, "\(String(describing: role)) on \(tab)")
            }
        }
        XCTAssertEqual(
            MarketplaceTab.allCases.filter(\.statesTheViewerRefusal),
            [.registrations, .carrier]
        )
    }
}
