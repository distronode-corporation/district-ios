@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    static func configReads() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .workspaceConfig,
                DistrictEndpoints.workspaceConfig(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/config?workspaceId=ws_1"
            ),
        ]
    }

    static func configWrites() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .savePersona,
                DistrictEndpoints.savePersona(
                    workspaceId: "ws_1",
                    name: "Ada",
                    greeting: nil,
                    personality: nil,
                    dgiEnabled: true
                ),
                .patch,
                "\(host)/api/district/workspace/persona",
                .json(#"{"dgiEnabled":true,"name":"Ada","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .saveTools,
                DistrictEndpoints.saveTools(workspaceId: "ws_1", allowedTools: ["transfer_to_creator"]),
                .patch,
                "\(host)/api/district/workspace/tools",
                .json(#"{"allowedTools":["transfer_to_creator"],"workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .saveDirectory,
                DistrictEndpoints.saveDirectory(
                    workspaceId: "ws_1",
                    callDirectory: [.object(["name": .string("Ops"), "phoneNumber": .string("+15555550123")])]
                ),
                .patch,
                "\(host)/api/district/workspace/directory",
                .json(#"{"callDirectory":[{"name":"Ops","phoneNumber":"+15555550123"}],"workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .saveRoutingRules,
                DistrictEndpoints.saveRoutingRules(workspaceId: "ws_1", routingRules: []),
                .post,
                "\(host)/api/district/workspace/routing-rules",
                .json(#"{"routingRules":[],"workspaceId":"ws_1"}"#)
            ),
        ]
    }

    /// Who answers a call, and whether the caller can be rung.
    ///
    /// ⛔ FOUR ROWS FOR TWO PATHS, and the two PATCH rows are where this table earns
    /// its keep. `saveCallHandling` drops a nil field through
    /// ``JSONValue/object(_:)``, so the body below proves that a mode-only save really
    /// does send only the mode — the route accepts either field alone and REFUSES a
    /// body carrying neither. And `appRingSeconds` is asserted as `20` rather than
    /// `20.0`: a `Double` that encodes with a decimal point is fractional as far as
    /// the route's `.int()` is concerned, and the refusal is a 400 nobody can act on.
    ///
    /// ⚠️ `saveAvailability` CARRIES NO IDENTITY, WHICH IS THE POINT OF PINNING ITS
    /// BODY BYTE FOR BYTE. The route writes the caller's own membership row and takes
    /// no email and no user id; a body that grew one would be the first step towards a
    /// UI that offers to set a colleague's availability.
    static func callHandling() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .callHandling,
                DistrictEndpoints.callHandling(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/call-handling?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .saveCallHandling,
                DistrictEndpoints.saveCallHandling(
                    workspaceId: "ws_1",
                    callHandling: "ai_then_app",
                    appRingSeconds: nil
                ),
                .patch,
                "\(host)/api/district/workspace/call-handling",
                .json(#"{"callHandling":"ai_then_app","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .availability,
                DistrictEndpoints.availability(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/availability?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .saveAvailability,
                DistrictEndpoints.saveAvailability(workspaceId: "ws_1", availableForCalls: true),
                .patch,
                "\(host)/api/district/workspace/availability",
                .json(#"{"availableForCalls":true,"workspaceId":"ws_1"}"#)
            ),
        ]
    }

    static func knowledge() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .knowledgeDocuments,
                DistrictEndpoints.knowledgeDocuments(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/knowledge?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .createDocument,
                DistrictEndpoints.createDocument(
                    workspaceId: "ws_1",
                    title: "Hours",
                    content: "Nine to five",
                    sourceType: nil,
                    sourceUrl: nil
                ),
                .post,
                "\(host)/api/district/workspace/knowledge",
                .json(#"{"content":"Nine to five","title":"Hours","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .deleteDocument,
                DistrictEndpoints.deleteDocument(workspaceId: "ws_1", documentId: "doc_1"),
                .delete,
                "\(host)/api/district/workspace/knowledge?workspaceId=ws_1&documentId=doc_1"
            ),
            EndpointExpectation(
                .knowledgeMode,
                DistrictEndpoints.knowledgeMode(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/knowledge-mode?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .saveKnowledgeMode,
                DistrictEndpoints.saveKnowledgeMode(workspaceId: "ws_1", mode: "linked"),
                .patch,
                "\(host)/api/district/workspace/knowledge-mode",
                .json(#"{"mode":"linked","workspaceId":"ws_1"}"#)
            ),
        ]
    }

    /// ⛔ THE PATHS ARE WRITTEN OUT RATHER THAN BUILT FROM `DistrictPaths`,
    /// like every other row here, and for this family it earns its keep twice
    /// over: `scheduling/sso` is one segment away and answers a 302 carrying a
    /// ONE-TIME sign-in credential, so a descriptor that reached it would spend
    /// that credential on a transport nobody sees. A table derived from the same
    /// constants would assert only that the code equals itself.
    static func scheduling() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .schedulingStatus,
                DistrictEndpoints.schedulingStatus(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/scheduling/status?workspaceId=ws_1"
            ),
            // ⚠️ THE WORKSPACE IS IN THE BODY AND NOT THE QUERY. The route reads
            // `req.json()` first and falls back to `searchParams`, so both would
            // work; the body is what the web client sends, and matching it keeps
            // a capture from one readable as the other.
            EndpointExpectation(
                .schedulingEnable,
                DistrictEndpoints.schedulingEnable(workspaceId: "ws_1"),
                .post,
                "\(host)/api/district/scheduling/enable",
                .json(#"{"workspaceId":"ws_1"}"#)
            ),
            // ⚠️ `next` IS ABSENT FROM THE BODY, NOT NULL. `JSONValue.object` drops a
            // nil pair so the route's own default fires; an explicit null is a value
            // zod would not default over. Same decision as `registerPushToken`'s
            // `kind`, and the row pins the dropped-key shape rather than the sent one.
            EndpointExpectation(
                .schedulingHandoff,
                DistrictEndpoints.schedulingHandoff(workspaceId: "ws_1"),
                .post,
                "\(host)/api/district/scheduling/handoff",
                .json(#"{"workspaceId":"ws_1"}"#)
            ),
        ]
    }

    static func messagingReads() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .messaging,
                DistrictEndpoints.messaging(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/messaging?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .saveMessagingAccount,
                DistrictEndpoints.saveMessagingAccount(
                    workspaceId: "ws_1",
                    account: MessagingAccountDraft(
                        activeProvider: "twilio",
                        credentialSource: "byok",
                        providerConfig: providerConfig,
                        makeDefault: true
                    )
                ),
                .patch,
                "\(host)/api/district/workspace/messaging",
                .json(
                    #"{"activeProvider":"twilio","credentialSource":"byok","makeDefault":true,"#
                        + #""providerConfig":{"accountSid":"AC1"},"workspaceId":"ws_1"}"#
                )
            ),
        ]
    }

    static func messagingActions() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .setDefaultAccount,
                DistrictEndpoints.setDefaultAccount(workspaceId: "ws_1", accountId: "acct-1"),
                .patch,
                "\(host)/api/district/workspace/messaging",
                .json(#"{"accountId":"acct-1","action":"setDefault","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .setChannelDefault,
                DistrictEndpoints.setChannelDefault(workspaceId: "ws_1", channel: "sms", accountId: "acct-1"),
                .patch,
                "\(host)/api/district/workspace/messaging",
                .json(
                    #"{"accountId":"acct-1","action":"setChannelDefault","channel":"sms","workspaceId":"ws_1"}"#
                )
            ),
            EndpointExpectation(
                .deleteMessagingAccount,
                DistrictEndpoints.deleteMessagingAccount(workspaceId: "ws_1", accountId: "acct-1"),
                .patch,
                "\(host)/api/district/workspace/messaging",
                .json(#"{"accountId":"acct-1","action":"delete","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .saveCreatorCell,
                DistrictEndpoints.saveCreatorCell(workspaceId: "ws_1", creatorCellNumber: "+15555550123"),
                .patch,
                "\(host)/api/district/workspace/messaging",
                .json(#"{"action":"meta","creatorCellNumber":"+15555550123","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .testMessagingCredentials,
                DistrictEndpoints.testMessagingCredentials(workspaceId: "ws_1", providerConfig: providerConfig),
                .post,
                "\(host)/api/district/workspace/messaging/test",
                .json(#"{"providerConfig":{"accountSid":"AC1"},"workspaceId":"ws_1"}"#)
            ),
        ]
    }
}
