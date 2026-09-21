import DistrictModel
import DistrictNetwork
import Foundation

/// The phone-number marketplace: what is for sale, what the workspace already has,
/// and everything that can be done to a number it holds.
///
/// ⛔ Release, configure, the whole regulatory-registration surface and the
/// carrier-account surfaces are ported, on the tested tier, with explicit
/// confirmations for the two irreversible ones. The one thing deliberately absent is
/// the purchase:
///
/// ⛔ **THERE IS NO PURCHASE METHOD AND THERE MUST NOT BE.**
/// `workspace/numbers/purchase` charges a setup fee AND opens a recurring monthly
/// charge for a service consumed inside the app, which is App Store Review Guideline
/// 3.1.1 — an in-app purchase or nothing at all. It has no ``EndpointID`` case, no
/// path constant and no descriptor, so `ApiClient` could not be handed a request for
/// it even by a caller inside this module. `EndpointSurfaceTests` pins that.
/// ⛔ 3.1.1 COVERS STEERING, so no method here returns a URL to the web marketplace
/// either, and none may be added. ``MarketplaceCopy/readOnly`` names the site in prose
/// and offers nothing to tap.
///
/// ⛔ TWO UNRELATED ROUTES BEHIND ONE SCREEN, AND THEY FAIL FOR DIFFERENT
/// REASONS. ``search(workspaceId:areaCode:country:type:provider:)`` hits the
/// carrier's inventory API; ``owned(workspaceId:)`` merges the tenant's carrier
/// account with the platform's hub records. They are two methods rather than one
/// combined read for the reason ``AnalyticsRepository`` keeps its two apart:
/// folding them into a single result means either failure blanking a half of the
/// screen that was answered correctly.
///
/// ⚠️ NO CACHING. Carrier inventory changes minute to minute, and an
/// owned-number list an operator is reading as current must be current. A stale
/// marketplace is worse than a second request.
///
/// ⚠️ THE PROVISIONING AND CARRIER-ACCOUNT METHODS ARE IN
/// `NumbersRepository+Provisioning.swift` AND `NumbersRepository+Carrier.swift`, which
/// is SwiftLint's 500-line `file_length` rather than a second repository: they are
/// extensions on this type, so there is exactly one ``NumbersRepository`` and one
/// place it is wired from (``AppContainer/numbers``). The cut follows
/// `DistrictEndpoints`' own per-family split.
public struct NumbersRepository: Sendable {
    /// ⚠️ INTERNAL RATHER THAN `private`, AND THE ONE REASON IS THE SIBLING FILES.
    /// `private` is FILE scope in Swift, so an extension declared in
    /// `NumbersRepository+Provisioning.swift` could not reach it — and the alternative
    /// is a second repository type over the same routes. Still module-internal, so nothing outside
    /// `DistrictData` can borrow the client.
    let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Search available inventory.
    ///
    /// ⛔ A WORKSPACE WITH NO CARRIER CONNECTED ANSWERS **400**, AND THAT IS NOT
    /// AN ERROR TO ALARM ABOUT. It passes through as an ``ApiError`` carrying
    /// the server's own sentence ("Messaging provider not configured for
    /// workspace") rather than being translated here, because the layer that
    /// knows how to render it as an empty state is the UI. ⛔ What this layer
    /// must not do is convert it into an empty success: a client that did would
    /// tell an operator the carrier has no numbers in their area code, which is
    /// a claim about inventory that was never looked at.
    ///
    /// ⚠️ BLANK FILTERS ARE NORMALISED TO ABSENT. The server distinguishes an
    /// omitted parameter from an empty one, and an empty `areaCode` would reach
    /// the carrier as a literal filter. ``ApiQueryItem`` already drops a nil, so
    /// the blank-to-nil step is the only one this layer has to make.
    ///
    /// ⚠️ ENVELOPE FIRST. Every field of the response would survive a `{}` body
    /// except the two required ones, and the answer a caller would act on from a
    /// half-decoded search is "no numbers available" — the exact answer that
    /// sends someone off to try a different area code.
    public func search(
        workspaceId: String,
        areaCode: String? = nil,
        country: String? = nil,
        type: String? = nil,
        provider: String? = nil
    ) async -> Result<NumberSearchResponse, ApiError> {
        let descriptor = DistrictEndpoints.searchNumbers(
            workspaceId: workspaceId,
            areaCode: Self.normalised(areaCode),
            country: Self.normalised(country),
            type: Self.normalised(type),
            provider: Self.normalised(provider)
        )
        let outcome = await client.send(descriptor, as: NumberSearchResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("NumberSearchResponse", response.success, response)
        }
    }

    /// The workspace's own numbers, managed and BYOK together.
    ///
    /// ⛔ THE `partial` FLAG IS CARRIED THROUGH INSIDE THE SUCCESS RATHER THAN
    /// CONVERTED INTO A FAILURE. "One carrier did not answer, here is the rest"
    /// is a different fact from both "here is everything" and "we could not
    /// look", and only the caller can render the middle one — a short list plus
    /// a banner naming the carrier. Collapsing it either way loses information
    /// the operator needs: upward, it hides real inventory behind an error;
    /// downward, it draws an incomplete list as a complete one. See
    /// ``OwnedNumbersResponse/failedProviderNames``.
    public func owned(workspaceId: String) async -> Result<OwnedNumbersResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.ownedNumbers(workspaceId: workspaceId),
            as: OwnedNumbersResponse.self
        )
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("OwnedNumbersResponse", response.success, response)
        }
    }

    /// A blank filter is the same as no filter. See ``search``.
    private static func normalised(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
