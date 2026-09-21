@testable import DistrictCall
import DistrictModel
import Foundation
import XCTest

/// The caller-identity mapping, kept out of `App/Sources` so it has a test lane.
///
/// ⛔ THE ASSERTIONS THAT MATTER ARE THE ONES ABOUT `"Unknown"`. The server builds a
/// call row's `number` as `displayName || c.from || "Unknown"`, so two of the three name-ish
/// columns on a call row are DISPLAY strings that carry the literal word Unknown
/// when nothing resolved. Reporting `CXHandle(type: .phoneNumber, value: "Unknown")`
/// to the operating system writes a string nobody can dial into the system call log,
/// on every device, permanently, and it is exactly what reading the obvious column
/// would produce.
final class IncomingCallIdentityTests: XCTestCase {
    /// A resolved contact: both halves present, and the screen shows the person.
    func testAResolvedContactCarriesBothTheNumberAndTheName() throws {
        let row = try Self.row(from: "+14165550134", callerName: "Ada Lovelace", number: "Ada Lovelace")
        let identity = IncomingCallIdentity.resolve(from: row)

        XCTAssertEqual(identity.handle, "+14165550134")
        XCTAssertEqual(identity.name, "Ada Lovelace")
        XCTAssertTrue(identity.isKnown)
        XCTAssertEqual(identity.displayLine, "Ada Lovelace")
    }

    /// ⛔ THE SENTINEL IS THE ABSENCE IT LOOKS LIKE, NOT A NAME. The server writes
    /// `displayName || "Unknown"` into `callerName`, so an unresolved caller arrives
    /// carrying the word rather than nil or an empty string. Passing it through would
    /// put "Unknown" on the ring screen and into Recents as somebody's name.
    func testTheUnknownSentinelIsRejectedAsAName() throws {
        let row = try Self.row(from: "+14165550134", callerName: "Unknown", number: "Unknown")
        let identity = IncomingCallIdentity.resolve(from: row)

        XCTAssertNil(identity.name)
        XCTAssertEqual(identity.handle, "+14165550134")
        // ⚠️ Still known: a number with no name is a perfectly good ring.
        XCTAssertTrue(identity.isKnown)
        // ⚠️ NEVER A THIRD STRING. The line falls back to the number rather than
        // inventing "Unknown caller", which would say more than the workspace knows.
        XCTAssertEqual(identity.displayLine, "+14165550134")
    }

    /// ⛔ THE HANDLE COMES FROM `from` AND FROM NOWHERE ELSE, WHICH IS THE WHOLE
    /// REASON THIS TYPE EXISTS. ``CallSummary/number`` is the column a reader reaches
    /// for first and it is a display string: here it holds the resolved person's
    /// name, and one row below it would hold the literal "Unknown". Either in a
    /// `.phoneNumber` handle is unusable and permanent.
    func testTheHandleIsNeverTakenFromTheDisplayNumberColumn() throws {
        let row = try Self.row(from: "+14165550150", callerName: "Grace Hopper", number: "Grace Hopper")
        let identity = IncomingCallIdentity.resolve(from: row)

        XCTAssertEqual(identity.handle, "+14165550150")
        XCTAssertNotEqual(identity.handle, "Grace Hopper")
    }

    /// ⚠️ AND THE SENTINEL IN THE DISPLAY COLUMN REACHES NEITHER FIELD. This is the
    /// row that would produce `CXHandle(value: "Unknown")` if `number` were the
    /// source.
    func testTheSentinelInTheDisplayColumnReachesNeitherField() throws {
        let row = try Self.row(from: nil, callerName: "Unknown", number: "Unknown")
        let identity = IncomingCallIdentity.resolve(from: row)

        XCTAssertNil(identity.handle)
        XCTAssertNil(identity.name)
        XCTAssertFalse(identity.isKnown)
        XCTAssertNil(identity.displayLine)
    }

    /// ⛔ BLANK COUNTS AS ABSENT. A handle made of whitespace is a handle nobody can
    /// dial and a blank entry in the system call log.
    func testAWhitespaceOnlyNumberIsAbsentRatherThanAHandle() throws {
        let row = try Self.row(from: "   ", callerName: "Ada Lovelace", number: "Ada Lovelace")
        let identity = IncomingCallIdentity.resolve(from: row)

        XCTAssertNil(identity.handle)
        XCTAssertEqual(identity.name, "Ada Lovelace")
        XCTAssertTrue(identity.isKnown)
        XCTAssertEqual(identity.displayLine, "Ada Lovelace")
    }

    /// ⚠️ THE SAME RULE ON THE NAME, AND AN EMPTY ONE IS NOT THE SENTINEL. Both
    /// collapse to nil, by two different clauses of the same guard.
    func testAnEmptyCallerNameIsAbsentRatherThanAName() throws {
        let row = try Self.row(from: "+14165550134", callerName: "", number: "+14165550134")
        let identity = IncomingCallIdentity.resolve(from: row)

        XCTAssertNil(identity.name)
        XCTAssertEqual(identity.displayLine, "+14165550134")
    }

    /// ⚠️ SURROUNDING WHITESPACE IS TRIMMED RATHER THAN CARRIED, on both fields. A
    /// leading space renders as an indented name and breaks an exact-match lookup.
    func testBothFieldsAreTrimmedRatherThanCarriedVerbatim() throws {
        let row = try Self.row(from: "  +14165550134 ", callerName: " Ada Lovelace ", number: "Ada Lovelace")
        let identity = IncomingCallIdentity.resolve(from: row)

        XCTAssertEqual(identity.handle, "+14165550134")
        XCTAssertEqual(identity.name, "Ada Lovelace")
    }

    /// ⚠️ THE WIRE VALUE IS PINNED, because it is a string being RECOGNISED rather
    /// than copy being shown: changing it silently stops the two guards firing.
    func testTheUnresolvedSentinelIsTheServersOwnWord() {
        XCTAssertEqual(IncomingCallIdentity.unresolvedName, "Unknown")
    }

    // MARK: - Helpers

    /// One `CallSummary`, decoded rather than constructed.
    ///
    /// ⚠️ THE DTO'S MEMBERWISE INITIALISER IS INTERNAL TO `DistrictModel`, so a test
    /// in another module cannot build one directly. Decoding is also the honest
    /// shape: this mapping only ever sees rows that came off the wire.
    private static func row(from: String?, callerName: String, number: String) throws -> CallSummary {
        let fromField = from.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id":"CA1","type":"inbound","number":"\(number)","status":"completed",
         "duration":"0m 12s","time":"9:41 AM","aiSummary":"","transcript":"",
         "callerName":"\(callerName)","summary":"","createdAt":"2026-09-06T09:41:00.000Z",
         "from":\(fromField)}
        """
        return try JSONDecoder().decode(CallSummary.self, from: Data(json.utf8))
    }
}
