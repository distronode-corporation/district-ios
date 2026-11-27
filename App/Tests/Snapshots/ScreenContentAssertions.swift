@testable import DistrictAI
import DistrictL10n
import SwiftUI
import XCTest

/// For the screens CI's simulator draws blank: assert what VoiceOver reads instead of an image.
///
/// ⚠️ CI's macos-26 runner draws some screens as an empty frame whichever renderer is used
/// (the setup wizard's callers, calls and go-live steps; run 45871312893), although the same drawings
/// are complete on a Mac's simulator. A blank reference would compare nothing, so these
/// screens are checked by the words and controls they put in the accessibility tree
/// (``HostedAccessibility``), in English and French, over the same recorded responses.
extension ScreenSnapshotTestCase {
    /// Builds the screen `make` returns over a container answering `replies`, then fails unless
    /// every string `expected` gives for the language is part of some element's label.
    func assertScreenContent(
        _ replies: [String: FixtureTransport.Reply] = [:],
        locales: [L10nLocale] = [.en, .frCA],
        expected: (L10nLocale) -> [String],
        file: StaticString = #filePath,
        line: UInt = #line,
        screen make: @escaping (AppContainer) -> some View
    ) async throws {
        for locale in locales {
            L10nRuntime.locale = locale
            let container = try await container(FixtureTransport(replies))
            let screen = try HostedAccessibility(NavigationStack { make(container) })
            let wanted = expected(locale)
            var labels: [String] = []
            for _ in 0 ..< 250 {
                labels = screen.elements().map(\.label)
                if wanted.allSatisfy({ word in labels.contains { $0.contains(word) } }) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            for word in wanted where !labels.contains(where: { $0.contains(word) }) {
                XCTFail("\(locale): '\(word)' is not on screen; read: \(labels)", file: file, line: line)
            }
            screen.close()
        }
    }
}
