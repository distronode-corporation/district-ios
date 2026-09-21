@testable import DistrictCall

/// The number every test dials. ⚠️ Held as the operator typed it; the server
/// normalises its own copy and this never travels.
let testNumber = "(416) 555-0100"

let testDialURL = "wss://livekit-trunk.distronode.com"
let testDialToken = "join-jwt"

/// The server's id for the call, i.e. `DialResponse.callId`.
///
/// ⛔ THE ONLY HANDLE ON THE CARRIER LEG. It arrives with the credential and not
/// before, which is why ``SoftphoneSession/inDialing()`` below has no `callId` and
/// every phase after it does — the difference is exactly the window an operator
/// hangs up in when they mis-dial.
let testDialCallId = "CA1"

/// The command every ending that knows the id must carry.
let testServerHangUp = SoftphoneCommand.requestServerHangUp(callId: testDialCallId)

/// One remote party, standing in for the SIP bridge's participant.
let testCallee = CallParticipant(identity: "sip_+14165550100")

extension SoftphoneSession {
    /// A session driven to each phase through real events, never by writing the
    /// phase.
    ///
    /// ⛔ THE PHASES ARE REACHED THE WAY PRODUCTION REACHES THEM, so a transition
    /// that stops working invalidates every table below rather than leaving them
    /// asserting against a state nothing can produce.
    static func inDialing() -> SoftphoneSession {
        var session = SoftphoneSession(number: testNumber)
        session.handle(.dialRequested)
        return session
    }

    static func inConnecting() -> SoftphoneSession {
        var session = inDialing()
        session.handle(.dialAccepted(url: testDialURL, token: testDialToken, callId: testDialCallId))
        return session
    }

    static func inRinging() -> SoftphoneSession {
        var session = inConnecting()
        session.handle(.engine(.connected))
        return session
    }

    static func inConnected() -> SoftphoneSession {
        var session = inRinging()
        session.handle(.engine(.participantJoined(testCallee)))
        return session
    }

    static func inEnded() -> SoftphoneSession {
        var session = inConnected()
        session.handle(.hangUpPressed)
        return session
    }
}
