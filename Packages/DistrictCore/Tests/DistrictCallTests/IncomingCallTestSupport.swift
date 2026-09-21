@testable import DistrictCall

let testWorkspace = WorkspaceID("ws-1")
let testCall = CallID("CA1")

/// The instant the push arrived, on the caller's own injected clock.
let testRingStart: Int64 = 1_700_000_000_000

let testAnswerURL = "wss://livekit-wss.distronode.com"
let testAnswerToken = "answer-jwt"

extension IncomingCallController {
    /// ⛔ REACHED THROUGH REAL EVENTS, never by writing a phase. See the same note
    /// on the softphone's helpers.
    static func inRinging() -> IncomingCallController {
        var controller = IncomingCallController()
        controller.handle(.ringing(workspace: testWorkspace, call: testCall, atMilliseconds: testRingStart))
        return controller
    }

    /// Answer pressed, the round trip still out. ⚠️ No engine exists yet.
    static func inAnswering() -> IncomingCallController {
        var controller = inRinging()
        controller.handle(.answerPressed)
        return controller
    }

    /// The credential landed and the join was issued, but media is not up.
    ///
    /// ⚠️ STILL `.answering`, AND THAT IS THE STATE THE `engineAttached` FLAG
    /// EXISTS FOR: a join issued here and then failed leaves a socket that only
    /// the flag can tell the exit to close.
    static func inJoining() -> IncomingCallController {
        var controller = inAnswering()
        controller.handle(.answerJoinable(url: testAnswerURL, token: testAnswerToken))
        return controller
    }

    static func inCall() -> IncomingCallController {
        var controller = inJoining()
        controller.handle(.engine(.connected))
        return controller
    }

    static func inEnded() -> IncomingCallController {
        var controller = inCall()
        controller.handle(.hangUpPressed)
        return controller
    }
}
