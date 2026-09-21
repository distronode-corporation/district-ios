import DistrictData
import DistrictModel
import DistrictNetwork
import SwiftUI

/// The rooms lobby: start a meeting, or read the minutes of one that already
/// happened.
///
/// ⛔ THE MINUTES ARE THE REASON THIS SCREEN EXISTS, NOT A SECONDARY LIST. The
/// Companion joins every `meet_` room and writes them up; without somewhere to read
/// them the feature is invisible on a phone. So a completed meeting shows its preview
/// inline rather than hiding it behind a tap.
///
/// ⛔ AND THE PREVIEW IS LABELLED AS ONE. The server truncates to 220 characters, so
/// presenting it as "the minutes" would quietly deliver two sentences where a page was
/// written. ⛔ NOTHING HERE OFFERS PLAYBACK: `MeetingResponses.swift` says the
/// `Meeting` model has no recording column at all and neither route has a recording
/// sibling, so a play control would be a control with nothing behind it.
///
/// ⚠️ THE JOIN FORM STAYS USABLE WHEN THE HISTORY READ FAILS. They are unrelated
/// server surfaces, and gating the field on the list would turn an outage of the
/// archive into an inability to hold a meeting.
///
/// ⛔ AND AN EMPTY LIST IS NEVER STATED AS "there are no meetings" WITHOUT CHECKING
/// WHETHER THE PAGE WAS EMPTY. See the ⛔ on ``meetingList(_:)``.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and
/// registers `navigationDestination(for: Route.self)` on it exactly once; this screen
/// appends a ``Route`` to that stack through `NavigationLink(value:)`.
struct RoomsLobbyView: View {
    @State private var model: RoomsLobbyModel

    @Environment(\.colorScheme) private var colorScheme

    private let workspaceId: String
    private let role: WorkspaceRole?

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        _model = State(
            initialValue: RoomsLobbyModel(container: container, workspaceId: workspaceId, role: role)
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DistrictSpacing.section) {
                startSection
                DistrictEyebrow(text: RoomsCopy.historyLabel)
                historySection
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        // ⛔ `.contain` BEFORE THE IDENTIFIER, per the sign-in finding.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Rooms.root)
        .navigationTitle(RoomsCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        // ⛔ A SHEET RATHER THAN A DESTINATION. The record carries the meeting's
        // COMPLETE TRANSCRIPT, and a destination would put that behind a route that
        // survives process death and sits in the back stack. See the ⛔ on
        // ``RoomsLobbyModel/record``.
        .sheet(isPresented: recordPresented) {
            MeetingRecordSheet(state: model.record, onClose: model.closeMeeting)
        }
    }

    private var recordPresented: Binding<Bool> {
        Binding(
            get: { model.record != nil },
            set: { presented in
                guard !presented else { return }
                model.closeMeeting()
            }
        )
    }

    // MARK: - Starting a room

    /// ⛔ HIDDEN FOR A VIEWER, WITH A SENTENCE. `WorkspaceRole.allowsMutation` is the
    /// gate on anything that starts a room; attendance is a different
    /// question and Rejoin below stays offered, because a viewer's token carries
    /// `canPublish:false` and the room is still a legitimate seat for them.
    @ViewBuilder
    private var startSection: some View {
        if model.canStart {
            startCard
        } else {
            RoomNotice(text: RoomsCopy.viewerCannotStart)
        }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: RoomsCopy.startLabel)
            TextField(RoomsCopy.nameLabel, text: $model.roomName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.join)
                .districtField()
            // ⛔ SHOWN WHILE TYPING, NEVER APPLIED TO THE FIELD. See
            // ``RoomsCopy/namePreview(_:)``.
            Text(model.canJoin ? RoomsCopy.namePreview(model.normalizedName) : RoomsCopy.nameHint)
                .font(DistrictType.caption)
                .foregroundStyle(mutedInk)
            joinLink
            // ⚠️ SAYS THE COMPANION WILL BE THERE BEFORE ANYONE JOINS. Being told
            // after the fact is being told too late.
            Text(RoomsCopy.companionNotice)
                .font(DistrictType.caption)
                .foregroundStyle(mutedInk)
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }

    /// ⛔ A `NavigationLink(value:)` CARRYING THE WHOLE MINTED NAME, never a button
    /// that assembles one at the destination. `Route.activeRoom`'s own ⛔ requires the
    /// full `meet_<workspaceId>_<suffix>` string in the value, because rebuilding a
    /// name is precisely where a `video_` one, one character away and a BILLABLE
    /// avatar session, could be produced by mistake.
    ///
    /// ⚠️ RENDERED AS A DISABLED CONTROL WHEN NOTHING USABLE IS TYPED, rather than
    /// absent, so the form does not reflow under the user's hands as they type.
    @ViewBuilder
    private var joinLink: some View {
        if let room = model.roomToStart() {
            NavigationLink(value: Route.activeRoom(workspaceId: workspaceId, role: role, roomName: room.value)) {
                Text(RoomsCopy.join)
            }
            .buttonStyle(.districtPrimary)
        } else {
            Button(RoomsCopy.join) {}
                .buttonStyle(.districtPrimary)
                .disabled(true)
        }
    }

    // MARK: - The history

