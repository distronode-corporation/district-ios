@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    static func composerReads() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .draft,
                DistrictEndpoints.draft(workspaceId: "ws_1", threadKey: "t_1"),
                .get,
                "\(host)/api/district/messages/drafts?workspaceId=ws_1&threadKey=t_1"
            ),
            EndpointExpectation(
                .drafts,
                DistrictEndpoints.drafts(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/messages/drafts?workspaceId=ws_1"
            ),
        ]
    }

    static func composerWrites() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .saveDraft,
                DistrictEndpoints.saveDraft(
                    workspaceId: "ws_1",
                    threadKey: "t_1",
                    body: "hi",
                    mediaUrls: ["https://www.distronode.com/api/media/abc"]
                ),
                .put,
                "\(host)/api/district/messages/drafts",
                .json(
                    #"{"body":"hi","mediaUrls":["https://www.distronode.com/api/media/abc"],"#
                        + #""threadKey":"t_1","workspaceId":"ws_1"}"#
                )
            ),
            EndpointExpectation(
                .deleteDraft,
                DistrictEndpoints.deleteDraft(workspaceId: "ws_1", threadKey: "t_1"),
                .delete,
                "\(host)/api/district/messages/drafts?workspaceId=ws_1&threadKey=t_1"
            ),
            EndpointExpectation(
                .generateDraft,
                DistrictEndpoints.generateDraft(workspaceId: "ws_1", contactId: "c_1", phoneNumber: nil),
                .post,
                "\(host)/api/district/messages/draft",
                .json(#"{"contactId":"c_1","workspaceId":"ws_1"}"#)
            ),
        ]
    }

    static func hq() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .hqPrompt,
                DistrictEndpoints.hqPrompt(workspaceId: "ws_1", prompt: "how many calls today"),
                .post,
                "\(host)/api/district/hq",
                .json(#"{"history":[],"prompt":"how many calls today","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .hqConfirm,
                DistrictEndpoints.hqConfirm(
                    workspaceId: "ws_1",
                    tool: "delete_contact",
                    args: .object(["contactId": .string("c_1")])
                ),
                .post,
                "\(host)/api/district/hq",
                .json(#"{"confirm":{"args":{"contactId":"c_1"},"tool":"delete_contact"},"workspaceId":"ws_1"}"#)
            ),
        ]
    }

    static func usage() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .analytics,
                DistrictEndpoints.analytics(workspaceId: "ws_1", range: .ninetyDays),
                .get,
                "\(host)/api/district/analytics?workspaceId=ws_1&timeRange=90d"
            ),
            EndpointExpectation(
                .usage,
                DistrictEndpoints.usage(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/usage?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .usageHistory,
                DistrictEndpoints.usageHistory(workspaceId: "ws_1", months: 6),
                .get,
                "\(host)/api/district/workspace/usage?workspaceId=ws_1&history=true&months=6"
            ),
        ]
    }

    static func numbers() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .searchNumbers,
                DistrictEndpoints.searchNumbers(
                    workspaceId: "ws_1",
                    areaCode: "416",
                    country: nil,
                    type: nil,
                    provider: nil
                ),
                .get,
                "\(host)/api/district/workspace/numbers/search?workspaceId=ws_1&areaCode=416"
            ),
            EndpointExpectation(
                .ownedNumbers,
                DistrictEndpoints.ownedNumbers(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/provider/numbers?workspaceId=ws_1"
            ),
        ]
    }
}
