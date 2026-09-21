import Foundation

/// The call log, the softphone, the inbound answer, and the meeting rooms.
public extension DistrictEndpoints {
    /// One page of the call log, newest first.
    ///
    /// ⛔ RETURNS A BARE JSON ARRAY WITH NO PAGINATION METADATA — no total, no
    /// `hasMore`, no cursor. End of list can only be inferred from a short page.
    /// Do not add a synthetic wrapper; the endpoint genuinely has none. See
    /// ``BareArrayEndpoints``.
    ///
    /// ⚠️ OFFSET PAGING OVER A LIVE FEED IS NOT STABLE: ordering is a fixed
    /// `createdAt desc`, so a call arriving mid-scroll shifts every window and the
    /// SAME call can be returned twice. `OffsetPager` deduplicates.
    ///
    /// - Parameter limit: clamped server-side to 100. A non-positive or
    ///   non-numeric value falls back to the server's default of 10 rather than
    ///   being clamped up, so passing 0 quietly yields ten rows.
    /// - Parameter offset: ⚠️ deliberately UNCAPPED server-side, so a large value
    ///   is a slow query rather than a wrong page.
    static func calls(workspaceId: String, limit: Int, offset: Int) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .calls,
            .get,
            DistrictPaths.calls,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("limit", String(limit)),
                ApiQueryItem("offset", String(offset)),
            ]
        )
    }

    /// One call, in exactly the shape a feed row has.
    ///
    /// ⚠️ A 404 DOES NOT MEAN THE ID WAS MALFORMED: the server reads by id and
    /// checks ownership afterwards, so another tenant's id is indistinguishable
    /// from a missing one. Word any message accordingly.
    static func callDetail(workspaceId: String, callId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .callDetail,
            .get,
            DistrictPaths.calls + [callId],
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// A single call's transcript, fetched on demand.
    ///
    /// ⚠️ Separate from the feed because transcripts are large: embedded in the
    /// contact timeline they would dominate its payload. An absent
    /// transcript is the EMPTY STRING, not null — the handler does
    /// `call.transcript || ""` — so emptiness is the "nothing to show" test.
    static func callTranscript(workspaceId: String, callId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .callTranscript,
            .get,
            DistrictPaths.calls + [callId, "transcript"],
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Resolve a playable URL for a call's recording.
    ///
    /// ⛔ THE SERVER ANSWERS **302, NOT JSON**, AND THIS CLIENT MUST NOT FOLLOW
    /// IT. Following it streams the whole audio file through this process just to
    /// learn its address — on a metered connection, for a file the player is
    /// about to fetch again itself. Send it through
    /// ``ApiClient/redirectTarget(_:)``, which surfaces the status and the
    /// `Location` header and follows nothing.
    ///
    /// ⚠️ THE URL IS SHORT-LIVED (a presigned object URL): resolve it at the
    /// moment of playback and never cache or persist it. A cached one expires and
    /// fails inside whatever player received it, which looks like a broken
    /// recording rather than a stale link.
    ///
    /// ⚠️ A call with no recording answers **404 with a JSON body**, not a
    /// redirect, so the ordinary error mapping still applies.
    static func callRecordingUrl(workspaceId: String, callId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .callRecordingUrl,
            .get,
            DistrictPaths.calls + [callId, "recording"],
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Place a direct outbound call and receive the credential to join its room.
    ///
    /// ⛔ THIS SPENDS REAL MONEY AND RINGS A TELEPHONE. Nothing may retry it on
    /// its own. A retry after a 5xx — where the dial may already have gone out —
    /// would ring the callee twice.
    ///
    /// ⛔ THE RESPONSE ARRIVES BEFORE THE CALLEE ANSWERS, DELIBERATELY. The route
    /// does not pass `waitUntilAnswered`, so the app joins the room while the far
    /// end is still ringing; a client that rendered "connected" would be wrong
    /// about the most visible thing on the screen.
    ///
    /// - Parameter to: the number AS TYPED. ⚠️ NOT pre-normalised here: the
    ///   server runs `normalizePhoneNumber` and then checks DNC against THAT
    ///   form, and a client-side canonicaliser that disagreed would place a call
    ///   the DNC check never ran against.
    static func dial(workspaceId: String, to: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .dial,
            .post,
            DistrictPaths.callsDial,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("to", .string(to)),
            ]))
        )
    }

    /// Answer a ringing call and receive the credential to join its room.
    ///
    /// ⛔ CALLED **AFTER** THE HUMAN PRESSES ANSWER, NEVER ON THE PUSH ITSELF.
    /// This call WRITES the Redis rendezvous the agent's `ring-app` transfer is
    /// blocking on, so "pre-warming" a credential tells the agent a human took
    /// the call while the phone is still ringing in a pocket — and the caller is
    /// handed to nobody.
    ///
    /// ⛔ NOTHING MAY RETRY IT. Not because a second answer is billable, but
    /// because a 5xx may already have released the agent's transfer, and a second
    /// attempt races a call that is being connected.
    ///
    /// ⚠️ 404 (a call this workspace cannot see) and 409 (no longer answerable)
    /// are both "the call ended while your phone was ringing", which is the
    /// ordinary race on a ringing screen rather than a fault. 403 is the viewer
    /// refusal and is genuinely different — and it cannot be prevented by hiding
    /// a button, because the entry point is a PUSH the server fanned out to every
    /// registered device without consulting roles.
    static func answerCall(callId: String, workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .answerCall,
            .post,
            DistrictPaths.callAnswer(callId),
            body: .json(.object([("workspaceId", .string(workspaceId))]))
        )
    }

    /// Tell the SERVER to end a direct softphone call, carrier leg included.
    ///
    /// ⛔ WITHOUT THIS THE APP CANNOT HANG UP, AND THE FAILURE IS A BILL RATHER
    /// THAN AN ERROR. Ending a call locally is `Room.disconnect()`, which removes
    /// THIS device from the room and says nothing to the SIP participant; the
    /// carrier leg goes on ringing or talking to an empty room and goes on being
    /// billed. Nothing fails, nothing logs, and the call log's own duration is the
    /// only place it shows.
    ///
    /// ⛔ IDEMPOTENT, WHICH IS THE EXACT OPPOSITE OF ITS NEIGHBOUR ONE SEGMENT
    /// AWAY. ``dial(workspaceId:to:)`` may never be re-sent because a re-send
    /// places a second call; this one is DESIGNED to be sent on endings that have
    /// already happened, because the case it exists for is a teardown racing a
    /// dial that has not come back yet. A second send answers
    /// `{success: true, ended: false}`.
    ///
    /// ⚠️ 404 IS "no such call for this workspace" AND 409 IS "not a direct
    /// softphone call", and neither is a fault a screen can act on. Both are
    /// answers rather than errors — see ``DistrictData``'s `DialRepository` — and
    /// the client never shows either to anybody, because the local teardown has
    /// already happened by the time this is sent.
    ///
    /// - Parameter callId: the `Call.callSid` from ``DialResponse/callId``. ⛔ Not
    ///   a room name and not derivable from one.
    static func hangUpCall(callId: String, workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .hangUpCall,
            .post,
            DistrictPaths.callHangUp(callId),
            body: .json(.object([("workspaceId", .string(workspaceId))]))
        )
    }

    /// Mint a join token for a `meet_` room.
    ///
    /// ⛔ THE ROOM NAME IS A ``RoomName``, NOT A STRING, AND THAT IS THE `video_`
    /// GUARD. See the ⛔ on that type: `video_` is one character from `meet_` in
    /// the same server-side `startsWith` chain and silently starts a billable
    /// Tavus avatar.
    ///
    /// ⚠️ IDEMPOTENT IN THE SENSE THAT NOTHING IS PERSISTED — but each call mints
    /// a fresh twelve-hour guest invite, so a screen calling it on every redraw
    /// would be minting capabilities at the rate it redraws.
    static func roomToken(roomName: RoomName) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .roomToken,
            .post,
            DistrictPaths.callsToken,
            body: .json(.object([
                ("roomName", .string(roomName.value)),
                ("identity", .string(RoomIdentity.value)),
            ]))
        )
    }

    /// The workspace's meetings, newest first, capped at 50 server-side.
    ///
    /// ⛔ A BARE JSON ARRAY, NOT AN ENVELOPE — `NextResponse.json(results)`, the
    /// same shape as the call log. See ``BareArrayEndpoints``.
    ///
    /// ⚠️ THE 50-ROW CAP IS SILENT. Nothing in the response says whether it was
    /// hit, so a client must not describe this as the complete history.
    static func meetings(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .meetings,
            .get,
            DistrictPaths.meetings,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// One meeting in full — minutes, transcript, action items.
    ///
    /// ⛔ NOT A SUPERSET OF THE LIST ROW, WHICH IS THE TRAP. This returns the raw
    /// database row, so it carries `summary` and `participants` where the list
    /// carried `summaryPreview` and `participantCount`. Neither model decodes the
    /// other's payload.
    static func meetingDetail(workspaceId: String, meetingId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .meetingDetail,
            .get,
            DistrictPaths.meetings + [meetingId],
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }
}
