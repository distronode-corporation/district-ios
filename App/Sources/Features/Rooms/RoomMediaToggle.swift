/// One meeting media control (the microphone or the camera): its state, whether a
/// change is in flight, and whether the last one was refused.
///
/// ⛔ SINGLE-FLIGHT, BECAUSE THE TARGET IS COMPUTED BEFORE THE AWAIT. Two quick taps
/// on "Start video" then "Stop video" each read `isOn == false` and both ask for ON,
/// so the camera stays published while the operator believes it is off. While a
/// change is in flight ``begin()`` refuses, and ``ActiveRoomView`` disables the
/// control on ``inFlight``.
///
/// ⛔ A REFUSAL IS SAID OUT LOUD, LIKE ``ActiveRoomModel/flipFailed``. `RoomEngine`
/// answers what the SDK ACCEPTED, so an answer different from the request is the SDK
/// saying no; a button that silently does nothing is the absence this client refuses
/// to render. ⚠️ The next change that lands clears it.
///
/// ⚠️ A VALUE TYPE WITH NO ENGINE IN IT so the rule is testable without LiveKit.
struct RoomMediaToggle: Equatable {
    private(set) var isOn = false
    private(set) var inFlight = false
    private(set) var failed = false

    /// Start a change to `!isOn`. Returns the value to ask for, or nil while another
    /// change is still in flight.
    mutating func begin() -> Bool? {
        guard !inFlight else { return nil }
        inFlight = true
        return !isOn
    }

    /// The engine answered.
    ///
    /// - Parameter accepted: what the SDK accepted, which is the truth either way.
    mutating func finish(requested: Bool, accepted: Bool) {
        inFlight = false
        isOn = accepted
        failed = accepted != requested
    }

    /// The SDK reported a change nobody here asked for (a server-side unpublish).
    mutating func observe(_ enabled: Bool) {
        isOn = enabled
    }
}
