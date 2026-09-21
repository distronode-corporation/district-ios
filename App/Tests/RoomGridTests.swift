@testable import DistrictAI
import XCTest

/// The meeting grid's column count and self tile, as functions of the width it is given.
final class RoomGridTests: XCTestCase {
    private let spacing = DistrictSpacing.tight

    /// ⛔ EVERY PHONE WIDTH GETS TWO COLUMNS, however many people are in.
    func test_IOS_ROOM_GRID_01_aPhoneWidthIsAlwaysTwoColumns() {
        for width: CGFloat in [0, 288, 343, 370, 408] {
            for tiles in [0, 1, 2, 5, 12] {
                XCTAssertEqual(RoomGrid.columns(width: width, tiles: tiles, spacing: spacing), 2, "\(width) \(tiles)")
            }
        }
    }

    /// ⚠️ A WIDE GRID GROWS TO FIT, CAPPED BY THE WIDTH, THE CEILING AND THE HEADCOUNT.
    func test_IOS_ROOM_GRID_02_aWideGridGrowsToTheWidthAndTheHeadcount() {
        XCTAssertEqual(RoomGrid.columns(width: 700, tiles: 8, spacing: spacing), 3)
        XCTAssertEqual(RoomGrid.columns(width: 1000, tiles: 8, spacing: spacing), 4)
        XCTAssertEqual(RoomGrid.columns(width: 1300, tiles: 8, spacing: spacing), RoomGrid.maximumColumns)
        XCTAssertEqual(RoomGrid.columns(width: 1000, tiles: 3, spacing: spacing), 3)
        XCTAssertEqual(RoomGrid.columns(width: 1000, tiles: 1, spacing: spacing), 2)
    }

    /// ⚠️ THE SELF TILE GROWS EXACTLY WHERE THE GRID CAN FIRST GO PAST TWO COLUMNS.
    func test_IOS_ROOM_GRID_03_theSelfTileGrowsWithTheGrid() {
        XCTAssertEqual(RoomGrid.selfTileSize(width: 408), CGSize(width: 96, height: 128))
        let threshold = RoomGrid.regularGridWidth
        XCTAssertEqual(RoomGrid.columns(width: threshold, tiles: 3, spacing: spacing), 3)
        XCTAssertEqual(RoomGrid.columns(width: threshold - 1, tiles: 3, spacing: spacing), 2)
        XCTAssertEqual(RoomGrid.selfTileSize(width: threshold - 1).width, 96)
        XCTAssertEqual(RoomGrid.selfTileSize(width: threshold).width, 144)
        XCTAssertEqual(RoomGrid.selfTileSize(width: threshold).height, 192)
    }
}
