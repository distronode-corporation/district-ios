@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    static func contactReads() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .contacts,
                DistrictEndpoints.contacts(workspaceId: "ws_1", limit: 25, offset: 0),
                .get,
                "\(host)/api/district/contacts?workspaceId=ws_1&limit=25&offset=0"
            ),
            EndpointExpectation(
                .contact,
                DistrictEndpoints.contact(workspaceId: "ws_1", contactId: "c_1"),
                .get,
                "\(host)/api/district/contacts/get?workspaceId=ws_1&contactId=c_1"
            ),
        ]
    }

    static func contactWrites() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .createContact,
                DistrictEndpoints.createContact(
                    workspaceId: "ws_1",
                    name: "Ada",
                    phoneNumber: nil,
                    email: "ada@example.com"
                ),
                .post,
                "\(host)/api/district/contacts/create",
                .json(#"{"email":"ada@example.com","name":"Ada","workspaceId":"ws_1"}"#)
            ),
            // ⛔ EVERY FIELD POPULATED, BECAUSE THE ROUTE REPLACES EVERY COLUMN
            // IT KNOWS ABOUT. This case is what pins the eight wire key names
            // against the route's zod schema. A name-only body reads as correct
            // while the caller it describes clears four columns on every
            // rename.
            // ⚠️ NO "/" IN ANY VALUE, deliberately: Linux's JSONEncoder escapes
            // it as `\/` and Darwin's does not, so a URL here would make this
            // byte-exact assertion pass on one platform and fail on the other.
            EndpointExpectation(
                .updateContact,
                DistrictEndpoints.updateContact(
                    workspaceId: "ws_1",
                    contactId: "c_1",
                    fields: ContactUpdateFields(
                        name: "Ada L",
                        phoneNumber: "+14165550134",
                        email: "ada@example.com",
                        linkedin: "in-ada",
                        contextSummary: "Asked about a survey.",
                        budget: "5k-10k",
                        timeline: "Q4",
                        website: "example.com"
                    )
                ),
                .patch,
                "\(host)/api/district/contacts/update",
                .json(
                    #"{"budget":"5k-10k","contactId":"c_1","contextSummary":"Asked about a survey.","#
                        + #""email":"ada@example.com","linkedin":"in-ada","name":"Ada L","#
                        + #""phoneNumber":"+14165550134","timeline":"Q4","website":"example.com","#
                        + #""workspaceId":"ws_1"}"#
                )
            ),
            EndpointExpectation(
                .deleteContact,
                DistrictEndpoints.deleteContact(workspaceId: "ws_1", contactId: "c_1"),
                .delete,
                "\(host)/api/district/contacts/delete?workspaceId=ws_1&contactId=c_1"
            ),
        ]
    }

    static func dgi() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .enrichContact,
                DistrictEndpoints.enrichContact(workspaceId: "ws_1", contactId: "c_1"),
                .post,
                "\(host)/api/district/contacts/enrich",
                .json(#"{"contactId":"c_1","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .clearContactIntel,
                DistrictEndpoints.clearContactIntel(workspaceId: "ws_1", contactId: "c_1"),
                .post,
                "\(host)/api/district/contacts/clear-intel",
                .json(#"{"contactId":"c_1","workspaceId":"ws_1"}"#)
            ),
        ]
    }

    static func inboxReads() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .conversations,
                DistrictEndpoints.conversations(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/conversations?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .timeline,
                DistrictEndpoints.timeline(workspaceId: "ws_1", contactId: "c_1", address: nil),
                .get,
                "\(host)/api/district/timeline?workspaceId=ws_1&contactId=c_1"
            ),
            EndpointExpectation(
                .unreadCount,
                DistrictEndpoints.unreadCount(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/messages/unread-count?workspaceId=ws_1"
            ),
            // ⚠️ THE QUERY VALUE CARRIES A SPACE, DELIBERATELY. `q` is free text
            // typed by a person, so percent-encoding it is the one thing about
            // this URL that can be wrong, and a single-word fixture would not
            // exercise it. ⚠️ No "/" in it: Linux escapes that as `\/` in JSON
            // bodies and Darwin does not, and keeping the two platforms' fixtures
            // identical is cheaper than reasoning about which assertions care.
            EndpointExpectation(
                .searchMessages,
                DistrictEndpoints.searchMessages(workspaceId: "ws_1", query: "survey booking"),
                .get,
                "\(host)/api/district/messages/search?workspaceId=ws_1&q=survey%20booking"
            ),
            // ⚠️ A PLAIN ID HERE, AND THE HOSTILE ONE IS PINNED IN
            // `EndpointSurfaceTests` AGAINST ``ApiPath/build(_:)`` INSTEAD. This row
            // asserts the whole absolute URL, which goes through `URL(string:)`, and
            // that is the wrong instrument for a traversal case: the question is
            // whether the SEGMENT ENCODER keeps a `/` inside one segment, not what
            // Foundation's URL parser does with the result. The existing
            // `testAnIdCannotTraverseIntoAnotherRoute` asks it the right way.
            // ⚠️ It is still the only row in this group whose path is not a literal.
            EndpointExpectation(
                .messageThread,
                DistrictEndpoints.messageThread(workspaceId: "ws_1", id: "msg_1"),
                .get,
                "\(host)/api/district/messages/msg_1?workspaceId=ws_1"
            ),
        ]
    }

    static func inboxWrites() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .sendMessage,
                DistrictEndpoints.sendMessage(
                    workspaceId: "ws_1",
                    to: "+15555550123",
                    body: "on my way",
                    channel: "sms",
                    subject: nil,
                    mediaUrls: ["https://www.distronode.com/api/media/abc"]
                ),
                .post,
                "\(host)/api/district/messages/send",
                .json(
                    #"{"body":"on my way","channel":"sms","#
                        + #""mediaUrls":["https://www.distronode.com/api/media/abc"],"#
                        + #""to":"+15555550123","workspaceId":"ws_1"}"#
                )
            ),
            EndpointExpectation(
                .markRead,
                DistrictEndpoints.markRead(workspaceId: "ws_1", contactId: "c_1", counterpart: nil),
                .post,
                "\(host)/api/district/messages/mark-read",
                .json(#"{"contactId":"c_1","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .uploadMedia,
                DistrictEndpoints.uploadMedia(
                    workspaceId: "ws_1",
                    fileName: "photo.jpg",
                    mimeType: "image/jpeg",
                    bytes: Data([0xFF, 0xD8])
                ),
                .post,
                "\(host)/api/district/messages/media",
                // ⛔ THE WORKSPACE IS A FORM FIELD HERE AND A QUERY PARAMETER ON
                // `desk/logo`, the only other multipart route on this surface. This
                // route reads `req.formData()`; that one reads `searchParams`. The
                // pair is spelled out per row precisely so neither can be copied onto
                // the other, which would leave the target route's guard with null.
                .multipart(fields: ["workspaceId": "ws_1"], fileName: "photo.jpg")
            ),
        ]
    }
}
