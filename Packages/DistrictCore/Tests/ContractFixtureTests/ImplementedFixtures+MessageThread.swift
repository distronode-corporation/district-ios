import DistrictModel
import Foundation

// The message-to-thread resolver's fixture, in a file of its own.
//
// ⛔ SPLIT OUT BECAUSE `ImplementedFixtures.swift` IS AT ITS 500-LINE CEILING, not
// for taste, and not because one gate deserves a file. SwiftLint's `file_length`
// warning is an ERROR under `--strict`, so a single line added inline reds the LINT
// job rather than the gate — a failure a long way from the change that caused it.
// The other `ImplementedFixtures+*.swift` files took the same split for the same
// reason; extensions here are expected to be siblings rather than the only one.
// ⚠️ NO LINE COUNT IS QUOTED: the ceiling is the durable fact and that file's
// current length is not, because more than one change adds to the list.
//
// ⚠️ `gate` IS ALREADY INTERNAL, so this file widens nothing.

extension ImplementedFixtures {
    // MARK: - One message id, resolved into a thread

    /// ⛔ GATING A FIXTURE THAT IS ALREADY ON DISK MOVES FOUR COUNTERS IN THREE
    /// DIRECTIONS. Landing the ``EndpointID``, the descriptor,
    /// ``MessageThreadResponse`` and the repository method together means:
    /// `EndpointTableTests`' total goes up by one, `TypedEndpoints` goes up by one,
    /// ``UntypedEndpoints/all`` does NOT move (the route was never reachable, so it
    /// was never on that list), and ``ContractManifest/expectedFixtureCount`` does
    /// NOT move either — nothing new lands on disk. Re-derive each from its own list.
    ///
    /// ⛔ AND IT TAKES ONE ALLOWLIST ENTRY WITH IT, `$.message.readAt`. That is the
    /// unread inbound message a push is about, which is the ORDINARY state for this
    /// route: the notification exists because nobody has read the message yet. The
    /// entry is a DECISION recorded in two files —
    /// `AllowedExplicitNulls+Inbox.swift` and
    /// ``ContractManifest/fixturesWithAllowedNulls`` — and it buys exactly two
    /// exemptions at exactly that path.
    ///
    /// ⚠️ WHAT THE FIXTURE DOES **NOT** PROVE IS THE ADDRESS-KEYED THREAD. Its
    /// `thread.contactId` is populated and its `thread.threadKey` is
    /// `contact:contact_contract_1`, so the `addr:<key>` / `contactId: null` branch —
    /// a stranger who has just written in, which is the common case for a first
    /// inbound message — has no fixture in the corpus. That branch is exercised in
    /// `InboxThreadResolveTests` against bytes instead, the same way
    /// `district-draft-null.json`'s null draft is. ⛔ Do not "fix" it by writing a
    /// second fixture: the corpus belongs to the Android side, and a file added here
    /// fails ``ContractManifest/expectedFixtureCount`` on both clients.
    static var messageThread: [ImplementedFixture] {
        [
            gate("district-message-thread.json", MessageThreadResponse.self),
        ]
    }
}
