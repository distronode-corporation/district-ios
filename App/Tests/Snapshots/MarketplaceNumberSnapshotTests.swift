@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The owned-number surfaces of Phone numbers: the list in its partial, empty and failed
/// states, one number's actions sheet, the confirmations collected before an irreversible or
/// billable write, and the search form and its results.
final class MarketplaceNumberSnapshotTests: ScreenSnapshotTestCase {
    private static let owned = "/api/district/workspace/provider/numbers"
    private static let configure = "/api/district/workspace/numbers/configure"
    private static let release = "/api/district/workspace/numbers/release"

    // MARK: - My numbers

    /// A carrier that did not answer: the banner naming it over the numbers that did come back.
    func testOwnedPartial() async throws {
        try await assertScreen([Self.owned: .fixture("district-provider-numbers-partial")]) { container in
            MarketplaceView(container: container, workspaceId: MarketplaceBodies.workspace, role: .client)
        }
    }

    /// No numbers yet: its own sentence, not a blank list.
    func testOwnedEmpty() async throws {
        try await assertScreen(
            [Self.owned: .recorded("district-provider-numbers") { $0["numbers"] = [Any]() }],
            devices: [.iPhone]
        ) { container in
            MarketplaceView(container: container, workspaceId: MarketplaceBodies.workspace, role: .client)
        }
    }

    /// A refused read draws the failure card with its retry.
    func testOwnedFailed() async throws {
        try await assertScreen([Self.owned: .refused(500)], devices: [.iPhone]) { container in
            MarketplaceView(container: container, workspaceId: MarketplaceBodies.workspace, role: .client)
        }
    }

