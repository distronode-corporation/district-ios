import DistrictData
import DistrictModel
import Foundation
import Observation

/// Whether this process was launched to make the App Review recording.
///
/// ⛔ IT EXISTS BECAUSE THE FLAG MECHANISM CANNOT BE DEMONSTRATED WITHOUT USING IT.
/// Apple asks for a physical-device recording of a reviewer flagging objectionable
/// content, and there is no dry-run: submitting the sheet files a REAL support
/// request into a REAL Atlassian queue. So the recording's tickets are marked in
/// their own subject line, which is what lets a human find and close them afterwards
/// instead of triaging a report about a fictional `+1 555 01xx` caller.
///
/// ⛔ DEBUG-ONLY, LITERAL AND ALL, FOR THE REASON ``UITestSession`` IS. The archive is
/// a Release build where `SWIFT_ACTIVE_COMPILATION_CONDITIONS` does not carry `DEBUG`
/// (measured on this project with `xcodebuild -showBuildSettings`, not assumed), so a
/// shipped binary has no argument to arm and no string to find. ⚠️ It grants nothing
/// either way: the only thing it changes is five words in a subject line.
enum ReviewRecordingMode {
    #if DEBUG
        static let launchArgument = "-ReviewRecording"

        static func isArmed(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(launchArgument)
        }
    #else
        static func isArmed() -> Bool {
            false
        }
    #endif
}

/// What was reported.
///
/// ⛔ AN ID, NEVER THE CONTENT. The message this model composes names the thread or
/// the call and says nothing about what was in it, and that is deliberate on two
/// counts: a support request is a Jira issue readable by our own agents, and the
/// customer's own words are already in the workspace where an agent can read them
/// under the workspace's own access rules. Copying a transcript into a ticket would
/// move customer content out of its residency region and into a vendor whose row in
/// the published sub-processor list does not cover it.
///
/// ⚠️ THE NAME IS CARRIED FOR THE SHEET'S HEADING, NOT FOR THE MESSAGE. It is what
/// the list resolved, so it can be a phone number or the literal "Unknown"; putting
/// it on the wire would add a field the server did not ask for to a payload that 400s
/// on unknown fields.
enum ReportTarget: Equatable {
    /// An inbox conversation, by its `contact:<id>` or `addr:<normalized>` key.
    case conversation(threadKey: String, name: String?)

    /// One call, by id.
    case call(callId: String)
}

/// The report's state machine.
///
/// ⛔ `done` CARRIES THE SENTENCE RATHER THAN A BOOLEAN, for the reason
/// ``SupportWriteState`` gives: raising a request has THREE successful outcomes
/// (filed, already open, being opened) and reporting the second as a failure is what
/// invites a third attempt into a human's queue.
enum ReportState: Equatable {
    case idle
    case sending
    case done(String)
    /// ⚠️ NO ``SupportResubmit`` HERE, UNLIKE ``SupportWriteState``. Every failure of
    /// this write is retryable because the request carries an idempotency key the
    /// server claims — see the ⚠️ on ``ReportContentModel/submit(note:)``.
    case failed(String)
}

