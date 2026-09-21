import DistrictData
import DistrictModel
import Foundation
import Observation

/// One recipient a new conversation can be started with.
///
/// ⛔ A CONTACT OR A TYPED ADDRESS, AND THE DIFFERENCE DECIDES WHERE THE CHANNEL COMES
/// FROM. A picked contact carries its own phone and email, so the choices are the
/// server's own columns; a typed address is one string whose channel this client has
/// to derive. ⚠️ Keeping the two apart in the type is what stops the derivation
/// leaking onto the contact path, where it would be a second, disagreeing decision
/// about a value the CRM already holds.
/// ⛔ NOT `Equatable`, DELIBERATELY, AND THE COMPILER IS THE ONLY THING THAT SAYS SO.
/// `Contact` is `Codable, Sendable` and `FailureText` is a bare struct; neither is
/// `Equatable` and nothing extends them to be, so a synthesised conformance cannot
/// exist. Every peer state enum in `App/` omits it for the same reason — there are
/// 40+ `case failed(FailureText)` sites and not one sits in an `Equatable` enum.
/// ⚠️ Add it only alongside a real need for `==` (a SwiftUI `.onChange(of:)` or
/// `.animation(_:value:)` on the state), and then by conforming the PAYLOAD types,
/// which is a public API change in DistrictCore rather than a one-line edit here.
enum ComposeRecipient {
    case contact(Contact)
    /// ⚠️ The operator's own text, trimmed once and carried verbatim thereafter. The
    /// server normalises it; this client does not, for the reason
    /// ``ConversationSummary/replyTargets`` gives about padded stored addresses.
    case typed(String)
}

/// What the compose sheet is doing about its recipient list.
///
/// ⚠️ `loading` IS THE FIRST PAGE ONLY. There is no paging on this screen: the
/// recipient field filters what one window returned, and the free-text path is what
/// covers everyone else. See ``ComposeModel/contacts``.
enum ComposeContactsState {
    case loading
    case ready([Contact])
    /// ⛔ A FAILED CONTACT READ MUST NOT CLOSE THE SHEET OR DISABLE THE FIELD. A
    /// number or an address typed by hand needs no CRM at all, so the failure is a
    /// caption beside a form that still works.
    case failed(FailureText)
}

/// What the send did.
enum ComposeSendState {
    case idle
    case sending
    /// ⛔ CARRIES THE ROUTE RATHER THAN A MESSAGE ID, because the id is not a
    /// destination. `messages/send` echoes a `Message` row; turning that into a thread
    /// takes a second request (see ``ComposeModel/resolve(_:)``), and the sheet must
    /// not dismiss until it knows whether it has somewhere to send the operator.
    ///
    /// ⛔ AND THE ROUTE IS OPTIONAL, WHICH IS THE WHOLE POINT OF THE CASE. nil means
    /// the message WENT OUT and the thread could not be resolved — a state that must
    /// never be rendered as a failed send, because the customer has the message and
    /// offering to send it again is a second charge and a duplicate. The sheet
    /// dismisses on it and the list behind refreshes; the new thread is at the top.
    case sent(Route?)
    case failed(FailureText)
}

/// Starting a conversation with somebody the Inbox has no thread for yet.
///
/// ⛔ WITHOUT THIS THE ONLY WAY INTO A THREAD IS TAPPING AN EXISTING ROW, WHICH MAKES
/// THE INBOX A READER RATHER THAN A CLIENT: an operator who wanted to text a customer
/// first would have to open the web dashboard.
///
/// ⛔ THE THREAD KEY IS RESOLVED BY THE SERVER AND NEVER COMPUTED HERE. It is
/// `contact:<id>` when the counterpart resolves to a `Contact` row and
/// `addr:<normalized>` when it does not — and for a brand-new address the client
/// cannot know which, because the send itself may CREATE the contact. So the flow is
/// send, then `GET /api/district/messages/{id}` with the row id the send echoed, then
/// navigate. Guessing instead would put a draft under a key nothing can restore and
/// open a second thread beside the one the message actually landed in.
///
/// ⚠️ IT MODELS THE SEND AND THE RESOLVE AS ONE STEP FOR THE OPERATOR AND TWO ON THE
/// WIRE, AND THE ORDER MATTERS: the send is the billable, non-idempotent half. If the
/// resolve fails, the message HAS gone out and the sheet must not offer to send it
/// again — see ``ComposeSendState/sent(_:)`` and ``resolve(_:)``.
@MainActor
@Observable
final class ComposeModel {
    /// ⚠️ ONE WINDOW, SIZED LIKE THE CONTACTS SCREEN'S PAGE. See ``contacts``.
    static let contactWindow = 50

