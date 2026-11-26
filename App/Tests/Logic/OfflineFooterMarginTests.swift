@testable import DistrictAI
import DistrictL10n
import SwiftUI
import Testing

/// The two strips the lists draw around their rows, read back the way VoiceOver reads them
/// (``HostedAccessibility``): ``OfflineBanner`` while a saved copy is on screen and never
/// otherwise, and ``PagedFeedFooter``'s spinner, its append failure with a retry, and its
/// nothing at all between windows.
///
/// ⚠️ EVERY "NOTHING IS DRAWN" READING WAITS FOR A CONTROL LINE FIRST, so a window that was
/// never laid out cannot pass as an empty strip.
@MainActor
@Suite(.serialized)
struct OfflineFooterMarginTests {
    private static let control = "Rows above"

    private func hosted(_ strip: some View) throws -> HostedAccessibility {
        try HostedAccessibility(VStack {
            Text(Self.control)
            strip
        })
    }

    // MARK: - The offline banner

    @Test
    func `a saved copy on screen shows the banner naming when it was saved`() async throws {
        L10nRuntime.locale = .en
        let status = OfflineStatus()
        let savedAt = Date()
        status.servedSaved(path: "/api/district/calls", savedAt: savedAt)
        let screen = try hosted(OfflineBanner(status: status))
        defer { screen.close() }

        let shown = await screen.elements { $0.identified(A11yID.Offline.banner) != nil }

        let banner = try #require(shown.identified(A11yID.Offline.banner))
        #expect(banner.label == OfflineBanner.text(savedAt: savedAt))
        #expect(banner.label.hasPrefix("Offline. Showing what was saved at "), "on screen: \(shown)")
    }

    @Test
    func `every screen live again draws no banner`() async throws {
        let status = OfflineStatus()
        status.servedSaved(path: "/api/district/calls", savedAt: Date())
        status.servedLive(path: "/api/district/calls")
        let screen = try hosted(OfflineBanner(status: status))
        defer { screen.close() }

        let shown = await screen.elements { $0.labels.contains(Self.control) }

        #expect(shown.identified(A11yID.Offline.banner) == nil, "on screen: \(shown)")
        #expect(!shown.labels.contains { $0.hasPrefix("Offline.") }, "on screen: \(shown)")
    }

    // MARK: - The paged footer

    @Test
    func `a failed append says so with the reason and a retry`() async throws {
        L10nRuntime.locale = .en
        let failure = FailureText(message: "The service did not answer.", action: .none)
        let screen = try hosted(PagedFeedFooter(appending: false, appendFailure: failure, onRetry: {}))
        defer { screen.close() }

        let shown = await screen.elements { $0.labels.contains(CommonCopy.tryAgain) }

        #expect(shown.labels.contains(CommonCopy.couldNotLoadMore), "on screen: \(shown)")
        #expect(shown.labels.contains("The service did not answer."), "on screen: \(shown)")
        #expect(shown.labels.contains(CommonCopy.tryAgain), "on screen: \(shown)")
    }

    /// ⚠️ A WINDOW IN FLIGHT WINS OVER THE LAST FAILURE: the retry is already under way, so
    /// offering it again would ask for the same window twice.
    @Test
    func `a window in flight hides the last failure`() async throws {
        let failure = FailureText(message: "The service did not answer.", action: .none)
        let screen = try hosted(PagedFeedFooter(appending: true, appendFailure: failure, onRetry: {}))
        defer { screen.close() }

        let shown = await screen.elements { $0.labels.contains(Self.control) }

        #expect(!shown.labels.contains(CommonCopy.couldNotLoadMore), "on screen: \(shown)")
        #expect(!shown.labels.contains("The service did not answer."), "on screen: \(shown)")
        #expect(!shown.labels.contains(CommonCopy.tryAgain), "on screen: \(shown)")
    }

    @Test
    func `between windows the footer draws nothing`() async throws {
        let screen = try hosted(PagedFeedFooter(appending: false, appendFailure: nil, onRetry: {}))
        defer { screen.close() }

        let shown = await screen.elements { $0.labels.contains(Self.control) }

        #expect(shown.labels.filter { !$0.isEmpty } == [Self.control], "on screen: \(shown)")
    }
}