/// Flagging objectionable content, on the workspace's own support desk.
///
/// ⛔ IT RIDES THE EXISTING SUPPORT TRANSPORT RATHER THAN A NEW ROUTE, AND THAT IS A
/// DECISION ABOUT WHERE A REPORT HAS TO LAND. `POST district/support/requests` claims
/// a durable local row BEFORE it calls Atlassian and files under the reporting
/// workspace's own region, so a report survives a vendor outage and stays in region.
/// A bespoke `/report` route would have had to re-earn both.
///
/// ⛔ `kind` IS `problem`, WHICH IS THE SERVER'S OWN DEFAULT AND THE ONLY DEFENSIBLE
/// CHOICE OF THE THREE. `question` and `suggestion` map to Jira request types whose
/// queues nobody watches for moderation, and the kind is mapped to a request type id
/// SERVER-SIDE precisely so a client cannot file into an arbitrary one.
///
/// ⛔ NOTHING MAY BE ADDED TO THE PAYLOAD. It is exactly `kind`, `subject`, `message`
/// and the key: the desk's `requestFieldValues` accepts only the fields the request
/// TYPE exposes on its portal form, and an unknown field is a hard 400 raised AFTER
/// the local claim row exists, which would fail every report filed. So the thread id
/// goes in the MESSAGE, which is where the support desk's own claim marker goes for
/// the same reason.
///
/// ⚠️ THE SUPPORT ROUTES EXCLUDE `viewer` SERVER-SIDE, so the caller gates this on
/// ``WorkspaceRole/allowsMutation(_:)`` and a read-only seat is not offered the
/// control. ⛔ THAT IS A KNOWN GAP AGAINST GUIDELINE 1.2 RATHER THAN A DESIGN: the
/// guideline asks that anyone who can SEE the content be able to flag it, and a
/// viewer can see it. Closing it is a server change (admit `viewer` on the create
/// route, or give reports their own route), not a client one — offering the control
/// anyway would only walk a viewer into a 403 they cannot act on, which is the rule
/// every other gated control on this client follows.
@MainActor
@Observable
final class ReportContentModel {
    private(set) var state: ReportState = .idle

    private let support: SupportRepository
    private let workspaceId: String
    private let target: ReportTarget

    /// ⛔ MINTED ONCE PER OPENED SHEET, NEVER PER ATTEMPT, which is what makes this
    /// the one write on the support surface a caller may repeat. The server claims
    /// the key before it calls Atlassian and answers a re-used one with
    /// `deduplicated: true`, so a retry carrying the SAME key collapses onto the
    /// first request while a retry that minted a fresh one would put a second
    /// moderation ticket in a human's queue.
    ///
    /// ⚠️ LOWERCASED, because the route validates a UUID and `Foundation`'s
    /// `uuidString` is upper-case. Same normalisation ``SupportModel`` does.
    private let idempotencyKey = UUID().uuidString.lowercased()

    init(container: AppContainer, workspaceId: String, target: ReportTarget) {
        support = container.support
        self.workspaceId = workspaceId
        self.target = target
    }

    /// The sheet's heading: what is about to be reported.
    var headline: String {
        ReportCopy.headline(for: target)
    }

    var isSending: Bool {
        state == .sending
    }

    /// File the report.
    ///
    /// ⚠️ THE NOTE IS OPTIONAL AND A BLANK ONE IS NOT A REFUSAL. Guideline 1.2 asks
    /// for a mechanism to FLAG content; requiring an explanation would make the
    /// mechanism conditional on the reporter being able to articulate why, which is
    /// the opposite of what a one-tap flag is for. ``ReportCopy`` says so in the
    /// message instead.
    ///
    /// ⚠️ A FAILED SUBMIT LEAVES THE CONTROL ARMED, unlike a support reply or close.
    /// Those post a public comment into the customer's own thread so a repeat is
    /// visible damage; this one carries an idempotency key, so the server converges.
    /// ``SupportResubmit/after(_:_:)`` with ``SupportWriteRepeat/idempotent`` answers
    /// `.allowed` for every error, which is why this model does not store one.
    func submit(note: String) async {
        guard state != .sending else { return }
        state = .sending

        let outcome = await support.create(
            workspaceId: workspaceId,
            kind: .problem,
            subject: ReportCopy.subject,
            message: ReportCopy.message(for: target, note: note),
            idempotencyKey: idempotencyKey
        )

        switch outcome {
        case let .success(filing):
            state = .done(ReportCopy.confirmation(for: filing))
        case let .failure(error):
            // ⚠️ THE SERVER'S OWN SENTENCE, NOT A SUBSTITUTE. A 429 names the remedy
            // (reply on an existing request) and a 503 names the public form as a
            // PATH rather than a host, because Canada's canonical host is
            // distronode.ca. `FailureText` shows a 4xx message verbatim for exactly
            // this.
            state = .failed(FailureText.from(error).message)
        }
    }

    /// Return to Idle so the control can be pressed again.
    func reset() {
        state = .idle
    }
}