    private(set) var contactsState: ComposeContactsState = .loading
    private(set) var sendState: ComposeSendState = .idle

    /// The recipient box's text, and the filter over ``contacts``.
    ///
    /// ⚠️ ONE FIELD FOR BOTH JOBS, WHICH IS THE WHOLE INTERACTION. Typing narrows the
    /// contact list AND is itself a valid recipient, so a stranger's number needs no
    /// mode switch — the operator types it and sends. A separate "or enter a number"
    /// box would make the common case (a customer already in the CRM) and the
    /// uncommon one look equally likely.
    var query = ""

    /// Which recipient is armed, or nil while the operator is still choosing.
    private(set) var recipient: ComposeRecipient?

    /// Which of ``channelChoices`` is armed.
    private(set) var selectedChannel = 0

    let workspaceId: String

    /// ⛔ EVERY WRITE ON THIS SHEET EXCLUDES `viewer` SERVER-SIDE (`messages/send`,
    /// and the resolver it is followed by), so the control is not offered at all
    /// rather than offered and refused.
    ///
    /// ⚠️ IT ERRS LOW: a nil role means "the role could not be established", never
    /// "assume client". ``WorkspaceRole/fromWire(_:)`` fails closed.
    let canSend: Bool

    private let inbox: InboxRepository
    private let contactsRepository: ContactsRepository
    private let role: WorkspaceRole?

    /// ⚠️ TAKES THE CONTAINER, NEVER A REPOSITORY. Each one is a `let` on the
    /// container built from the one ``ApiClient``; a repository constructed here would
    /// reach a second ``TokenRefreshCoordinator``.
    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        canSend = WorkspaceRole.allowsMutation(role)
        inbox = container.inbox
        contactsRepository = container.contacts
    }

    // MARK: - Recipients

    /// The contacts the recipient field can match against.
    ///
    /// ⛔ ONE WINDOW, FILTERED LOCALLY, AND THAT IS A SERVER LIMIT RATHER THAN A
    /// SHORTCUT. `GET /api/district/contacts` takes `limit` and `offset` and NOTHING
    /// ELSE — there is no `q` parameter to send, unlike `messages/search`. So this
    /// reads the newest window and filters it here.
    ///
    /// ⛔ WHICH MEANS THE MATCH IS INCOMPLETE, AND THE FREE-TEXT PATH IS WHY THAT IS
    /// ACCEPTABLE RATHER THAN HIDDEN. A contact outside the window will not appear in
    /// the suggestions, and the operator can still reach them by typing the number or
    /// the address — which produces the same send, and the same thread, because the
    /// server resolves the counterpart to the existing `Contact` row either way. ⚠️ The
    /// sheet says so in its own caption rather than presenting a short list as if it
    /// were the whole CRM.
    private(set) var contacts: [Contact] = []

    /// Open the form: clear the last attempt, then read the first window of contacts.
    ///
    /// ⛔ THE RESET IS HERE RATHER THAN IN THE SHEET'S OWN `@State`, BECAUSE THE MODEL
    /// OUTLIVES THE SHEET. It is held at the inbox screen's scope so a presentation
    /// cannot rebuild it mid-flight, which means a cancelled compose would otherwise
    /// leave its recipient, its channel choice and its failure sentence sitting in a
    /// form the operator reopened expecting a blank one. The typed MESSAGE lives on the
    /// sheet and goes with it, which is the same split ``DeskComposeSheet`` uses.
    ///
    /// ⚠️ THE CONTACT WINDOW IS RE-READ ON EVERY OPEN RATHER THAN CACHED. It is one
    /// indexed page and a contact added since the last open — by this operator, on
    /// another device, or by the voice agent from an inbound call — has to be in the
    /// list; caching it would make the suggestion list quietly older than the CRM.
    ///
    /// ⚠️ FAIL-SOFT. A failure leaves the form usable and says so in a caption,
    /// because typing an address needs no CRM read at all — refusing to compose
    /// because a suggestion list could not load would be strictly worse than
    /// composing without suggestions.
    func prepare() async {
        query = ""
        recipient = nil
        selectedChannel = 0
        sendState = .idle
        contactsState = .loading
        let pager = contactsRepository.pager(workspaceId: workspaceId)
        switch await pager.loadNext(limit: Self.contactWindow) {
        case let .success(slice):
            contacts = slice.items
            contactsState = .ready(slice.items)
        case let .failure(error):
            contacts = []
            contactsState = .failed(FailureText.from(error))
        }
    }

    /// The contacts matching what has been typed.
    ///
    /// ⚠️ NAME, NUMBER **AND** ADDRESS, CASE-INSENSITIVELY, because an operator
    /// starting a conversation is as likely to remember a phone number as a name — and
    /// because a contact whose name is the literal "Unknown" (what the voice agent
    /// writes for an unidentified caller) is only findable by its number.
    ///
    /// ⚠️ AN EMPTY QUERY SHOWS THE WINDOW AS IT CAME, newest first, which is the
    /// server's own order and a useful default: the person you just spoke to is near
    /// the top.
    var matches: [Contact] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return contacts }
        return contacts.filter { contact in
            [contact.name, contact.phoneNumber ?? "", contact.email ?? ""]
                .contains { $0.lowercased().contains(needle) }
        }
    }

    /// Arm a contact as the recipient.
    ///
    /// ⚠️ IT RESETS THE CHANNEL TO THE FIRST CHOICE. A selection carried over from a
    /// previous recipient could name a channel this one has no address for, and the
    /// index would then point past the end.
    func choose(_ contact: Contact) {
        recipient = .contact(contact)
        selectedChannel = 0
        clearFailure()
    }

    /// Arm whatever is in the box as a raw address.
    ///
    /// ⚠️ REFUSES A BLANK STRING AND VALIDATES NOTHING ELSE. The server owns address
    /// validation and its refusals are specific (an unverified sender, an unroutable
    /// number); a client-side regex here would refuse international formats it had not
    /// been taught and would tell the operator their customer's number is wrong.
    func useTypedAddress() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recipient = .typed(trimmed)
        selectedChannel = 0
        clearFailure()
    }

    /// Go back to choosing.
    func clearRecipient() {
        recipient = nil
        selectedChannel = 0
        clearFailure()
    }

    func selectChannel(_ index: Int) {
        guard channelChoices.indices.contains(index) else { return }
        selectedChannel = index
    }

    private func clearFailure() {
        if case .failed = sendState {
            sendState = .idle
        }
    }
}

