import ContractGateSupport
import Foundation
import XCTest

/// Proof that the strict gate can FAIL.
///
/// ⛔ THIS FILE IS THE ACCEPTANCE CRITERION FOR THE GATE, NOT AN EXTRA. A gate
/// that has only ever been observed passing is indistinguishable from a gate
/// that checks nothing, and this repo has been burned by exactly that shape more
/// than once — a green suite that agreed with the bug, an e2e tier that reported
/// success while running zero specs. Every rejection path below is driven with a
/// deliberately-broken payload and asserted to throw the SPECIFIC failure, with
/// the fixture name and the JSON path an operator would need.
///
/// ⚠️ THE PAYLOADS ARE IN-MEMORY, NOT COMMITTED FIXTURES. A broken fixture on
/// disk would be picked up by the enumeration in `ContractFixtureTests` and
/// counted as part of the corpus, which is the opposite of what these are.
final class StrictDecodeVerifierTests: XCTestCase {
    // MARK: - Positive control

    /// If this ever fails, every negative test below is proving nothing.
    func testWellFormedPayloadPasses() throws {
        let json = """
        {"success":true,"members":[{"email":"a@b.test","role":"agency"}]}
        """
        let value = try StrictDecodeVerifier.verify(
            name: "control.json",
            json: Data(json.utf8),
            as: SimpleRoster.self
        )
        XCTAssertTrue(value.success)
        XCTAssertEqual(value.members.count, 1)
        XCTAssertEqual(value.members[0].email, "a@b.test")
    }

    // MARK: - An unknown server key the DTO silently drops

    /// ⛔ THE CASE FOUNDATION CANNOT CATCH ON ITS OWN. `JSONDecoder` has no
    /// `ignoreUnknownKeys = false`; it ignores `serverAddedThis` without a
    /// murmur. Only the re-encode makes the loss visible.
    func testUnknownTopLevelKeyIsRejected() {
        let json = """
        {"success":true,"members":[],"serverAddedThis":"surprise"}
        """
        let failure = gateFailure("unknown-key.json", json, as: SimpleRoster.self)
        guard case let .droppedKeys(fixture, _, path, keys)? = failure else {
            return XCTFail("expected droppedKeys, got \(String(describing: failure))")
        }
        XCTAssertEqual(fixture, "unknown-key.json")
        XCTAssertEqual(path, "$")
        XCTAssertEqual(keys, ["serverAddedThis"])
    }

    /// The same check has to reach INSIDE arrays, because that is where most of
    /// the API's shape lives — a roster row, a call row, a timeline entry.
    func testUnknownKeyInsideAnArrayElementIsRejected() {
        let json = """
        {"success":true,"members":[
          {"email":"a@b.test","role":"agency"},
          {"email":"c@d.test","role":"viewer","invitedBy":"someone"}
        ]}
        """
        let failure = gateFailure("nested-unknown-key.json", json, as: SimpleRoster.self)
        guard case let .droppedKeys(_, _, path, keys)? = failure else {
            return XCTFail("expected droppedKeys, got \(String(describing: failure))")
        }
        // ⚠️ The path must name the ELEMENT, not just the array: a 40-row fixture
        // with one odd row is otherwise a manual bisect.
        XCTAssertEqual(path, "$.members[1]")
        XCTAssertEqual(keys, ["invitedBy"])
    }

    // MARK: - A key the DTO requires and the payload does not carry

    func testMissingRequiredKeyIsRejected() {
        let json = """
        {"members":[]}
        """
        let failure = gateFailure("missing-key.json", json, as: SimpleRoster.self)
        guard case let .decodeFailed(fixture, type, reason)? = failure else {
            return XCTFail("expected decodeFailed, got \(String(describing: failure))")
        }
        XCTAssertEqual(fixture, "missing-key.json")
        XCTAssertEqual(type, "SimpleRoster")
        // The reason has to name the key. DecodingError's localizedDescription on
        // Linux is "The operation could not be completed", which names nothing.
        XCTAssertTrue(reason.contains("success"), "reason should name the missing key: \(reason)")
    }

