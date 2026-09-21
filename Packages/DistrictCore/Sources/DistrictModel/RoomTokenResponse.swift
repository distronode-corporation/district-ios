import Foundation

/// `POST /api/district/calls/token` for a `meet_` room.
///
/// ⛔ THE PATH SAYS "calls" AND THE THING IT ANSWERS FOR HERE IS A ROOM. That
/// route serves two unrelated cases behind one body: when `roomName` starts with
/// `meet_` or `video_` it is a standalone room name, otherwise it is a `Call.id`
/// and the caller is a supervisor joining someone else's live phone call. The
/// name is historical; what matters to this client is that only the first case
/// is reachable from it.
///
/// ⛔ ``url`` IS THE SERVER'S CHOICE OF MEDIA NODE AND MUST BE USED VERBATIM. The
/// room only exists on the deployment that created it, so a client that derived
/// a URL from the workspace's region — or from a constant — would join a bus
/// that has never heard of the room. For a standalone room the two answers agree
/// today; for a call room they do not, because the SIP bridge and the outbound
/// trunks exist only on the US deployment, so an EU workspace's phone call lives
/// in a US room. Treating this field as advisory is how that becomes a silent
/// failure rather than an error.
///
/// ⛔ ``guestInvite`` AND ``guestPath`` ARE ABSENT, NOT NULL, FOR A VIEWER — and
/// their absence is a SECURITY decision rather than a shape quirk.
/// `/api/meet/token` grants publish rights to whoever presents a valid invite,
/// and an invite is a transferable twelve-hour capability, so minting one for a
/// read-only seat would hand it a publish-capable route into the room it had
/// just been refused, and let it admit unauthenticated outsiders with publish
/// rights too. The route spreads the two keys in only for a non-viewer.
/// `district-room-token.json` and `district-room-token-viewer.json` pin both
/// branches, which is required rather than thorough: the strict gate compares
/// key sets per fixture, so a DTO proven against one branch is proven against
/// half the responses this route produces.
public struct RoomTokenResponse: Codable, Sendable {
    public let success: Bool
    /// The LiveKit access token, ~30 minutes.
    ///
    /// ⚠️ SHORT-LIVED BY DESIGN (`TOKEN_TTL = "30m"`), which is shorter than a
    /// long meeting. It authorises the JOIN; an established connection is not
    /// re-checked against it, so this is not a meeting length limit — but a
    /// rejoin after it expires needs a fresh one.
    public let token: String
    /// ⛔ Used verbatim. See the type note.
    public let url: String
    /// The room's end-to-end encryption key, present only for a room that HAS one.
    ///
    /// ⛔ ABSENT IS A REAL ANSWER AND MEANS "JOIN UNENCRYPTED", NOT "SOMETHING WENT
    /// WRONG". This route serves two room families (see the type note) and only the
    /// `meet_` one is encrypted: a `call_` supervisor join has a SIP leg in it, and a
    /// carrier delivers a telephone call unencrypted, so there is nothing an app-side
    /// key could protect there. A client that treated the absence as an error would
    /// refuse to join exactly the rooms that work today.
    ///
    /// ⚠️ Encryption is a property of the ROOM, not of the seat, so a viewer receives
    /// the same key as a publisher — unlike ``guestInvite``/``guestPath``, which really
    /// are role-dependent. It is not a capability: holding it grants no publish rights,
    /// and the LiveKit token still decides what the holder may do.
    public let e2ee: E2EEInfo?
    public let guestInvite: GuestInvite?
    /// The path half of a shareable guest link, already URL-encoded and carrying
    /// `?e=` and `?s=`.
    ///
    /// ⛔ ASSEMBLED SERVER-SIDE AND NEVER BY A CLIENT. It binds the signature to
    /// the exact room name, and a client that rebuilt it from ``guestInvite``
    /// would be reimplementing the encoding the signature was computed over.
    /// Join it onto the app's own origin and share that.
    public let guestPath: String?
}

/// A signed, expiring capability that lets an unauthenticated guest join one
/// specific room.
///
/// ⚠️ MEETING ROOM NAMES ARE LOW ENTROPY — human-typed and restricted to
/// `[a-zA-Z0-9-]` — so "knowing the room name" was never an acceptable
/// authorization boundary. This is what replaces it. Nothing here is secret to
/// the person holding the link; it is secret from everyone else, and it expires.
/// The shared symmetric key for one end-to-end encrypted room.
///
/// ⛔ ``key`` IS A PASSPHRASE AND IS HANDED TO THE MEDIA SDK VERBATIM. IT MUST NEVER BE
/// BASE64-DECODED. It arrives as the base64 text of 32 random bytes, and it is tempting
/// to read "base64" as an instruction — it is not. Every LiveKit SDK UTF-8-encodes this
/// string and runs PBKDF2 over those ASCII bytes (salt `LKFrameEncryptionKey`) to derive
/// the AES-GCM key. Decoding to 32 raw bytes on one platform selects a DIFFERENT
/// derivation (HKDF) and therefore a different AES key — and the failure mode is not an
/// error. Both sides join, both sides publish, and every track is undecryptable noise.
/// The Android client, the web client and the voice agent are bound by the same rule and
/// pass the same string.
///
/// ⛔ `RoomEngine` takes the key and hands it to LiveKit's E2EE options unmodified,
/// exactly as on Android. `DistrictCore` still may
/// import only Foundation, FoundationNetworking and swift-crypto — the engine lives in
/// the App target, which is why the DTO stays here and the consumer does not.
///
/// ⚠️ The DTO would earn its place regardless: the strict contract gate compares key
/// sets, so a field the server sends and this type does not model reds CI.
/// ⚠️ `Equatable` SINCE THE PERSONA BATCH, AND IT IS THE CONFORMANCE RATHER THAN
/// THE TYPE THAT CHANGED. ``PersonaPreviewTokenResponse`` embeds this and is
/// `Equatable` so a repository test can compare a whole decoded credential in one
/// assertion; a synthesised conformance cannot reach through a member that lacks
/// one. ⛔ It compares the PASSPHRASE, which is fine in a test and must never become
/// a reason to log or diff one.
public struct E2EEInfo: Codable, Sendable, Equatable {
    /// ⛔ The base64 TEXT of 32 bytes — 44 characters — used as a passphrase, not decoded.
    public let key: String
}

public struct GuestInvite: Codable, Sendable {
    /// Unix **seconds**, unlike `expiresAt` elsewhere on this API, which is
    /// milliseconds. The server mints twelve hours; a client only forwards it.
    public let exp: Int64
    /// base64url HMAC over the room name and ``exp``.
    public let sig: String
}
