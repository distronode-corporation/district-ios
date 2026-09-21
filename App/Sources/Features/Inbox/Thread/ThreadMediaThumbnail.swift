import SwiftUI

/// One attachment, drawn as a thumbnail.
///
/// ⛔ `AsyncImage` GOES THROUGH `URLSession.shared` AND THEREFORE CARRIES NO BEARER
/// TOKEN, WHICH IS EXACTLY RIGHT HERE. `/api/media/<uuid>` is an ANONYMOUS capability
/// URL — it must be, because a carrier's MMS fetcher has no session either — so
/// attaching this client's access token would send a credential to a route that never
/// asked for one.
///
/// ⛔ THREE STATES, AND "unavailable" IS NOT ALLOWED TO LOOK LIKE "loading". A
/// permanent shimmer for an image that will never arrive is the worst of the three
/// outcomes: the operator waits for something that is not coming.
struct ThreadMediaThumbnail: View {
    let url: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                caption("Image unavailable")
            case .empty:
                caption("Loading image")
            @unknown default:
                caption("Image unavailable")
            }
        }
        // ⛔ `minHeight`, BECAUSE THIS BOX HOLDS TEXT IN TWO OF ITS FOUR STATES.
        // A successful image is 96x96; a failure or a load shows `caption("Image
        // unavailable")` / `("Loading image")`, and at an accessibility size that
        // sentence is taller than 96pt and was clipped to nothing. The WIDTH stays
        // fixed so the thumbnail column keeps its rhythm.
        .frame(width: 96)
        .frame(minHeight: 96)
        .background(colors.muted)
        .clipShape(RoundedRectangle(cornerRadius: DistrictRadius.control))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
            .multilineTextAlignment(.center)
            .padding(DistrictSpacing.hairline)
    }
}
