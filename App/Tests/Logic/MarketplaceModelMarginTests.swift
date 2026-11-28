@testable import DistrictAI
import DistrictModel
import XCTest

/// ``MarketplaceModel``'s two reads over a real container: the owned list complete and partial,
/// its failure, the search and its results, the 400 that means "no carrier connected" (with the
/// server's sentence and with a blank one), any other failure, and the form and tabs.
final class MarketplaceModelMarginTests: ScreenSnapshotTestCase {
    private static let ownedPath = "/api/district/workspace/provider/numbers"
    private static let searchPath = "/api/district/workspace/numbers/search"

    private func model(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (MarketplaceModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let container = try await container(transport)
        return (MarketplaceModel(container: container, workspaceId: "ws-contract-test", role: role), transport)
    }

    func testTheOwnedListIsCompleteFromTheRecordedReply() async throws {
        let (model, transport) = try await model()
        await model.loadOwned()
        guard case let .ready(numbers, partial, failed) = model.owned else {
            return XCTFail("expected ready, got \(model.owned)")
        }
        XCTAssertFalse(numbers.isEmpty)
        XCTAssertFalse(partial)
        XCTAssertEqual(failed, [])
        XCTAssertEqual(transport.unanswered, [])
        guard case .idle = model.search else { return XCTFail("the owned read touched the search") }
    }

    /// ⛔ A partial 200 keeps its rows and names the carrier that did not answer.
    func testAPartialOwnedListKeepsItsRowsAndNamesTheCarrier() async throws {
        let (model, _) = try await model([Self.ownedPath: .fixture("district-provider-numbers-partial")])
        await model.loadOwned()
        guard case let .ready(numbers, partial, failed) = model.owned else {
            return XCTFail("expected ready, got \(model.owned)")
        }
        XCTAssertEqual(numbers.map(\.phoneNumber), ["+14165550100", "+14165550199", "+18005550188"])
        XCTAssertTrue(partial)
        XCTAssertEqual(failed, ["telnyx"])
    }

    func testAFailedOwnedReadIsAFailure() async throws {
        let (model, _) = try await model([Self.ownedPath: .json(#"{"error":"Internal error"}"#, status: 500)])
        await model.loadOwned()
        guard case .failed = model.owned else { return XCTFail("expected a failure, got \(model.owned)") }
    }

    func testASearchAnswersWithTheCarrierThatAnswered() async throws {
        let (model, transport) = try await model()
        XCTAssertFalse(model.isSearching)
        model.updateAreaCode("416")
        model.updateCountry("CA")
        model.updateType("local")
        XCTAssertEqual(model.form.areaCode, "416")
        XCTAssertEqual(model.form.country, "CA")
        XCTAssertEqual(model.form.type, "local")
        await model.runSearch()
        XCTAssertFalse(model.isSearching)
        guard case let .ready(provider, numbers) = model.search else {
            return XCTFail("expected ready, got \(model.search)")
        }
        XCTAssertEqual(provider, "twilio")
        XCTAssertEqual(numbers.map(\.phoneNumber), ["+14165550111", "+18005550122"])
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.searchPath)" }.count, 1)
        XCTAssertFalse(transport.requested.contains("GET \(Self.ownedPath)"))
        guard case .loading = model.owned else { return XCTFail("the search touched the owned list") }
    }

    /// The search is loading while it is in flight.
    func testTheSearchIsLoadingWhileInFlight() async throws {
        let (model, _) = try await model()
        let search = Task { await model.runSearch() }
        for _ in 0 ..< 200 where !model.isSearching {
            await Task.yield()
        }
        XCTAssertTrue(model.isSearching)
        await search.value
        XCTAssertFalse(model.isSearching)
    }

    /// ⛔ A 400 is "no carrier connected", carrying the server's own sentence, trimmed.
    func testA400IsNotConfiguredWithTheServersSentence() async throws {
        let (model, _) = try await model([
            Self.searchPath: .json(#"{"error":"  No messaging provider configured  "}"#, status: 400),
        ])
        await model.runSearch()
        guard case let .notConfigured(text) = model.search else {
            return XCTFail("expected not configured, got \(model.search)")
        }
        XCTAssertEqual(text, "No messaging provider configured")
    }

    /// ⚠️ A blank sentence on the 400 counts as absent: the screen's own fallback is shown.
    func testA400WithABlankSentenceUsesTheFallback() async throws {
        for body in [#"{"error":"   "}"#, #"{}"#] {
            let (model, _) = try await model([Self.searchPath: .json(body, status: 400)])
            await model.runSearch()
            guard case let .notConfigured(text) = model.search else {
                return XCTFail("expected not configured for \(body), got \(model.search)")
            }
            XCTAssertEqual(text, MarketplaceCopy.notConfiguredFallback, body)
        }
    }

    /// Any other status is a plain failure, never an empty result.
    func testOtherFailuresAreFailures() async throws {
        for status in [403, 404, 500, 503] {
            let (model, _) = try await model([Self.searchPath: .json(#"{"error":"nope"}"#, status: status)])
            await model.runSearch()
            guard case .failed = model.search else {
                return XCTFail("expected a failure for \(status), got \(model.search)")
            }
        }
    }

    /// A body that does not decode is a failure, not a 400 account state.
    func testAMalformedSearchBodyIsAFailure() async throws {
        let (model, _) = try await model([Self.searchPath: .json("not json")])
        await model.runSearch()
        guard case .failed = model.search else { return XCTFail("expected a failure, got \(model.search)") }
    }

    /// The form survives a tab switch, and selecting the current tab is a no-op.
    func testTheFormSurvivesATabSwitch() async throws {
        let (model, _) = try await model()
        XCTAssertEqual(model.tab, .owned)
        XCTAssertEqual(model.form.country, MarketplaceCopy.defaultCountry)
        XCTAssertEqual(model.form.type, MarketplaceCopy.numberTypeLocal)
        model.updateAreaCode("")
        model.updateAreaCode("514")
        model.selectTab(.search)
        model.selectTab(.search)
        XCTAssertEqual(model.tab, .search)
        model.selectTab(.carrier)
        model.selectTab(.owned)
        XCTAssertEqual(model.tab, .owned)
        XCTAssertEqual(model.form.areaCode, "514")
    }

    /// ⚠️ A nil role errs low: it cannot change numbers.
    func testANilRoleCannotChangeNumbers() async throws {
        let (unknown, _) = try await model(role: nil)
        XCTAssertFalse(unknown.canChangeNumbers)
        let (viewer, _) = try await model(role: .viewer)
        XCTAssertFalse(viewer.canChangeNumbers)
        let (agency, _) = try await model(role: .agency)
        XCTAssertTrue(agency.canChangeNumbers)
    }
}
