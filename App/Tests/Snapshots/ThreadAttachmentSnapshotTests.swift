@testable import DistrictAI
import SwiftUI
import XCTest

/// A received attachment in each way it can land, over a fetch the test answers, so the
/// drawing does not depend on a network.
final class ThreadAttachmentSnapshotTests: ScreenSnapshotTestCase {
    private static let media = "https://media.contract.test/roof.jpg"

    private static func answer(_ status: Int, _ type: String?, _ body: Data) -> ReceivedAttachmentLoader.Fetch {
        { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: status,
                      httpVersion: "HTTP/1.1",
                      headerFields: type.map { ["Content-Type": $0] } ?? [:]
                  )
            else { throw URLError(.badURL) }
            return (body, response as URLResponse)
        }
    }

    private static let failing: ReceivedAttachmentLoader.Fetch = { _ in throw URLError(.notConnectedToInternet) }

    /// An image drawn; a PDF offered as a file tile; a 401, an unreachable host and a non-web
    /// address each said as "can't be opened".
    func testReceivedAttachmentStates() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                HStack(spacing: DistrictSpacing.tight) {
                    ReceivedAttachmentView(url: Self.media, fetch: Self.answer(200, "image/png", ScopeMedia.png))
                    ReceivedAttachmentView(url: Self.media, fetch: Self.answer(200, "application/pdf", ScopeMedia.pdf))
                    ReceivedAttachmentView(
                        url: Self.media,
                        fetch: Self.answer(200, "application/x-fixture-unknown", Data([7, 7, 7]))
                    )
                }
                HStack(spacing: DistrictSpacing.tight) {
                    ReceivedAttachmentView(url: Self.media, fetch: Self.answer(401, "text/plain", Data("no".utf8)))
                    ReceivedAttachmentView(url: Self.media, fetch: Self.failing)
                    ReceivedAttachmentView(url: "ftp://media.contract.test/roof.jpg", fetch: Self.failing)
                }
                Spacer(minLength: 0)
            }
            .padding(DistrictSpacing.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