    @ViewBuilder
    private var historySection: some View {
        switch model.meetings {
        case .loading:
            VStack(spacing: DistrictSpacing.row) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    SkeletonBlock(height: DistrictSpacing.header)
                }
            }
        case let .ready(page):
            meetingList(page)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        }
    }

    /// ⛔ THREE OUTCOMES BEHIND ONE SUCCESS, AND TWO OF THEM ARE EMPTY. The server caps
    /// its query at 50 rows BEFORE this client drops the `video_` avatar sessions
    /// (``MeetingsPage`` states the whole of it), so an empty list means "this
    /// workspace has held no meetings" only when the page itself was empty. When rows
    /// arrived and none survived the filter, the honest sentence is about the PAGE, and
    /// it belongs to a workspace that is busy rather than new: telling that operator
    /// "no meetings yet" is the confident absence this screen must never state.
    ///
    /// ⚠️ THE THIRD IS A FULL PAGE THAT MAY NOT BE THE WHOLE HISTORY, captioned rather
    /// than hidden. ``BillingCopy/invoicesTruncated`` says the same thing about the
    /// same shape ("Showing your most recent invoices"), and the caption sits ABOVE the
    /// rows for the reason ``MarketplaceCopy/partialBanner(_:)`` gives: it qualifies
    /// them, it never replaces them.
    @ViewBuilder
    private func meetingList(_ page: MeetingsPage) -> some View {
        if page.isEmptyAfterFiltering {
            // ⛔ NOT `RoomsCopy.emptyTitle`. That sentence says the workspace has held
            // no meetings, which is a claim about the ACCOUNT; this one is a claim about
            // one page of one read, and it is the only one the client can support.
            // ⚠️ INLINE LITERALS RATHER THAN ``RoomsCopy`` ENTRIES, which is where the
            // rest of this screen's sentences live and where these two belong; moving
            // them is a rename with no behaviour in it.
            EmptyStateView(
                systemImage: "calendar.badge.exclamationmark",
                title: "No meetings on this page",
                message: "The most recent records for this workspace are not meetings this app shows. "
                    + "There may be meetings further back that this app does not show."
            )
        } else if page.meetings.isEmpty {
            // ⚠️ EMPTY IS AN ANSWER AND IS EVERY WORKSPACE ON DAY ONE, so it explains
            // the absence rather than reporting a fault. ⚠️ Reachable only when the
            // server sent nothing at all, which is what makes the sentence true.
            EmptyStateView(
                systemImage: "calendar",
                title: RoomsCopy.emptyTitle,
                message: RoomsCopy.emptyBody
            )
        } else {
            VStack(spacing: DistrictSpacing.row) {
                if page.isCapped {
                    // ⚠️ IT DOES NOT NAME A COUNT. The page arrived full at 50 ROWS and
                    // the avatar sessions were dropped from it, so the number of
                    // meetings drawn below is usually smaller; quoting either figure
                    // would state something the operator cannot check.
                    RoomNotice(
                        text: "Showing the most recent meetings. "
                            + "The full history is not available in this app."
                    )
                }
                ForEach(page.meetings, id: \.id) { meeting in
                    MeetingRow(
                        meeting: meeting,
                        workspaceId: workspaceId,
                        role: role,
                        rejoinRoom: model.roomToRejoin(meeting.roomName),
                        onOpen: { openMeeting(meeting.id) }
                    )
                    .accessibilityIdentifier(A11yID.Rooms.meeting(meeting.id))
                }
            }
        }
    }

    private func reload() {
        Task { await model.load() }
    }

    private func openMeeting(_ meetingId: String) {
        Task { await model.openMeeting(meetingId) }
    }

    private var mutedInk: Color {
        DistrictColors.resolve(colorScheme).mutedForeground
    }

    private var cardFill: Color {
        DistrictColors.resolve(colorScheme).card
    }
}

/// One meeting in the history.
///
/// ⛔ REJOIN IS OFFERED ONLY FOR A MEETING STILL RUNNING, AND THE ROW IS WHAT
/// ENFORCES IT. Joining the room of a finished meeting is not an error server-side
/// (the name is still valid), so nothing would stop it; it would just silently start
/// a SECOND meeting under the name whose minutes the user was reading, and the
/// Companion would write those up too.
struct MeetingRow: View {
    let meeting: MeetingSummary
    let workspaceId: String
    let role: WorkspaceRole?
    /// ⚠️ nil WHEN THE STORED NAME IS NOT ONE THIS CLIENT WILL JOIN, which is a real
    /// answer rather than a fault: the `Meeting` table records whatever room the
    /// Companion was dispatched into.
    let rejoinRoom: RoomName?
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var isLive: Bool {
        meeting.status == RoomsCopy.statusInProgress
    }

    /// ⚠️ THE HUMAN HALF OF THE ROOM NAME WHEN NOBODY TITLED THE MEETING. The full
    /// `meet_<uuid>_standup` is not something to show a person, and an empty line
    /// would leave the row unidentifiable.
    private var title: String {
        let named = meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return named.isEmpty ? RoomName.displayName(meeting.roomName) : named
    }

    /// ⛔ NAMED AS A PREVIEW, and "no minutes yet" gets its own sentence rather than
    /// an empty line: an in-progress meeting has no summary and that is normal, not a
    /// fault. See ``MeetingSummary/summaryPreview``.
    private var subtitle: String {
        let preview = meeting.summaryPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preview.isEmpty {
            return RoomsCopy.preview(preview)
        }
        return isLive ? RoomsCopy.noMinutesYet : RoomsCopy.noMinutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            HStack {
                Text(title)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DistrictBadge(text: meeting.status, tone: isLive ? .district : .neutral)
            }
            Text(subtitle)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            HStack(spacing: DistrictSpacing.tight) {
                Button(RoomsCopy.openMeeting, action: onOpen)
                    .buttonStyle(DistrictButtonStyle(variant: .ghost, size: .small))
                if isLive, let room = rejoinRoom {
                    NavigationLink(
                        value: Route.activeRoom(workspaceId: workspaceId, role: role, roomName: room.value)
                    ) {
                        Text(RoomsCopy.rejoin)
                    }
                    .buttonStyle(DistrictButtonStyle(variant: .secondary, size: .small))
                }
            }
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }
}
