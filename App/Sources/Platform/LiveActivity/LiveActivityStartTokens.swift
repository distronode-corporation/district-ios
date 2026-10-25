import DistrictData
import DistrictModel
import Foundation

/// Hands the server this device's push-to-start token. `CallsRepository.registerLiveActivityStartToken`
/// (district-core-swift 8.1.0) is the one conformance.
protocol LiveActivityStartTokenRegistering: Sendable {
    func registerLiveActivityStartToken(workspaceId: String, token: String) async -> Result<Void, ApiError>
}

extension CallsRepository: LiveActivityStartTokenRegistering {}

/// What was last sent, so a launch does not send the same token again.
struct LiveActivityStartTokenSent: Codable, Equatable {
    let token: String
    let workspaceId: String
    let sentAt: Date
}

/// Where ``LiveActivityStartTokens`` remembers what it sent.
protocol LiveActivityStartTokenMemory {
    func load() -> LiveActivityStartTokenSent?
    func save(_ sent: LiveActivityStartTokenSent?)
}

/// The device's Live Activity push-to-start token, sent to the server so a ring can start the
/// call's activity with no app running (Sean, 2026-10-25: "Add push-to-start").
///
/// ⛔ SENT ONLY WHILE SIGNED IN, FOR THE CURRENT WORKSPACE: after sign-in and on each launch
/// (``begin()``), when ActivityKit hands over a new token, and when the person switches
/// workspace (``workspaceChanged()``). A token already sent for the same workspace is sent
/// again only once it is ``staleAfter`` old, which keeps the server's 30-day entry alive.
///
/// ⛔ NEVER RETRIED. A failure is not remembered, so the next of those moments sends again; no
/// loop does. At sign-out (``stop()``) nothing more is sent and the memory is cleared, so the
/// next account sends its own; the server's entry expires on its own.
@MainActor
final class LiveActivityStartTokens {
    /// Sent again after this long, though nothing changed.
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    private let registrar: any LiveActivityStartTokenRegistering
    private let memory: any LiveActivityStartTokenMemory
    private let workspace: @MainActor () -> String?
    private let now: () -> Date
    private let observe: @MainActor (@escaping @MainActor (Data) -> Void) -> Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var latest: String?
    private var signedIn = false
    /// The token and workspace on the wire now, so two triggers send it once.
    private var sending: String?

    /// - Parameter observe: starts reading ActivityKit's push-to-start tokens, handing each to
    ///   the closure; nil where there are none (below iOS 18).
    init(
        registrar: any LiveActivityStartTokenRegistering,
        memory: any LiveActivityStartTokenMemory,
        workspace: @escaping @MainActor () -> String?,
        now: @escaping () -> Date = Date.init,
        observe: @escaping @MainActor (@escaping @MainActor (Data) -> Void) -> Task<Void, Never>?
    ) {
        self.registrar = registrar
        self.memory = memory
        self.workspace = workspace
        self.now = now
        self.observe = observe
    }

    /// Signed in (after sign-in, and at every launch that finds a session).
    func begin() {
        signedIn = true
        if observation == nil {
            observation = observe { [weak self] data in self?.received(data) }
        }
        sendIfNeeded()
    }

    /// The person switched workspace: the token now routes through that one.
    func workspaceChanged() {
        sendIfNeeded()
    }

    /// Sign-out: send nothing more, and forget what was sent.
    func stop() {
        signedIn = false
        memory.save(nil)
    }

    private func received(_ data: Data) {
        latest = CallLiveActivities.hex(data)
        sendIfNeeded()
    }

    private func sendIfNeeded() {
        guard signedIn, let token = latest, let workspaceId = workspace() else { return }
        let sent = memory.load()
        let fresh = sent.map { now().timeIntervalSince($0.sentAt) < Self.staleAfter } ?? false
        guard !fresh || sent?.token != token || sent?.workspaceId != workspaceId else { return }
        let key = workspaceId + ":" + token
        guard sending != key else { return }
        sending = key
        let registrar = registrar
        Task { [weak self] in
            let outcome = await registrar.registerLiveActivityStartToken(workspaceId: workspaceId, token: token)
            self?.finished(key, outcome, token: token, workspaceId: workspaceId)
        }
    }

    private func finished(_ key: String, _ outcome: Result<Void, ApiError>, token: String, workspaceId: String) {
        if sending == key {
            sending = nil
        }
        // ⚠️ A SIGN-OUT WHILE THE REQUEST WAS ON THE WIRE WINS: nothing is remembered for an
        // account that has left.
        guard case .success = outcome, signedIn else { return }
        memory.save(LiveActivityStartTokenSent(token: token, workspaceId: workspaceId, sentAt: now()))
    }
}

/// ``LiveActivityStartTokenMemory`` in `UserDefaults.standard`. ⚠️ A push token, not a
/// credential: like the alert and VoIP tokens (``UserDefaultsPushTokenMemory``).
struct UserDefaultsLiveActivityStartTokenMemory: LiveActivityStartTokenMemory {
    static let defaultsKey = "com.distronode.district.liveActivityStartToken"

    var defaults: UserDefaults = .standard

    func load() -> LiveActivityStartTokenSent? {
        defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(
            LiveActivityStartTokenSent.self,
            from: $0
        ) }
    }

    func save(_ sent: LiveActivityStartTokenSent?) {
        guard let sent, let data = try? JSONEncoder().encode(sent) else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
