import Foundation

/// `GET /api/district/conversations?workspaceId=` — the unified Inbox list.
///
/// ⛔ "UNIFIED" IS THE WHOLE POINT, AND IT IS WHY ``ConversationSummary/threadKey``
/// EXISTS. One thread can mix SMS and email, because a customer's phone number
/// and their email address are two different strings that resolve to the same
/// Contact. The server folds them; a client that keyed this list by address
/// instead would show the same person twice and split their history.
///
/// ⚠️ NOT PAGED, AND THAT IS A SERVER PROPERTY THIS CLIENT MUST RESPECT. The
/// server scans a bounded window of recent messages (``scanLimit``, 500) and
/// groups what it finds — so this is "recent conversations", not "all
/// conversations", and there is no page to request.
public struct ConversationsResponse: Codable, Sendable {
    public let success: Bool
    public let conversations: [ConversationSummary]
    /// How many messages the server actually scanned to build this list.
    ///
    /// ⚠️ `scanned == scanLimit` MEANS THE LIST MAY BE INCOMPLETE — an older
    /// conversation with no recent traffic falls outside the window entirely. It
    /// is not an error and there is nothing to fetch; it is a truthfulness
    /// signal, and the UI says so rather than implying the list is everything.
    /// `DistrictData.ConversationList.isPartial` is where that comparison lives.
    public let scanned: Int
    public let scanLimit: Int
}

/// One thread in the Inbox.
///
/// ⚠️ ``key`` AND ``kind`` ARE MODELLED EVEN THOUGH BOTH ARE DEPRECATED
/// SERVER-SIDE, AND THAT IS A REVERSAL THE KOTLIN CLIENT ALREADY MADE. Omitting
/// them is not neutral: the strict gate compares key sets, so an unmodelled
/// field is a dropped key and a hard failure — relaxing the gate for this one
/// type would retire the check that catches a genuinely NEW field. They are
/// carried and documented instead.
///
/// ⚠️ NOT MARKED `@available(*, deprecated)`, DELIBERATELY. Swift applies that
/// attribute to the SYNTHESISED `Codable` conformance's own accesses, so the
/// whole module would warn on every build about code nobody wrote. The ⛔s below
/// are the deprecation.
public struct ConversationSummary: Codable, Sendable {
    /// The normalized address of the thread's most recent message.
    ///
    /// ⛔ NOT THREAD IDENTITY, AND SUPERSEDED BY ``threadKey``. The server keeps
    /// it only so a browser running a previous JS bundle against a freshly
    /// deployed server keeps working. One customer's phone and their email are
    /// two different strings, so this cannot identify a thread that mixes
    /// channels — the fixture's folded thread has `key = "ada@contract.test"`
    /// while carrying SMS from the contact's phone number.
    public let key: String
    /// Stable thread identity: `contact:<id>` when the counterpart resolves to a
    /// Contact, `addr:<normalized>` when it does not.
    ///
    /// ⛔ THE LIST KEY, AND THE ONLY SAFE ONE. Keying a list on the counterpart
    /// address produces duplicate identifiers the moment one person's SMS and
    /// email fold together.
    public let threadKey: String
    /// The counterpart as stored on the most recent message, in display form.
    public let counterpart: String
    /// Every normalized address that folds into this thread — a contact-keyed
    /// thread carries the phone AND the email, so a deep link or a search hit on
    /// either one lands on the already-open conversation.
    public let matchKeys: [String]
    /// The message type of the thread's most recent message.
    ///
    /// ⛔ NOT A THREAD PROPERTY, AND SUPERSEDED BY ``channels``. A thread that
    /// mixes SMS and email has no single kind, and reading this one is how the
    /// web's reply box decided a customer who had only ever emailed could not be
    /// sent an SMS.
    public let kind: String
    /// Distinct message types present in the thread, e.g. `["sms", "email"]`.
    public let channels: [String]
    /// nil when the counterpart resolves to no Contact — an explicit null on the
    /// wire, which is what `district-conversations.json`'s second row pins.
    public let contactId: String?
    public let contactName: String?
    public let contactEmail: String?
    public let contactPhone: String?
    /// ⛔ SERVER-DECIDED, NEVER INFERRED FROM ``channels``. Deriving sendability
    /// from the thread's most recent message type means a customer who had only
    /// ever emailed could not be sent an SMS even when their contact record held
    /// a number.
    public let canSms: Bool
    public let canEmail: Bool
    public let lastMessage: ConversationLastMessage
    public let unreadCount: Int
    public let totalMessages: Int
}