/// The channel choice, and the one place in this client where a channel is DERIVED
/// from the shape of an address.
///
/// ⛔ THIS IS THE EXCEPTION ``ReplyTarget`` EXISTS TO FORBID EVERYWHERE ELSE, AND IT
/// IS CORRECT HERE FOR ONE REASON: THERE IS NO SERVER ANSWER TO CARRY. Every other
/// producer of a ``ReplyTarget`` reads `canSms`/`canEmail` off a row the server
/// computed — ``ConversationSummary/replyTargets`` from `conversations`,
/// ``ResolvedThread/replyTarget`` from `messages/{id}` — because a thread that exists
/// has a server-decided answer about how it can be reached. An address the operator
/// has just typed has NO THREAD, no `Contact` row of its own necessarily, and
/// therefore no such answer: there is nothing to ask and nothing to carry. The
/// alternative is not "ask the server", it is "refuse to let anyone start a
/// conversation", which is the gap this sheet closes.
///
/// ⛔ SO THE DERIVATION IS CONFINED TO ``ComposeRecipient/typed(_:)`` AND MUST STAY
/// THERE. A picked contact takes its choices from the CRM's own columns
/// (``Contact/phoneNumber``, ``Contact/email``) rather than from an `@` test, because
/// for that recipient a stored answer DOES exist and a derivation beside it would be a
/// second, disagreeing decision about the same value. ⛔ And nothing here may be
/// copied into the thread screen, the search path or the notification path: all three
/// have a server answer, and ignoring it produces a known bug (a reply box deciding
/// that a customer who had only ever emailed cannot be texted).
///
/// ⚠️ THE SERVER'S OWN FALLBACK IS THE SAME TEST, WHICH IS WHY IT IS THE RIGHT ONE.
/// `messages/{id}` picks the reply channel from the stored `type` first and falls back
/// to email when the counterpart is an email address and SMS otherwise, and the
/// server's address normaliser decides that on an `@`. Matching it means a typed address and
/// the thread it creates agree about the channel from the first message onwards.
extension ComposeModel {
    /// Every channel the armed recipient can be reached on, best first.
    ///
    /// ⛔ ORDERED SMS-FIRST FOR A CONTACT WITH BOTH, WHICH IS THE OPPOSITE ORDERING
    /// PROBLEM FROM A REPLY AND THEREFORE A DIFFERENT ANSWER. `replyTargets` prefers
    /// the channel the customer has already used, because answering an email by text
    /// is a surprise; here there is no history to follow, and the ordering falls back
    /// to the same SMS-first default `replyTargets` uses when `channels` is empty.
    /// ⚠️ Both choices are drawn, so nothing is hidden behind the default.
    ///
    /// ⚠️ A CONTACT WITH NEITHER ADDRESS PRODUCES AN EMPTY LIST AND CANNOT BE SENT TO.
    /// The CRM is email-first and admits phone-less rows, so a row with no email and no
    /// number is legal; ``canSendNow`` refuses rather than the sheet offering a Send
    /// whose request has no `to`.
    var channelChoices: [ReplyTarget] {
        // ⚠️ UNWRAPPED FIRST RATHER THAN SWITCHED OVER THE OPTIONAL. Matching an enum's
        // cases directly against an `Optional` of it works for simple cases and reads
        // ambiguously with associated values; one `guard` costs a line and cannot be
        // misread.
        guard let recipient else { return [] }
        switch recipient {
        case let .contact(contact):
            return Self.choices(for: contact)
        case let .typed(address):
            return [ReplyTarget(to: address, channel: Self.derivedChannel(of: address))]
        }
    }

