import Foundation

/// The two values `GET /dashboard/handoff/start` sends back to this app, through its
/// own URL scheme: `districtai://handoff?state=<S>&nonce=<N>`.
///
/// ⛔ THE NONCE BINDS A HAND-OFF CODE TO ONE BROWSER, AND THAT IS THE WHOLE POINT. A
/// code that signs in whichever browser opens it is a login CSRF: one minted for an
/// attacker's account and sent to a signed-out victim signs the victim in as the
/// attacker. Leg 1 sets a nonce cookie in the browser this app opened and hands the
/// same nonce to the app; leg 2 mints the code bound to it; leg 3 redeems it only in a
/// browser holding the cookie.
///
/// ⛔ NEITHER VALUE IS EVER LOGGED OR SENT TO A CRASH REPORT. The nonce is half of a
/// sign-in and the state is what makes a callback ours; both live in memory for the
/// seconds a hand-off takes and nowhere else. See ``SchedulingHandoffCallback``.
public struct SchedulingHandoffCallbackValues: Equatable, Sendable {
    public let state: String
    public let nonce: String

    public init(state: String, nonce: String) {
        self.state = state
        self.nonce = nonce
    }
}

/// Recognising and reading the `districtai://handoff` callback.
///
/// ⛔ A DIFFERENT HOST FROM `districtai://auth`, AND THE TWO MUST NEVER BE CONFUSED.
/// The sign-in callback is intercepted in-session by `ASWebAuthenticationSession`
/// and never reaches the scene; this one arrives through the scene's URL routing,
/// because leg 1 runs in `SFSafariViewController` (it has to: legs 1 and 3 must
/// share one cookie jar). Only `handoff` is answered here; every other host is
/// "not ours" and is left alone.
///
/// ⚠️ ANY APP ON THE DEVICE CAN REGISTER `districtai://`, which is why the `state`
/// this app generated has to come back unchanged before the nonce is spent. That
/// check lives with the pending hand-off (`SchedulingHandoffFlow`), not here; this
/// type only says whether the URL is the right shape to ask the question at all.
public enum SchedulingHandoffCallback {
    public static let scheme = "districtai"
    public static let host = "handoff"

    /// Whether the URL is addressed to the hand-off callback, whatever it carries.
    ///
    /// ⚠️ SEPARATE FROM ``values(in:)`` ON PURPOSE. A malformed callback is still a
    /// callback: it is consumed and dropped rather than offered to the link resolver,
    /// which would otherwise be the next thing to look at it.
    public static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    /// The state and nonce, or nil for anything that is not a well-formed callback.
    ///
    /// ⛔ EACH NAME EXACTLY ONCE. Two `state` items would leave "which one did the
    /// server mean" to the order a parser happens to keep, so the URL is refused
    /// instead. Unknown names are ignored, so the server can add one without
    /// breaking a shipped build.
    public static func values(in url: URL) -> SchedulingHandoffCallbackValues? {
        guard isCallback(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = items.filter { $0.name == "state" }.compactMap(\.value)
        let nonces = items.filter { $0.name == "nonce" }.compactMap(\.value)
        guard states.count == 1, nonces.count == 1 else { return nil }
        guard isValidState(states[0]), isValidNonce(nonces[0]) else { return nil }
        return SchedulingHandoffCallbackValues(state: states[0], nonce: nonces[0])
    }

    /// The server's rule for `state`: 16 to 256 characters of `[A-Za-z0-9._~-]`.
    ///
    /// ⚠️ THE RFC 3986 UNRESERVED SET, so a valid state travels through a query
    /// string without any escaping in either direction and comes back byte for byte.
    public static func isValidState(_ state: String) -> Bool {
        (16 ... 256).contains(state.utf8.count) && state.utf8.allSatisfy(isUnreserved)
    }

    /// The server's rule for a nonce: exactly 43 base64url characters (32 bytes,
    /// unpadded).
    ///
    /// ⛔ CHECKED HERE SO A MALFORMED ONE NEVER REACHES A REQUEST BODY. The server
    /// would answer 400 `invalid_nonce`; dropping the callback instead leaves the
    /// hand-off to fall back the way any missing callback does.
    public static func isValidNonce(_ nonce: String) -> Bool {
        nonce.utf8.count == 43 && nonce.utf8.allSatisfy(isBase64URL)
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        isBase64URL(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "~")
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"):
            true
        default:
            false
        }
    }
}
