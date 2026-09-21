@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    /// The two Guideline 1.2 moderation rows.
    ///
    /// ⛔ THE BODY IS ASSERTED BYTE-EXACT AND IT IS THE ONLY THING PINNING THIS
    /// WIRE SHAPE. Neither route has a contract fixture — the corpus is generated
    /// by the server's suite and owned by the Android side, and
    /// `ContractManifest.expectedFixtureCount` asserts EXACTLY the files on disk —
    /// so these strings and `ContactBlockBodies` are the whole contract on this
    /// client. Same position `createContact` is in.
    ///
    /// ⛔ ONE ROW PER ENDPOINT AND THE SECOND BODY SHAPE LIVES ELSEWHERE, WHICH IS
    /// FORCED RATHER THAN CHOSEN. `testEveryEndpointHasExactlyOneRow` asserts
    /// `Set(ids).count == ids.count`, so a second `.setContactBlocked` row for the
    /// by-number/unblock form would fail the table outright. That shape matters —
    /// ``JSONValue/object(_:)`` drops a nil pair silently by design, so "did this
    /// request carry a `phoneNumber`" is a question about the encoded document
    /// rather than about the arguments, and the by-number call is the one an inbox
    /// thread with an unresolved counterpart makes — so it is pinned byte-exact in
    /// `ContactsBlockRepositoryTests` instead, off `RepositoryTransport.bodies`.
    /// Same instrument, different file.
    ///
    /// ⚠️ `blocked` IS A JSON BOOLEAN, NOT THE STRING "true". The route's Zod schema
    /// is `z.boolean()`, and a stringly-typed flag is the shape that would 400 with
    /// a message about the wrong field.
    /// ⚠️ NO "/" IN ANY VALUE, deliberately: Linux's `JSONEncoder` escapes it as
    /// `\/` and Darwin's does not, so a URL here would make a byte-exact assertion
    /// pass on one platform and fail on the other.
    static func blocking() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .setContactBlocked,
                DistrictEndpoints.setContactBlocked(
                    workspaceId: "ws_1",
                    contactId: "c_1",
                    phoneNumber: nil,
                    blocked: true
                ),
                .post,
                "\(host)/api/district/contacts/block",
                .json(#"{"blocked":true,"contactId":"c_1","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .blockedContacts,
                DistrictEndpoints.blockedContacts(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/contacts/blocked?workspaceId=ws_1"
            ),
        ]
    }
}