public extension ConversationSummary {
    /// What to show as the thread's title.
    ///
    /// ⚠️ FALLS BACK TO THE RAW COUNTERPART, NEVER TO A PLACEHOLDER. An
    /// unresolved address IS the identity of that thread — a phone number is a
    /// perfectly good label, and "Unknown" would hide the one piece of
    /// information available.
    var displayName: String {
        guard let contactName, !contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return counterpart
        }
        return contactName
    }

    /// True when this thread has anything the operator has not seen.
    var hasUnread: Bool {
        unreadCount > 0
    }

    /// Where a reply to this thread actually goes, and on which channel.
    ///
    /// ⛔ THE RECIPIENT IS AN ADDRESS, NEVER A THREAD IDENTITY, AND THIS WAS A
    /// LIVE BUG ON THE OTHER CLIENT. `messages/send` takes `to` as a phone
    /// number or an email and hands it straight to the carrier or to Postmark —
    /// it does not resolve a Contact id. Sending ``threadKey``'s `contact:<id>`
    /// portion as `to` dispatches an SMS to a cuid, which fails at the provider
    /// and surfaces as a raw 500. Since the server folds any counterpart that
    /// resolves to a Contact into that form, that is MOST threads.
    ///
    /// ⛔ GATED ON ``canSms``/``canEmail``, WHICH ARE SERVER-DECIDED. Never infer
    /// sendability from ``channels``.
    ///
    /// ⚠️ THE DEFAULT IS THE FIRST OF ``replyTargets`` AND IS NO LONGER
    /// UNCONDITIONALLY SMS. The reasoning lives on that property.
    ///
    /// nil means the thread has nothing to reply on, and the caller must offer
    /// no reply box at all.
    var replyTarget: ReplyTarget? {
        replyTargets.first
    }

    /// Every channel this thread can be answered on, the best default first.
    ///
    /// ⛔ SMS MUST NOT WIN UNCONDITIONALLY, OR EMAIL GETS ANSWERED WITH BILLABLE
    /// SMS. ``canSms`` is `contact ? !!contactPhone : kind === "phone"`
    /// server-side, so ANY thread whose contact has a number on file is sendable
    /// by SMS — including a thread the customer has only ever emailed. A reply
    /// there costs a carrier segment and arrives outside the mail thread the
    /// customer was reading. The picker is the caller's job.
    ///
    /// ⛔ THIS IS A PREFERENCE, NOT A SENDABILITY TEST, AND THE DISTINCTION IS
    /// WHAT MAKES READING ``channels`` SAFE HERE. Sendability stays
    /// server-decided, which is what keeps the web's old bug dead: a customer who
    /// has only ever emailed is still reachable by SMS, because that target is
    /// still in this list. ``channels`` only decides which of two ALREADY
    /// PERMITTED channels a composer opens on.
    ///
    /// ⚠️ AN EMPTY ``channels`` DECIDES NOTHING. The server accumulates it from
    /// `Message.type`, which is nullable on rows written before that column
    /// existed, so a thread of such rows reports `[]` — an absence of evidence,
    /// and the order falls back to the previous SMS-first behaviour.
    ///
    /// ⚠️ WHATSAPP CANNOT BE ORDERED HERE AT ALL, AND THAT IS A WIRE GAP RATHER
    /// THAN AN OMISSION. `conversations` publishes no `canWhatsapp`, so a
    /// WhatsApp-only thread arrives with `canSms: true` (its `kind` is `phone`)
    /// and nothing that says WhatsApp is where the customer is. It goes out as
    /// SMS. ``MessageChannel/whatsapp`` has no producer in this client either;
    /// fixing it needs a server field, not a client rule.
    var replyTargets: [ReplyTarget] {
        var sms: [ReplyTarget] = []
        var email: [ReplyTarget] = []
        if canSms, let phone = address(stored: contactPhone, counterpartIsAnAddress: false) {
            sms.append(ReplyTarget(to: phone, channel: MessageChannel.sms))
        }
        if canEmail, let mailbox = address(stored: contactEmail, counterpartIsAnAddress: true) {
            email.append(ReplyTarget(to: mailbox, channel: MessageChannel.email))
        }
        // ⚠️ THE TWO CHECKS STAY SEQUENTIAL, NOT EXCLUSIVE. A thread the server marks
        // sendable on both, whose only usable address is an email, has to fall THROUGH
        // the SMS branch — otherwise a customer who can be reached becomes one who
        // cannot. That was true of the `if`/`if` this replaced and it is still the rule.
        return prefersEmail ? email + sms : sms + email
    }

    /// True when this thread's own traffic is email and never SMS.
    ///
    /// ⚠️ READ ONLY BY ``replyTargets``, and only to ORDER two channels the server
    /// has already permitted. Never to decide whether a channel is available at
    /// all — that is the ⛔ on ``canSms``.
    private var prefersEmail: Bool {
        channels.contains(MessageChannel.email) && !channels.contains(MessageChannel.sms)
    }

    /// The stored address for one channel, falling back to ``counterpart`` only
    /// when it is of the right kind.
    ///
    /// ⚠️ ONE HELPER FOR BOTH CHANNELS, because they differ in nothing but the
    /// `@` test — and two hand-inlined copies of this fallback are how one of
    /// them ends up sending an email address to a carrier.
    private func address(stored: String?, counterpartIsAnAddress: Bool) -> String? {
        if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        let fallback = counterpart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, fallback.contains("@") == counterpartIsAnAddress else { return nil }
        return counterpart
    }
}

