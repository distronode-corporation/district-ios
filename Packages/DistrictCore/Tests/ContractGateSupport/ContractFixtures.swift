import Foundation

/// Where the committed contract fixtures live, and how to read one.
///
/// ⛔ THE FIXTURES LIVE OUTSIDE THIS PACKAGE, IN `contracts/` AT THE REPOSITORY
/// ROOT, AND THIS TYPE READS ACROSS FOLDERS TO REACH THEM. The corpus is
/// generated from the server's real handlers and copied in unchanged, so there
/// is exactly one copy of each wire shape, and the Android client checks the
/// same files.
///
/// ⛔ THE MITIGATION IS THAT ``allFixtureNames()`` THROWS RATHER THAN RETURNING
/// AN EMPTY ARRAY, AND IT IS THE WHOLE REASON THIS TYPE EXISTS SEPARATELY FROM
/// THE TEST THAT USES IT. A contract gate that silently verifies ZERO fixtures
/// is indistinguishable from one that passes: a skipped read must abort, never
/// fall through to a green result. If the path ever breaks (a moved directory,
/// a gitignore rule that swallows `*.json`, a checkout that never had the
/// fixtures), this goes RED.
///
/// The Android client's fixture loader has the same guard for the same reason.
public enum ContractFixtures {
    /// The environment variable that overrides the location.
    ///
    /// ⚠️ EXISTS FOR CONTAINERISED RUNS, where the repo root is not mounted and
    /// the `#filePath`-relative walk below therefore lands outside the mount.
    /// It mirrors the `district.contracts.dir` system property Gradle supplies
    /// on the Android side. It is not a way to make a failure go away: the
    /// count assertion in `ContractManifest` still has to hold, and every
    /// implemented fixture still has to decode, so pointing this at the wrong
    /// directory fails louder than leaving it unset.
    public static let overrideEnvironmentKey = "DISTRICT_CONTRACTS_DIR"

    /// The resolved fixture directory.
    ///
    /// ⚠️ DERIVED FROM `#filePath`, NOT FROM THE WORKING DIRECTORY.
    /// `swift test` can be invoked from the package directory, from the repo
    /// root, or from a CI job that has `cd`-ed somewhere else entirely, and a
    /// relative path would resolve differently in each. `#filePath` is baked in
    /// at compile time and is the only stable anchor available to a test.
    ///
    /// ⚠️ A BLANK OVERRIDE IS TREATED AS UNSET rather than as an empty path,
    /// because a CI variable that exists but was never populated is the common
    /// way this goes wrong and `URL(fileURLWithPath: "")` resolves to the working
    /// directory — which would look for the fixtures wherever `swift test`
    /// happened to be run from and find none.
    ///
    /// ⚠️ Written as one flat condition on purpose: a multi-line `if let` here is
    /// unsatisfiable across the two linters (SwiftFormat wraps the opening brace,
    /// SwiftLint's `opening_brace` refuses it), the same standoff the
    /// `trailing_comma` note in `.swiftlint.yml` documents.
    public static var directory: URL {
        let override = ProcessInfo.processInfo.environment[overrideEnvironmentKey] ?? ""
        if override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return defaultDirectory
        }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    /// `<repo>/contracts`, walked up from this source file.
    ///
    /// The five components removed are, innermost first: this file, its
    /// directory (`ContractGateSupport`), `Tests`, `DistrictCore` and
    /// `Packages`, which leaves the repository root. Adding a directory level
    /// between the package root and this file breaks the walk — which the guard
    /// turns into a red suite rather than a silent zero-fixture pass.
    private static var defaultDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("contracts", isDirectory: true)
    }

    /// Every `.json` fixture on disk, sorted, or a diagnosis of why there are
    /// none.
    ///
    /// ⛔ THROWS RATHER THAN RETURNING AN EMPTY ARRAY. "No fixtures" must never
    /// be a value a caller can accidentally treat as "nothing to check".
    public static func allFixtureNames() throws -> [String] {
        let dir = directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ContractFixturesUnavailable.missingDirectory(path: dir.path)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let names = entries.filter { $0.hasSuffix(".json") }.sorted()
        guard !names.isEmpty else {
            throw ContractFixturesUnavailable.emptyDirectory(path: dir.path)
        }
        return names
    }

    /// Read one fixture's bytes.
    public static func read(_ name: String) throws -> Data {
        let url = directory.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ContractFixturesUnavailable.missingFixture(name: name, path: url.path)
        }
        return data
    }
}

/// The three ways the fixture corpus can be unusable. Separate from
/// `ContractGateFailure` because none of these is a contract problem — they all
/// mean the gate could not run at all, which is a worse failure and needs a
/// different message.
public enum ContractFixturesUnavailable: Error, CustomStringConvertible, Equatable {
    case missingDirectory(path: String)
    case emptyDirectory(path: String)
    case missingFixture(name: String, path: String)

    public var description: String {
        switch self {
        case let .missingDirectory(path):
            """
            contract fixtures: DIRECTORY NOT FOUND at \(path).
              The fixtures live in contracts/ at the repository root, found by
              walking up from #filePath, unless \(ContractFixtures.overrideEnvironmentKey)
              names another directory. If it is set, the directory it names does
              not exist; unset it or point it at a copy of contracts/. If it is
              unset, the walk no longer lands on the repository root (a test
              directory moved), or this is a partial checkout.
            """
        case let .emptyDirectory(path):
            """
            contract fixtures: NO .json FILES in \(path).
              ⛔ This is a hard failure and never a skip. A gitignore rule that
              swallows *.json leaves CI with an empty directory, and every
              contract test would otherwise pass by verifying nothing.
            """
        case let .missingFixture(name, path):
            """
            contract fixtures: MISSING \(name) at \(path).
              The corpus is regenerated from the server's contract suite, run
              with CONTRACTS_UPDATE=1, never by hand.
            """
        }
    }
}
