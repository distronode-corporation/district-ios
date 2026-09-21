import Foundation

/// The single normalised error type every District API call resolves to.
///
/// ⚠️ The server answers errors in THREE different envelope shapes
/// (`{success:false,error}`, `{error}`, `{error,code}`). Normalising them into
/// one type is a real piece of behaviour with its own tests; this enum is the
/// destination that work decodes into.
public enum ApiError: Error, Equatable, Sendable {
    /// The request reached the server and it answered with a non-2xx status.
    /// `message` is whatever the envelope carried, already unwrapped.
    case http(status: Int, message: String?)
    /// The request never produced a response (DNS, TLS, timeout, offline).
    case transport(String)
    /// A 2xx response whose body did not match the declared contract.
    case decoding(String)

    /// A human-readable reason suitable for a UI surface.
    ///
    /// ⚠️ Deliberately does NOT invent copy for the `http` case when the server
    /// sent no message. A caller that needs a fallback string owns that choice;
    /// inventing one here would make a contract regression look like a normal
    /// error to every screen.
    public var message: String? {
        switch self {
        case let .http(_, message):
            message
        case let .transport(reason):
            reason
        case let .decoding(reason):
            reason
        }
    }

    /// The HTTP status, when there was one.
    public var httpStatus: Int? {
        guard case let .http(status, _) = self else { return nil }
        return status
    }

    /// Whether the failure is an authentication failure the token refresh
    /// coordinator should react to. 403 is deliberately excluded: it means
    /// "authenticated but not permitted", and refreshing a token cannot fix it.
    public var isUnauthorized: Bool {
        httpStatus == 401
    }
}
