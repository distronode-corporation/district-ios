import DistrictCall
import DistrictModel
import SwiftUI

/// The dialer: a number field and a Call button, and — while a call is live — the
/// in-call surface in its place.
///
/// ⛔ ONE DESTINATION FOR BOTH, BECAUSE THEY ARE ONE DESTINATION. See the ⛔ on
/// `Route.dialer`: an in-call destination reached by navigation is restored from the
/// path after process death and the effect that starts the call runs again, placing a
/// SECOND billable call to the same person with no user action. Swapping the content of
/// one destination has no such restore path — a killed process comes back to an idle
/// keypad, which is the truth, because the socket died with it.
///
/// ⚠️ THE MODEL IS NOT THE CALL'S OWNER FOR LIFETIME PURPOSES. This `@State` dies with
/// the destination; the call does not. ``DialerModel`` claims
/// ``CallStack/onSystemRequest`` on the process-lifetime stack held by ``AppContainer``
/// for exactly the length of one call, so a screen popped mid-call leaves the call
/// running with an owner still driving it. See the ⛔ on that model.
///
/// ⛔ AND A SCREEN REBUILT AROUND A LIVE CALL RE-ATTACHES TO THAT OWNER. Choosing another
/// sidebar section and then Dial again, or a rotation that swaps the tab bar for the
/// sidebar, destroys this view while the call goes on; a fresh model here would draw an
/// idle keypad over a live call, with the hang-up nowhere on screen and every new dial
/// refused as busy. ``CallStack/softphone`` is where the owner is found, and the model
/// registers itself there when it takes the claim.
/// ⚠️ ON A PHONE THE SAME HOLDS FOR A DIAL SCREEN POPPED MID-CALL AND OPENED AGAIN from
/// the Overview, which would otherwise come back to that busy keypad.
/// ⚠️ This is not a restore after process death, which the ⛔ on `Route.dialer` rules
/// out: a killed process holds no owner, so it still comes back to an idle keypad.
struct DialerView: View {
    @State private var model: DialerModel

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        let live = DialerModel.attached(to: container.callStack, workspaceId: workspaceId)
        _model = State(
            initialValue: live ?? DialerModel(container: container, workspaceId: workspaceId, role: role)
        )
    }

    var body: some View {
        content
            .navigationTitle("Dial")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        if let call = model.call {
            InCallView(display: .softphone(call.state, endedByOperator: model.endedByOperator), controls: model)
        } else {
            DialerKeypadView(model: model)
        }
    }
}