    /// The pair the send will use.
    var target: ReplyTarget? {
        let choices = channelChoices
        guard choices.indices.contains(selectedChannel) else { return nil }
        return choices[selectedChannel]
    }

    /// True when the outgoing channel is email, and therefore needs a subject.
    ///
    /// ⛔ THE SAME RULE THE THREAD COMPOSER ENFORCES, AND FOR THE SAME REASON:
    /// `messages/send` substitutes "Message from District" for an absent or blank
    /// subject and DELIVERS, so this is the last place a missing one can be caught. A
    /// first email to a customer titled with our own literal is worse here than in a
    /// reply, because it is the first thing they ever see from this workspace.
    var requiresSubject: Bool {
        target?.channel == MessageChannel.email
    }

    /// ⚠️ A CONTACT'S STORED COLUMNS, NEVER AN `@` TEST. See the ⛔ on this extension:
    /// for a contact a stored answer exists, so deriving one beside it would be a
    /// second decision about the same value.
    /// ⚠️ Blank is treated as absent, because both columns are free text on a row an
    /// operator can edit and a whitespace-only cell is not an address.
    private static func choices(for contact: Contact) -> [ReplyTarget] {
        var choices: [ReplyTarget] = []
        if let phone = usable(contact.phoneNumber) {
            choices.append(ReplyTarget(to: phone, channel: MessageChannel.sms))
        }
        if let email = usable(contact.email) {
            choices.append(ReplyTarget(to: email, channel: MessageChannel.email))
        }
        return choices
    }

    private static func usable(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// ⛔ AN `@` AND NOTHING ELSE, MATCHING THE SERVER ADDRESS NORMALISER'S OWN TEST. A
    /// richer guess (digit counting, a regex) would disagree with the server about
    /// exactly the inputs that are hard, and the server is the side that has to deliver
    /// the message.
    private static func derivedChannel(of address: String) -> String {
        address.contains("@") ? MessageChannel.email : MessageChannel.sms
    }
}

/// Sending the first message, and finding the thread it created.
extension ComposeModel {
    /// Whether Send may be offered at all.
    ///
    /// ⛔ IN FLIGHT MEANS NO, AND THAT GUARD IS ABOUT MONEY. Every send is a carrier
    /// segment or a Postmark send that has already been paid for, capped at 30/min per
    /// WORKSPACE, so a second tap must not become a second charge and a message the
    /// customer receives twice.
    ///
    /// ⛔ A BLANK BODY IS REFUSED EVEN WITH EVERYTHING ELSE FILLED IN, because
    /// `messages/send` guards on `!body` before it looks at anything else. And an email
    /// with no subject is refused for the reason ``requiresSubject`` gives: the server
    /// would accept it and substitute a literal, so nothing downstream can catch it.
    func canSendNow(body: String, subject: String) -> Bool {
        guard canSend, target != nil else { return false }
        if case .sending = sendState {
            return false
        }
        guard !isBlank(body) else { return false }
        guard requiresSubject else { return true }
        return !isBlank(subject)
    }

