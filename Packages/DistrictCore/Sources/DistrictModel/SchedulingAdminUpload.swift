import Foundation

/// What `POST /api/district/scheduling/admin/upload` answers.
///
/// ⛔ ONE KEY, AND **WHICH** KEY DEPENDS ON THE `target` THAT WAS SENT. The route
/// holds a per-target `urlKey` — `logo` ⇒ `logo_url`, `banner` ⇒ `banner_url`,
/// `avatar` ⇒ `avatar_url` — reads only that one field out of the fork's answer,
/// and emits `{ok:true, data:{<urlKey>: …}}`. So this is not a body with three
/// optional fields in the ordinary sense: exactly one arrives, and the other two
/// are ABSENT rather than null. Modelling it as three Optionals is what lets one
/// type cover all three uploads while still round-tripping each body key-for-key
/// through the strict gate, which a single `url` field could not do — the gate
/// compares key NAMES, and `url` would be an added key on every body.
///
/// ⚠️ IT WEARS THE RPC'S ENVELOPE WITHOUT BEING AN RPC OP. This route is not in
/// `admin-ops.ts` at all — an image cannot travel through a zod-validated params
/// object — yet it answers `{ok:true,data}` on success and `{ok:false, failure,
/// status}` at HTTP **200** when the scheduler refuses, deliberately matching the
/// catalog route so both surfaces have one failure vocabulary. A client that read
/// `res.ok` alone would report a rejected image as a successful upload.
///
/// ⛔ `""` IS A REACHABLE VALUE AND IT MEANS "UPLOADED, ADDRESS UNREADABLE". The
/// route writes `typeof url === "string" ? url : ""`, so a fork that answered 2xx
/// with a shape it did not recognise yields an empty string rather than an error.
/// Treat emptiness as "re-read the branding settings", never as a URL to load.
public struct SchedulingUploadResult: Codable, Equatable, Sendable {
    /// Present only for `target=logo`.
    public let logoUrl: String?
    /// Present only for `target=banner`.
    public let bannerUrl: String?
    /// Present only for `target=avatar`.
    public let avatarUrl: String?

    /// The one URL that arrived, whichever key carried it.
    ///
    /// ⚠️ A CONVENIENCE FOR THE CALLER THAT ALREADY KNOWS WHICH TARGET IT SENT,
    /// not a way to avoid knowing. It reads the keys in target order and answers
    /// the first that arrived; a body carrying none — which the route does not
    /// send — answers nil rather than `""`, so "the server said nothing" stays
    /// distinguishable from "the server said the address is unknown".
    public var publishedUrl: String? {
        logoUrl ?? bannerUrl ?? avatarUrl
    }

    enum CodingKeys: String, CodingKey {
        case logoUrl = "logo_url"
        case bannerUrl = "banner_url"
        case avatarUrl = "avatar_url"
    }
}
