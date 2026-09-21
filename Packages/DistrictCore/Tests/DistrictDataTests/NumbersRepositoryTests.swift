import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The marketplace's two reads.
///
/// ⛔ THE ASSERTIONS HERE ARE ABOUT WHICH OUTCOMES STAY DISTINCT. Three answers
/// on this surface all look like "there is nothing" and mean different things: a
/// genuinely empty inventory, a **400** because the workspace has connected no
/// carrier, and a **200** carrying a SHORT list because one carrier did not
/// answer. Flattening any pair produces a screen that is confidently wrong about
/// a customer's phone lines.
///
/// ⛔ AND NOTHING HERE BUYS, RELEASES OR CONFIGURES. There is no such method to
/// test, deliberately: a number is a recurring charge and a live line, and a
/// released one cannot be reclaimed.
final class NumbersRepositoryTests: XCTestCase {
    // MARK: - Search

    func testASearchPutsEveryFilterOnTheQueryOfTheSearchRoute() async {
        let transport = RepositoryTransport(json: NumberBodies.searchOneRow)

        let result = await NumbersRepository(client: .repositoryTest(transport)).search(
            workspaceId: "ws_1",
            areaCode: "416",
            country: "US",
            type: "local",
            provider: "twilio"
        )

        XCTAssertEqual(result.successOnly?.provider, "twilio")
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/search"
                + "?workspaceId=ws_1&areaCode=416&country=US&type=local&provider=twilio"
        )
        XCTAssertTrue(transport.bodies.isEmpty)
    }

    /// ⚠️ A BLANK FILTER IS THE SAME AS NO FILTER, AND THE SERVER DOES NOT AGREE
    /// UNLESS THE CLIENT NORMALISES. It distinguishes an omitted parameter from
    /// an empty one, so an empty `areaCode` would reach the carrier as a literal
    /// filter and return nothing. Asserted on the request bytes, since the
    /// difference is entirely in the URL.
    func testBlankAndWhitespaceFiltersAreDroppedRatherThanSentEmpty() async {
        let transport = RepositoryTransport(json: NumberBodies.searchOneRow)

        _ = await NumbersRepository(client: .repositoryTest(transport)).search(
            workspaceId: "ws_1",
            areaCode: "",
            country: "   ",
            type: nil,
            provider: "twilio"
        )

        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/search?workspaceId=ws_1&provider=twilio"
        )
    }

    /// ⛔ A WORKSPACE WITH NO CARRIER CONNECTED ANSWERS **400** AND THE SENTENCE
    /// REACHES THE SCREEN INTACT. It is a legitimate account state, not a fault,
    /// and the layer that knows how to render it as an empty state is the UI. ⛔
    /// What this layer must never do is convert it into an empty success: that
    /// would tell an operator the carrier has no numbers in their area code,
    /// which is a claim about inventory nobody looked at.
    func testAnUnconfiguredWorkspaceIsA400CarryingItsOwnSentenceAndNotAnEmptyList() async {
        let transport = RepositoryTransport(json: NumberBodies.notConfigured, status: 400)

        let result = await NumbersRepository(client: .repositoryTest(transport)).search(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 400)
        XCTAssertEqual(result.failureOnly?.message, "Messaging provider not configured for workspace")
        XCTAssertNil(result.successOnly, "⛔ never an empty success")
    }

    /// ⚠️ ENVELOPE FIRST. Every field of the response has a shape that survives a
    /// thin body, and the answer a caller would act on from a half-decoded search
    /// is "no numbers available" — the exact answer that sends someone off to try
    /// a different area code.
    func testASearchBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"provider":"twilio","numbers":[]}"#)

        let result = await NumbersRepository(client: .repositoryTest(transport)).search(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("NumberSearchResponse did not affirm success=true"))
    }

    func testASignedOutSearchIsA401() async {
        let transport = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)

        let result = await NumbersRepository(client: .repositoryTest(transport)).search(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 401)
    }

    // MARK: - What the workspace already owns

    func testReadingOwnedNumbersGetsTheProviderRouteWithTheWorkspaceInTheQuery() async {
        let transport = RepositoryTransport(json: NumberBodies.ownedClean)

        let result = await NumbersRepository(client: .repositoryTest(transport)).owned(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.numbers.count, 1)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/provider/numbers?workspaceId=ws_1"
        )
        XCTAssertEqual(result.successOnly?.failedProviderNames, [], "a clean list warns about nothing")
    }

    /// ⛔ THE `partial` FLAG IS CARRIED THROUGH INSIDE THE SUCCESS RATHER THAN
    /// CONVERTED INTO A FAILURE, AND BOTH DIRECTIONS OF THE COLLAPSE ARE WRONG.
    /// Upward, an error hides real inventory the operator can see nowhere else;
    /// downward, a plain list draws an incomplete answer as a complete one. Only
    /// the caller can render the middle: the rows AND the carrier's name.
    func testAPartialAnswerStaysASuccessAndKeepsBothTheRowsAndTheCarrierName() async throws {
        let transport = RepositoryTransport(json: NumberBodies.ownedPartial)

        let result = await NumbersRepository(client: .repositoryTest(transport)).owned(workspaceId: "ws_1")

        XCTAssertNil(result.failureOnly, "⛔ a 200 with an answer in hand is not an error")
        let response = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(response.partial, true)
        XCTAssertEqual(response.failedProviderNames, ["telnyx"])
        XCTAssertFalse(response.numbers.isEmpty, "⛔ the rows that DID resolve are still served")
    }

    /// ⚠️ THE 502 IS THE OTHER SIDE OF THE SAME DECISION: reserved for "a carrier
    /// failed AND nothing resolved at all", because a failed lookup rendered as
    /// an empty list reads as "you own no numbers". It passes through as an error,
    /// which is what makes the 200-with-a-flag above meaningful.
    func testACompleteCarrierFailureIsA502RatherThanAnEmptyList() async {
        let transport = RepositoryTransport(json: #"{"error":"Failed to list numbers"}"#, status: 502)

        let result = await NumbersRepository(client: .repositoryTest(transport)).owned(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 502)
        XCTAssertNil(result.successOnly)
    }

    func testAnOwnedBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"numbers":[]}"#)

        let result = await NumbersRepository(client: .repositoryTest(transport)).owned(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("OwnedNumbersResponse did not affirm success=true"))
    }

    /// ⚠️ A viewer reading someone else's workspace is a 403, and it is not a
    /// statement about inventory.
    func testAForbiddenOwnedReadPassesThroughUntouched() async {
        let transport = RepositoryTransport(json: #"{"error":"Forbidden"}"#, status: 403)

        let result = await NumbersRepository(client: .repositoryTest(transport)).owned(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 403)
    }
}

/// Minimal, VALID bodies for the two marketplace shapes.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-numbers-search.json` and the two
/// `district-provider-numbers*.json` pin the wire shape through the strict gate;
/// these are the smallest bodies that satisfy the Swift types.
private enum NumberBodies {
    static let searchOneRow = #"""
    {"success":true,"provider":"twilio",
     "numbers":[{"phoneNumber":"+14165550111","capabilities":["sms","voice"],"type":"local"}]}
    """#

    static let notConfigured = #"""
    {"success":false,"error":"Messaging provider not configured for workspace"}
    """#

    /// ⚠️ NEITHER FLAG IS PRESENT, which is what a clean list looks like on the
    /// wire — absent, not false and not an empty array.
    static let ownedClean = #"""
    {"success":true,"numbers":[{"phoneNumber":"+14165550100","capabilities":["voice"],
     "type":"local","status":"active","provider":"twilio","managed":false}]}
    """#

    static let ownedPartial = #"""
    {"success":true,"numbers":[{"phoneNumber":"+14165550100","capabilities":["voice"],
     "type":"local","status":"active","provider":"twilio","managed":false}],
     "partial":true,"failedProviders":["telnyx"]}
    """#
}
