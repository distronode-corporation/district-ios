/// The HQ voice tokens in flight, so a sign-out can wait for each to be given back
/// (``HQVoiceSession/abandon()``, #116).
///
/// ⚠️ A COUNT, NOT A FLAG: a session abandoned while minting can start again before the first
/// token arrives, and the wait ends only when both have been shown, refused or given back.
@MainActor
final class HQVoiceMints {
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// A token request went out.
    func begin() {
        inFlight += 1
    }

    /// A token request finished, its discard included.
    func finish() {
        inFlight -= 1
        guard inFlight == 0 else { return }
        let resumed = waiters
        waiters = []
        resumed.forEach { $0.resume() }
    }

    /// Returns once no token request is in flight.
    func settled() async {
        guard inFlight > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