/// A resolved reply destination: the address to send to, and the channel to send
/// on.
///
/// ⚠️ THE TWO TRAVEL TOGETHER ON PURPOSE. An email address on the `sms` channel
/// reaches the carrier branch, which does no address-shape validation, so the
/// pair has to be chosen in one place rather than assembled from two independent
/// decisions.
///
/// ⚠️ `Hashable` IS REQUIRED RATHER THAN CONVENIENT, AND IT IS SYNTHESISED. A
/// `Route` in the App target has to be `Hashable` — `NavigationPath` demands it,
/// and the thread destination now carries the whole ORDERED SET of targets so the
/// composer can offer a channel rather than merely naming one. Both stored
/// properties are `String`, so Swift synthesises the conformance and there is no
/// hand-written `hash(into:)` to keep in step with `==`.
/// ⛔ IT DOES NOT MAKE A TARGET A KEY. Two threads can legitimately share one
/// `(to, channel)` pair — the same person reached from a contact-keyed thread and
/// from an address-keyed one — so this type must never be used to identify a
/// thread. ``ConversationSummary/threadKey`` is what does that.
public struct ReplyTarget: Sendable, Hashable {
    public let to: String
    /// One of ``MessageChannel``'s values.
    public let channel: String

    /// ⛔ WRITTEN OUT BECAUSE A SYNTHESISED MEMBERWISE INITIALISER ON A PUBLIC
    /// STRUCT IS **INTERNAL**, AND WITHOUT THIS ONE NO CONSUMER OUTSIDE THIS
    /// MODULE CAN BUILD A TARGET AT ALL. ``ConversationSummary/replyTarget`` was
    /// the only producer, which is enough for a screen holding a row and not
    /// enough for the thread screen: `Route.thread` carries the address and the
    /// channel as two `String?`s (a `Route` has to be `Hashable` and
    /// self-describing after a process death) and reassembles the pair on
    /// arrival. The same trap is documented from the other side on
    /// `OffsetSlice`, which the app target genuinely cannot construct.
    ///
    /// ⚠️ IT DOES NOT WEAKEN THE ⚠️ ABOVE. The pair still has to be CHOSEN in one
    /// place — that place is ``ConversationSummary/replyTarget``, and every
    /// caller of this initialiser is carrying its answer rather than making its
    /// own. Never derive a channel here from the shape of an address.
    public init(to: String, channel: String) {
        self.to = to
        self.channel = channel
    }
}

/// The preview line under a thread's title.
public struct ConversationLastMessage: Codable, Sendable {
    public let body: String
    /// `inbound` or `outbound`.
    public let direction: String
    /// `sms`, `email` or `whatsapp` — ⚠️ nil on older rows, which is why this is
    /// the one Optional here.
    public let type: String?
    public let status: String
    /// ISO-8601, server-formatted. This module owns no date parsing.
    public let createdAt: String
}