    /// A viewer reads the same list, with the caption saying who can change a number.
    func testOwnedForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            MarketplaceView(container: container, workspaceId: MarketplaceBodies.workspace, role: .viewer)
        }
    }

    // MARK: - One number's actions

    /// A number this workspace brought itself: reapply routing, and release.
    func testActionsForANumberItHolds() async throws {
        let number = try Self.number("+14165550100")
        try await assertScreen(devices: [.iPhone]) { container in
            Self.actions(container, role: .client, number: number) { _ in }
        }
    }

    /// A number Distronode manages for the workspace cannot be released here, and says so.
    func testActionsForAManagedNumber() async throws {
        let number = try Self.number("+14165550199")
        try await assertScreen(devices: [.iPhone]) { container in
            Self.actions(container, role: .client, number: number) { _ in }
        }
    }

    /// A viewer is told who can act, with no control drawn.
    func testActionsForAViewer() async throws {
        let number = try Self.number("+14165550100")
        try await assertScreen(devices: [.iPhone]) { container in
            Self.actions(container, role: .viewer, number: number) { _ in }
        }
    }

    /// Routing reapplied: the notice, with both controls still armed (configure converges).
    func testActionsAfterConfigure() async throws {
        let number = try Self.number("+14165550100")
        let replies = [Self.configure: FixtureTransport.Reply.fixture("district-number-configure")]
        try await assertScreen(replies, devices: [.iPhone]) { container in
            Self.actions(container, role: .client, number: number) {
                await $0.configure(phoneNumber: "+14165550100")
            }
        }
    }

    /// A release that went through but could not end its monthly charge says so, not in red.
    func testActionsAfterAReleaseWithWarnings() async throws {
        let number = try Self.number("+14165550100")
        let replies = [Self.release: FixtureTransport.Reply.fixture("district-number-release-warnings")]
        try await assertScreen(replies, devices: [.iPhone]) { container in
            Self.actions(container, role: .client, number: number) {
                await $0.release(phoneNumber: "+14165550100")
            }
        }
    }

    /// A release whose answer was lost: both controls disarmed, and the sentence saying why.
    func testActionsAfterAnUnconfirmedRelease() async throws {
        let number = try Self.number("+14165550100")
        try await assertScreen([Self.release: .refused(500)], devices: [.iPhone]) { container in
            Self.actions(container, role: .client, number: number) {
                await $0.release(phoneNumber: "+14165550100")
            }
        }
    }

    // MARK: - Confirmations

    func testConfirmRelease() async throws {
        try await assertConfirmation(.release(phoneNumber: "+14165550100"))
    }

    func testConfirmSubmitRegistration() async throws {
        try await assertConfirmation(.submitRegistration(bundleId: "bun_draft", country: "EE"))
    }

    func testConfirmA2P() async throws {
        try await assertConfirmation(.a2p)
    }

    func testConfirmTollFree() async throws {
        try await assertConfirmation(.tfv(phoneNumber: "+18005550188"))
    }

    func testConfirmLookup() async throws {
        try await assertConfirmation(.lookup(phoneNumber: "+14165550142"))
    }

    /// A release the service refused with a 4xx proves nothing was released, so reopening the
    /// confirmation is allowed and it carries the refusal over an armed button.
    func testConfirmReleaseAfterARefusal() async throws {
        try await assertScreen(
            [Self.release: .refused(409, "This number is still assigned to a routing rule.")],
            devices: [.iPhone]
        ) { container in
            Self.confirmation(container) { model in
                await model.release(phoneNumber: "+14165550100")
                model.requestConfirmation(.release(phoneNumber: "+14165550100"))
            }
        }
    }

    // MARK: - Search

    /// The search form as first drawn, local selected.
    func testSearchForm() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView {
                NumberSearchFormCard(
                    areaCode: .constant("416"),
                    country: .constant("CA"),
                    selectedType: MarketplaceCopy.numberTypeLocal,
                    searching: false,
                    onSelectType: { _ in },
                    onSearch: {}
                )
                .padding(DistrictSpacing.gutter)
            }
        }
    }

    /// The recorded results: a local number with its locality and price, and a toll-free one
    /// with neither, under the carrier that answered.
    func testSearchResults() async throws {
        let response = try JSONDecoder().decode(
            NumberSearchResponse.self,
            from: FixtureTransport.fixtureData("district-numbers-search")
        )
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView {
                SearchResultsList(provider: response.provider, numbers: response.numbers)
                    .padding(DistrictSpacing.gutter)
            }
        }
    }

    /// A search with nothing for sale says so, and a blank provider names no carrier.
    func testSearchResultsEmpty() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView {
                SearchResultsList(provider: "  ", numbers: [])
                    .padding(DistrictSpacing.gutter)
            }
        }
    }

    // MARK: - Helpers

    /// Opens `confirmation` on a fresh model, as the row's or card's button does, and draws
    /// the sheet the screen presents for it.
    private func assertConfirmation(
        _ confirmation: NumberConfirmation,
        testName: String = #function,
        line: UInt = #line
    ) async throws {
        try await assertScreen(devices: [.iPhone], testName: testName, line: line) { container in
            Self.confirmation(container) { $0.requestConfirmation(confirmation) }
        }
    }

    /// One number's actions sheet, over a model `drive` has written through.
    private static func actions(
        _ container: AppContainer,
        role: WorkspaceRole?,
        number: ListedNumber,
        drive: @escaping @MainActor @Sendable (NumberProvisioningModel) async -> Void
    ) -> some View {
        ProvisioningHost(container, role: role, drive: drive, content: {
            NumberActionsSheet(model: $0, number: number)
        })
    }

    /// The confirmation sheet the screen presents from the model's own state.
    private static func confirmation(
        _ container: AppContainer,
        drive: @escaping @MainActor @Sendable (NumberProvisioningModel) async -> Void
    ) -> some View {
        ProvisioningHost(container, role: .client, drive: drive, content: { NumberConfirmationHost(model: $0) })
    }

    /// The recorded owned number `phoneNumber`.
    private static func number(_ phoneNumber: String) throws -> ListedNumber {
        let response = try JSONDecoder().decode(
            OwnedNumbersResponse.self,
            from: FixtureTransport.fixtureData("district-provider-numbers")
        )
        return try XCTUnwrap(response.numbers.first { $0.phoneNumber == phoneNumber })
    }
}
