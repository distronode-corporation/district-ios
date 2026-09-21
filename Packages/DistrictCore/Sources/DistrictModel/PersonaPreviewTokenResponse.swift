import Foundation

/// `POST /api/district/workspace/persona/preview-token` — the credential for one
/// persona audition.
///
/// ⛔ A REAL, BILLED CALL AND NOT A DRY RUN. The token invites the voice agent into
/// a `preview_<workspaceId>_<uuid>` room on the workspace's own pipeline and its
/// own media node, where it answers with STT, an LLM and TTS exactly as it would on
/// a telephone call. The route is capped at **10/min per workspace** and is not
/// idempotent; nothing in this client may retry it.
///
/// ⛔ ``url`` IS THE SERVER'S CHOICE OF MEDIA NODE AND IS USED VERBATIM, for the
/// reason ``RoomTokenResponse/url`` states at length: the room exists only on the
/// deployment that created it, and a URL derived from the workspace's region — or
/// from a constant — joins a bus that has never heard of the room. Here it is
/// derived from the WORKSPACE's region server-side, precisely so an EU customer is
/// not auditioning their agent through the US node.
///
/// ⛔ THE TOKEN LASTS 30 MINUTES AND THAT IS NOT A SESSION LIMIT. It authorises the
/// JOIN; an established connection is not re-checked against it. A rejoin after it
/// expires needs a fresh one, which is a fresh rate-limit slot and a fresh billed
/// session.
///
/// ⚠️ THE SEAT IS PUBLISH-CAPABLE BY DESIGN (`canPublish`, `canSubscribe`,
/// `canPublishData`): the whole point is to speak to the agent and hear it answer.
/// There is no viewer variant of this route, so unlike `calls/token` there is no
/// second body shape to gate.
public struct PersonaPreviewTokenResponse: Codable, Sendable, Equatable {
    public let success: Bool
    /// ⚠️ 30 minutes. See the type note.
    public let token: String
    /// ⛔ Used verbatim. See the type note.
    public let url: String
    /// ⛔ `preview_<workspaceId>_<uuid>`, MINTED SERVER-SIDE AND NEVER REBUILT. The
    /// agent branches on the `preview_` prefix to read the persona out of the token
    /// metadata instead of the stored row, so a name a client invented would be
    /// answered by the SAVED persona — the opposite of what the screen promises.
    public let roomName: String
    /// The room's shared encryption passphrase.
    ///
    /// ⛔ HANDED TO THE MEDIA SDK VERBATIM AND NEVER BASE64-DECODED. It arrives as
    /// the base64 TEXT of 32 random bytes and it is tempting to read "base64" as an
    /// instruction: every LiveKit SDK UTF-8-encodes this string and runs PBKDF2
    /// over those ASCII bytes, so decoding to raw bytes selects a different
    /// derivation and a different AES key. The failure mode is not an error — both
    /// sides join, both publish, and every track is undecryptable noise. The voice
    /// agent is bound by the same rule (`district-voice-agent/src/e2ee.py`). The
    /// type is shared with ``RoomTokenResponse``, which carries the argument in
    /// full.
    ///
    /// ⛔ OPTIONAL IN SWIFT AND PRESENT ON EVERY PREVIEW IN PRACTICE, and the
    /// Optional is a refusal to crash rather than a documented second shape: a
    /// `preview_*` room is always encrypted (browser-to-agent, no SIP leg, no
    /// avatar). ⚠️ So an ABSENT key here is not "join unencrypted" the way it is on
    /// `calls/token` — it is the server failing to derive one, and a client that
    /// joined anyway would be the only unencrypted participant in a room everyone
    /// else encrypted, hearing and publishing noise.
    public let e2ee: E2EEInfo?
}