    // MARK: - Asymmetric Codable

    /// ⛔ THE FAILURE MODE A DECODE-ONLY TEST CAN NEVER SEE. `init(from:)` reads
    /// `name`; `encode(to:)` writes `title`. Decoding succeeds, the value is
    /// correct, and the app would still serialise something the server cannot
    /// read — a real hazard on the request side, where the same DTOs get reused.
    func testAsymmetricEncoderIsRejected() {
        let failure = gateFailure("asymmetric.json", #"{"name":"Renamed Workspace"}"#, as: RenamingOnEncode.self)
        guard case let .droppedKeys(_, _, path, keys)? = failure else {
            return XCTFail("expected droppedKeys, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$")
        XCTAssertEqual(keys, ["name"])
    }

    /// The mirror image: an encoder that emits a key the contract never carried.
    /// A non-Optional property with a default does this too.
    func testEncoderThatInventsAKeyIsRejected() {
        let failure = gateFailure("inventing.json", #"{"success":true}"#, as: InventingOnEncode.self)
        guard case let .addedKeys(_, _, path, keys)? = failure else {
            return XCTFail("expected addedKeys, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$")
        XCTAssertEqual(keys, ["clientOnlyField"])
    }

    func testEncoderThatChangesAValuesShapeIsRejected() {
        let failure = gateFailure("shape.json", #"{"tags":["a","b"]}"#, as: ArrayToStringOnEncode.self)
        guard case let .shapeMismatch(_, _, path, raw, encoded)? = failure else {
            return XCTFail("expected shapeMismatch, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$.tags")
        XCTAssertEqual(raw, "array")
        XCTAssertEqual(encoded, "string")
    }

    func testEncoderThatDropsAnArrayElementIsRejected() {
        let failure = gateFailure("length.json", #"{"items":["a","b","c"]}"#, as: DroppingElementOnEncode.self)
        guard case let .arrayLengthMismatch(_, _, path, raw, encoded)? = failure else {
            return XCTFail("expected arrayLengthMismatch, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$.items")
        XCTAssertEqual(raw, 3)
        XCTAssertEqual(encoded, 2)
    }

    // MARK: - The no-nulls invariant

    /// ⛔ THE INVARIANT THE WHOLE GATE RESTS ON. Swift
    /// encodes a nil Optional as an OMITTED key, so an explicit null in a
    /// fixture makes step 4 report a mismatch that is not a real contract break —
    /// and the tempting fix, loosening the comparison, disables the unknown-key
    /// check for every other fixture at once.
    func testExplicitNullIsRejectedAndNamesItsPath() {
        let json = """
        {"success":true,"members":[{"email":"a@b.test","role":null}]}
        """
        let failure = gateFailure("null.json", json, as: NullableRoster.self)
        guard case let .explicitNull(fixture, path)? = failure else {
            return XCTFail("expected explicitNull, got \(String(describing: failure))")
        }
        XCTAssertEqual(fixture, "null.json")
        XCTAssertEqual(path, "$.members[0].role")
    }

    /// The null check runs BEFORE the decode, so a fixture that is both
    /// null-bearing and undecodable reports the null — the more actionable of
    /// the two, and the one that explains the other.
    func testNullCheckRunsBeforeDecoding() {
        let failure = gateFailure("null-first.json", #"{"role":null}"#, as: NullableRoster.self)
        guard case .explicitNull? = failure else {
            return XCTFail("expected explicitNull to pre-empt decodeFailed, got \(String(describing: failure))")
        }
    }

    /// The sanctioned escape hatch, exercised through the parameter so the
    /// shipped `allowedExplicitNulls` constant can stay empty.
    ///
    /// ⚠️ AN ALLOWLISTED PATH IS EXEMPT FROM BOTH HALVES: the null assertion AND
    /// the key-set comparison. Exempting it from only the first would trade one
    /// failure for another and teach the next reader that the allowlist does not
    /// work.
    func testAllowlistedPathPermitsAnExplicitNull() throws {
        let json = """
        {"success":true,"members":[{"email":"a@b.test","role":null}]}
        """
        let value = try StrictDecodeVerifier.verify(
            name: "allowlisted.json",
            json: Data(json.utf8),
            as: NullableRoster.self,
            allowingExplicitNulls: ["$.members[0].role"]
        )
        XCTAssertNil(value.members[0].role)
    }

    /// ⛔ AND THE ALLOWLIST IS PER PATH, NOT PER FIXTURE. An entry for one field
    /// must not silence a null somewhere else in the same file, which is exactly
    /// what a fixture-wide exemption would do.
    func testAllowlistDoesNotCoverAnUnlistedPath() {
        let json = """
        {"success":true,"members":[
          {"email":"a@b.test","role":null},
          {"email":"c@d.test","role":null}
        ]}
        """
        let failure = gateFailure(
            "allowlist-scope.json",
            json,
            as: NullableRoster.self,
            allowingExplicitNulls: ["$.members[0].role"]
        )
        guard case let .explicitNull(_, path)? = failure else {
            return XCTFail("expected explicitNull for the unlisted path, got \(String(describing: failure))")
        }
        XCTAssertEqual(path, "$.members[1].role")
    }

    // MARK: - Not JSON at all

    func testNonJSONPayloadIsRejected() {
        let failure = gateFailure("garbage.json", "this is not json", as: SimpleRoster.self)
        guard case let .unreadable(fixture, _)? = failure else {
            return XCTFail("expected unreadable, got \(String(describing: failure))")
        }
        XCTAssertEqual(fixture, "garbage.json")
    }

    // MARK: - The messages themselves

    /// The description is what a CI log shows, and a failure that does not name
    /// the fixture costs a manual bisect through the corpus.
    func testFailureDescriptionsNameTheFixtureAndThePath() {
        let dropped = ContractGateFailure.droppedKeys(
            fixture: "district-members.json",
            type: "MemberListResponse",
            path: "$.members[2]",
            keys: ["invitedBy", "seatId"]
        )
        XCTAssertTrue(dropped.description.contains("district-members.json"))
        XCTAssertTrue(dropped.description.contains("$.members[2]"))
        XCTAssertTrue(dropped.description.contains("invitedBy, seatId"))

        let nulled = ContractGateFailure.explicitNull(fixture: "x.json", path: "$.a.b")
        XCTAssertTrue(nulled.description.contains("allowedExplicitNulls"))
        XCTAssertTrue(nulled.description.contains("$.a.b"))

        // The remaining cases are rendered here rather than left unexercised: a
        // string-interpolation typo in a diagnostic only shows up when the gate
        // is already failing, which is the worst moment to discover it.
        let rendered = [
            ContractGateFailure.unreadable(fixture: "x.json", reason: "bad"),
            .decodeFailed(fixture: "x.json", type: "T", reason: "missing key `id`"),
            .encodeFailed(fixture: "x.json", type: "T", reason: "boom"),
            .addedKeys(fixture: "x.json", type: "T", path: "$", keys: ["extra"]),
            .shapeMismatch(fixture: "x.json", type: "T", path: "$.a", raw: "array", encoded: "string"),
            .arrayLengthMismatch(fixture: "x.json", type: "T", path: "$.a", raw: 3, encoded: 2),
        ]
        for failure in rendered {
            XCTAssertTrue(failure.description.contains("x.json"), "\(failure)")
        }
    }

    /// The corpus-level failures are a different family and say so: they mean the
    /// gate could not run at all, which is worse than any single fixture failing.
    func testFixtureUnavailableDescriptionsExplainThemselves() {
        let missingDir = ContractFixturesUnavailable.missingDirectory(path: "/nope")
        XCTAssertTrue(missingDir.description.contains("/nope"))
        XCTAssertTrue(missingDir.description.contains(ContractFixtures.overrideEnvironmentKey))

        let empty = ContractFixturesUnavailable.emptyDirectory(path: "/empty")
        XCTAssertTrue(empty.description.contains("hard failure"))

        let missing = ContractFixturesUnavailable.missingFixture(name: "a.json", path: "/x/a.json")
        XCTAssertTrue(missing.description.contains("CONTRACTS_UPDATE=1"))
    }

    /// The override is what makes a containerised run possible, and pointing it
    /// somewhere useless has to fail loudly rather than quietly verify nothing.
    func testMissingDirectoryThrowsRatherThanReturningNothing() {
        let key = ContractFixtures.overrideEnvironmentKey
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "/definitely/not/a/contracts/directory", 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        XCTAssertThrowsError(try ContractFixtures.allFixtureNames()) { error in
            guard case ContractFixturesUnavailable.missingDirectory = error else {
                return XCTFail("expected missingDirectory, got \(error)")
            }
        }
        XCTAssertThrowsError(try ContractFixtures.read("anything.json")) { error in
            guard case ContractFixturesUnavailable.missingFixture = error else {
                return XCTFail("expected missingFixture, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func gateFailure(
        _ name: String,
        _ json: String,
        as type: (some Codable).Type,
        allowingExplicitNulls allowed: Set<String>? = nil
    ) -> ContractGateFailure? {
        do {
            _ = try StrictDecodeVerifier.verify(
                name: name,
                json: Data(json.utf8),
                as: type,
                allowingExplicitNulls: allowed
            )
            return nil
        } catch let failure as ContractGateFailure {
            return failure
        } catch {
            XCTFail("expected a ContractGateFailure, got \(error)")
            return nil
        }
    }
}

// MARK: - Deliberately-broken DTOs

//
// ⚠️ THESE LIVE IN THE TEST TARGET, NEVER IN Sources/. A broken DTO in the model
// module would be reachable by feature code and would count against the coverage
// floors; here it is exactly what it looks like — a fixture for the gate itself.

private struct SimpleMember: Codable {
    let email: String
    let role: String
}

private struct SimpleRoster: Codable {
    let success: Bool
    let members: [SimpleMember]
}

private struct NullableMember: Codable {
    let email: String
    let role: String?
}

private struct NullableRoster: Codable {
    let success: Bool
    let members: [NullableMember]
}

/// Decodes `name`, encodes `title`. The classic CodingKeys typo.
private struct RenamingOnEncode: Codable {
    let name: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DecodeKeys.self)
        name = try container.decode(String.self, forKey: .name)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: EncodeKeys.self)
        try container.encode(name, forKey: .title)
    }

    private enum DecodeKeys: String, CodingKey { case name }
    private enum EncodeKeys: String, CodingKey { case title }
}

/// Emits a field the server never sent — what a non-Optional property with a
/// client-side default does.
private struct InventingOnEncode: Codable {
    let success: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        success = try container.decode(Bool.self, forKey: .success)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(success, forKey: .success)
        try container.encode(1, forKey: .clientOnlyField)
    }

    private enum Keys: String, CodingKey {
        case success
        case clientOnlyField
    }
}

/// Reads an array, writes a joined string.
private struct ArrayToStringOnEncode: Codable {
    let tags: [String]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        tags = try container.decode([String].self, forKey: .tags)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(tags.joined(separator: ","), forKey: .tags)
    }

    private enum Keys: String, CodingKey { case tags }
}

/// Silently filters a row on the way out.
private struct DroppingElementOnEncode: Codable {
    let items: [String]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        items = try container.decode([String].self, forKey: .items)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Array(items.dropLast()), forKey: .items)
    }

    private enum Keys: String, CodingKey { case items }
}