    /// Send the first message, then resolve the thread it landed in.
    ///
    /// ⛔ TWO REQUESTS, AND ONLY THE FIRST ONE SPENDS MONEY. The send is billable and
    /// non-idempotent; the resolve is a cheap authenticated GET. That asymmetry decides
    /// every failure decision below.
    ///
    /// ⛔ A FAILED **RESOLVE** MUST NOT LOOK LIKE A FAILED SEND. The message has gone
    /// out — the customer has it — so reporting "could not send" would invite the
    /// operator to send it again, which is a second charge and a duplicate message. The
    /// state goes to ``ComposeSendState/sent(_:)`` with no route, the sheet closes, and
    /// the inbox list refreshes: the new thread is at the top of it, which is one tap
    /// away rather than a lost message.
    ///
    /// ⛔ AND NOTHING IS RETRIED AUTOMATICALLY ON EITHER HALF. A send that timed out may
    /// well have landed, and `ApiClient` retries nothing, which is the other half of
    /// that guarantee.
    ///
    /// - Returns: true when the message went out, whether or not a thread could be
    ///   resolved. ⚠️ The caller dismisses on true and reads ``landing`` for the route;
    ///   false is a real failure and the sheet stays up holding what was typed.
    func send(body: String, subject: String) async -> Bool {
        guard canSendNow(body: body, subject: subject), let target else { return false }
        sendState = .sending

        let outcome = await inbox.send(
            workspaceId: workspaceId,
            target: target,
            body: body,
            // ⚠️ NEVER A BLANK STRING. `messages/send` reads
            // `(typeof subject === "string" && subject.trim()) || "Message from District"`,
            // so an empty subject and an absent one are the SAME thing to it — sending
            // `""` would look like a fix and be none.
            subject: requiresSubject && !isBlank(subject) ? subject : nil
        )
        switch outcome {
        case let .success(message):
            sendState = await .sent(resolve(message.id))
            return true
        case let .failure(error):
            // ⚠️ THE SERVER'S REFUSALS REACH THE OPERATOR VERBATIM — an unverified
            // sender, an exhausted A2P registration, the per-workspace cap. Each needs
            // a different action from them, and "could not send" throws all of it away.
            sendState = .failed(FailureText.from(error))
            return false
        }
    }

    /// Where the send landed, once it has.
    ///
    /// ⚠️ nil BOTH BEFORE A SEND AND AFTER ONE WHOSE RESOLVE FAILED, and the caller
    /// must not try to tell those apart from here: it dismisses on
    /// ``send(body:subject:)``'s own answer and reads this only to decide whether there
    /// is a thread to push.
    var landing: Route? {
        guard case let .sent(route) = sendState else { return nil }
        return route
    }

    /// Exchange the sent message's row id for the thread it belongs to.
    ///
    /// ⛔ THE CLIENT CANNOT COMPUTE THIS AND MUST NOT TRY. The thread key is
    /// `contact:<id>` when the counterpart resolves to a `Contact` and
    /// `addr:<normalized>` when it does not, and for a freshly typed address which one
    /// applies depends on whether a row already existed — a fact only the server holds,
    /// and one the send itself can change. A guessed key would store the composer's
    /// draft under something nothing can restore and open a thread beside the one the
    /// message is actually in.
    ///
    /// ⚠️ nil IS SURVIVABLE AND IS NOT REPORTED AS AN ERROR. See ``send(body:subject:)``.
    private func resolve(_ messageId: String) async -> Route? {
        guard case let .success(resolved) = await inbox.messageThread(
            workspaceId: workspaceId,
            messageId: messageId
        ) else {
            return nil
        }
        return .thread(
            workspaceId: workspaceId,
            role: role,
            threadKey: resolved.threadKey,
            // ⛔ THE SERVER'S OWN PAIR FROM HERE ON, NOT THE ONE THIS SHEET DERIVED.
            // The thread exists now, so it has a server-decided answer, and the
            // resolver's `counterpart` is the UNWRAPPED address. Carrying the typed
            // string forward instead would keep this screen's derivation alive on a
            // surface that no longer needs it.
            replyTargets: [resolved.replyTarget],
            // ⚠️ NO TITLE. The route's title is the counterpart name the LIST resolved,
            // and this path has not read the list; the thread screen falls back to a
            // neutral noun rather than asserting a name nobody supplied.
            title: nil
        )
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