/// The number field, the Call button, and whatever the last dial refused with.
///
/// ⛔ A TEXT FIELD RATHER THAN A TWELVE-KEY GRID, AND THE REASON IS THE NUMBERS THIS
/// PRODUCT DIALS. A grid is the right shape for a consumer phone dialling local numbers
/// from memory; this dials E.164 numbers with country codes, usually pasted or read off
/// a call log, and a grid makes `+` awkward and pasting impossible. The `.phonePad`
/// keyboard puts the same digits one tap away, and it is the system field, so paste,
/// selection and autofill all work without anything being written here.
private struct DialerKeypadView: View {
    let model: DialerModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⛔ EVERY EDIT GOES THROUGH ``DialerModel/onEntryChange(_:)``, which clears the
    /// previous refusal. A binding straight to the property would leave a message about
    /// a number the operator has already replaced.
    private var entry: Binding<String> {
        Binding(get: { model.entry }, set: { model.onEntryChange($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                Text("Number")
                    .font(DistrictType.labelSmall)
                    .foregroundStyle(colors.mutedForeground)
                field
                destination
                problem
                hint
                action
                notice
                failure
                callbacks
            }
            .padding(DistrictSpacing.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // ⛔ THE LIST LOADS INDEPENDENTLY AND MAY FAIL ALONE. This `.task` is the
        // only thing that reads it, and nothing it can do reaches ``model.refusal``
        // or ``DialerModel/canPlaceCall``, so an outage of the call log leaves a
        // working keypad. ⚠️ It runs again whenever the keypad comes back after a
        // call, because ``DialerView`` swaps this view out for the in-call surface
        // and SwiftUI gives the replacement a fresh identity. That re-read is
        // wanted: anyone who rang while the call was up belongs in the list. It is
        // a GET, so replaying it costs nothing.
        .task {
            await model.loadCallbacks()
        }
    }

    // MARK: - Pieces

    /// ⚠️ `.phonePad` RATHER THAN `.numberPad`, so `+`, `*` and `#` are reachable. A
    /// digits-only keyboard makes an international number untypeable without switching
    /// keyboards.
    ///
    /// ⛔ DISABLED FOR A VIEWER RATHER THAN HIDDEN, WITH THE SENTENCE BELOW IT. The
    /// entry into this screen is already hidden for that role (see ``RouteGate``), so
    /// anyone here arrived from a restored back stack or a deep link, and a field that
    /// simply did nothing would read as a broken app.
    private var field: some View {
        TextField("Number", text: entry)
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .autocorrectionDisabled()
            // ⛔ ALSO LOCKED WHILE `placing`. The keypad is still on screen between the
            // tap and CallKit performing the start action, and an edit in that window
            // would leave the field disagreeing with the number the OS was handed.
            // ``DialerModel/placeCall()`` pins the value anyway; this is so the operator
            // is not shown a number that is no longer the one being dialled.
            .disabled(!model.canDial || model.placing)
            .districtField()
            .accessibilityIdentifier(A11yID.Dialer.entry)
    }

    /// Which country the number will ring.
    ///
    /// ⛔ THE LINE THIS SCREEN EXISTS TO SHOW, AND IT IS BESIDE THE FIELD RATHER THAN IN
    /// IT. A leading `+41` reads "Switzerland" here, which is the one thing that catches
    /// a call about to reach the wrong country and be billed for it. The value that
    /// travels stays exactly what was typed: the server normalises its own copy and runs
    /// the DNC check and the dial against THAT form, so a formatter that rewrote the field
    /// would place a call the compliance check never saw. Rewriting text as someone types
    /// also moves their cursor.
    ///
    /// ⚠️ FULL `foreground` RATHER THAN `mutedForeground`, unlike every other caption
    /// on this screen. It is the line the operator is being asked to READ before
    /// spending money, and a muted one is the line people stop seeing.
    ///
    /// ⚠️ THE WARNING TONE IS FOR AN UNRECOGNISED CODE ONLY, and it is not
    /// destructive: the number is still dialable, and painting it red would say the
    /// app knows something is wrong when what it knows is that it does not know.
    @ViewBuilder
    private var destination: some View {
        if model.canDial, let line = DialerModel.destinationLine(model.destination.region) {
            Text(line)
                .font(DistrictType.bodySmall)
                .foregroundStyle(destinationInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destinationInk: Color {
        model.destination.region == .unrecognised ? colors.warning : colors.foreground
    }

    /// ⚠️ EMPTY WHEN THERE IS NOTHING TO SAY, which is the `.none` region — a number
    /// with no country code yet. An empty hint is no hint rather than a pause.
    private var destinationHint: String {
        DialerModel.destinationLine(model.destination.region) ?? ""
    }

    /// Why the Call button is off.
    ///
    /// ⛔ A DISABLED BUTTON WITH NO REASON CONFUSES PEOPLE, AS THE EIGHT-DIGIT FLOOR
    /// SHOWS. The commonest case by far is a number typed with no country code at
    /// all, which cannot be dialled.
    @ViewBuilder
    private var problem: some View {
        if model.canDial, let line = DialerModel.entryProblem(model.destination.refusal) {
            Text(line)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.Dialer.refusal)
        }
    }

    /// ⛔ BESIDE THE FIELD, NEVER IN IT. See ``destination``.
    @ViewBuilder
    private var hint: some View {
        if model.canDial, model.entry.isEmpty {
            Text(DialerModel.entryHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    @ViewBuilder
    private var action: some View {
        if model.canDial {
            // ⚠️ A CLOSURE LITERAL RATHER THAN `action: model.placeCall`. A non-Sendable
            // escaping closure inherits the enclosing `body`'s main-actor isolation; a
            // method REFERENCE is a value conversion and does not, which Swift 6 rejects.
            Button(model.placing ? "Calling…" : "Call") { model.placeCall() }
                .buttonStyle(.districtPrimary)
                .disabled(!model.canPlaceCall)
                // ⚠️ IDENTITY, NOT THE LABEL: it reads "Calling…" while placing.
                .accessibilityIdentifier(A11yID.Dialer.call)
                // ⛔ THE DESTINATION IS ATTACHED TO THE BUTTON, NOT LEFT BESIDE THE
                // FIELD. "This number rings Switzerland" is the line that catches a
                // call about to reach the wrong country and be billed for it —
                // see the ⛔ on ``destination`` — and it is a separate element two
                // swipes back. Someone using VoiceOver otherwise hears "Call, button"
                // and nothing about where. A hint is read after the label and after
                // the trait, which is exactly the moment before the press.
                .accessibilityHint(destinationHint)
        }
    }

    /// ⚠️ THE MICROPHONE SENTENCE IS SAID BEFORE THE SYSTEM ASKS, so the permission
    /// prompt has a visible reason. A request with no explanation is the one people deny
    /// permanently.
    private var notice: some View {
        Text(model.canDial ? DialerModel.microphoneNotice : DialerModel.viewerNotice)
            .font(DistrictType.caption)
            .foregroundStyle(colors.mutedForeground)
    }

    /// ⚠️ THE REFUSAL LIVES HERE, ON THE KEYPAD, because a refused dial produced no call
    /// and there is no call screen to show it over.
    @ViewBuilder
    private var failure: some View {
        if let refusal = model.refusal {
            Text(refusal.message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The call-back list

    /// The recent inbound callers, under a heading that says what they are.
    ///
    /// ⛔ "CALL BACK", NOT "REDIAL", AND THE LIST IS FILTERED TO MATCH.
    /// ``CallSummary/from`` on an OUTBOUND row is the workspace's own number, so a
    /// redial built from it would dial the workspace's own line; the filter lives
    /// in ``CallsRepository/recentCallbacks(workspaceId:limit:)`` and the heading
    /// here is the half of the promise the operator can see.
    ///
    /// ⛔ RENDERED FOR A VIEWER TOO, WHOSE KEYPAD IS DISABLED. It is a read of the
    /// call log rather than a way to place a call, and hiding it would answer "can
    /// I see who rang" with a blank screen. Tapping a row fills a field the viewer
    /// cannot dial from, which is the same dead end the field itself already is and
    /// is stated by the notice above it.
    private var callbacks: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            DistrictEyebrow(text: DialerModel.callbacksTitle)
            callbackContent
        }
        .padding(.top, DistrictSpacing.section)
    }

    @ViewBuilder
    private var callbackContent: some View {
        switch model.callbacks {
        case .loading:
            LoadingView(message: DialerModel.callbacksLoading)
        case let .ready(calls):
            callbackRows(calls)
        case let .failed(text):
            callbackFailure(text)
        }
    }

    /// ⚠️ AN EMPTY LIST IS AN EXPLAINED ABSENCE, NEVER A BLANK. A workspace whose
    /// newest twenty calls were all outbound has no call-backs and is perfectly
    /// healthy; drawing nothing there is indistinguishable from a broken screen.
    ///
    /// ⚠️ NOT COLLAPSED BY NUMBER, DELIBERATELY, AND THE DECISION IS THIS VIEW'S TO
    /// STATE. The repository hands over one row per CALL, so a person who rang
    /// three times is three rows; each carries its own time and outcome, and
    /// merging them would hide two calls behind one line.
    @ViewBuilder
    private func callbackRows(_ calls: [CallSummary]) -> some View {
        if calls.isEmpty {
            EmptyStateView(
                systemImage: "phone.arrow.down.left",
                title: DialerModel.callbacksEmptyTitle,
                message: DialerModel.callbacksEmpty
            )
        } else {
            // ⚠️ WIDTH ASSERTED HERE. The enclosing `VStack` is `.leading`, so a
            // child sizes to its ideal width unless it says otherwise, and a row
            // that shrank to its text would put the divider under half the screen.
            VStack(spacing: 0) {
                ForEach(calls, id: \.id) { call in
                    callbackRow(call)
                    DistrictRowDivider()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// ⛔ A TAP FILLS THE FIELD AND DOES NOT DIAL, which is why the whole row is one
    /// plain `Button` with a hint rather than a row carrying a Call control. One tap
    /// must never place a call, least of all from a scrolling list where a mis-scroll
    /// lands on a row.
    ///
    /// ⛔ THE TITLE COMES FROM ``CallDisplay``, NOT FROM ``CallSummary/number``.
    /// The server sends the literal "Unknown" for an unresolved caller, and printing
    /// that verbatim reads as a name; ``CallDisplay/callerLabel`` is the one place
    /// that rule lives, and re-deriving it here is exactly the drift that type
    /// exists to stop.
    ///
    /// ⚠️ THE SUBTITLE LEADS WITH THE NUMBER, unlike the call log's, because the
    /// number is what this row will put in the field and the operator is checking it
    /// before pressing Call. The direction glyph the log carries would say the same
    /// thing on every row here, since all of them are inbound by construction.
    ///
    /// ⚠️ `from` IS NON-NIL BY CONSTRUCTION HERE: the repository drops every row
    /// without a usable number, because a row with none is not something to call
    /// back. The coalesce is for the type, not for a case that can reach the screen.
    private func callbackRow(_ call: CallSummary) -> some View {
        let number = call.from ?? ""
        let display = CallDisplay(call)
        return Button { model.callBack(number) } label: {
            DistrictListRow(title: display.callerLabel, subtitle: "\(number) · \(display.timeAndDuration)")
        }
        .buttonStyle(.plain)
        .accessibilityHint(DialerModel.callbackHint)
    }

    /// ⛔ A FAILURE, NEVER AN EMPTY LIST, AND NEVER THE KEYPAD'S PROBLEM. The
    /// heading names what could not be read and ``FailureView`` decides what may be
    /// offered; the retry re-reads only this list.
    private func callbackFailure(_ text: FailureText) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(DialerModel.callbacksFailed)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            FailureView(failure: text, onRetry: reloadCallbacks)
        }
        .frame(maxWidth: .infinity)
    }

    /// ⚠️ A `Task` RATHER THAN AN `async` HANDLER, because ``FailureView`` takes a
    /// synchronous closure. It re-reads the list and touches nothing else.
    private func reloadCallbacks() {
        Task { await model.loadCallbacks() }
    }
}

extension DialerModel {
    /// The dialler already driving a call for this workspace, if there is one.
    ///
    /// ⛔ ONLY WHILE IT HAS A CALL TO SHOW: placing, live, or ended and still summarised.
    /// An idle model is never handed to a second screen, and one from another workspace
    /// never is either, since its call belongs to the tenant that placed it.
    static func attached(to calls: CallStack, workspaceId: String) -> DialerModel? {
        guard let live = calls.softphone as? DialerModel, live.workspaceId == workspaceId else { return nil }
        guard live.placing || live.call != nil else { return nil }
        return live
    }
}
