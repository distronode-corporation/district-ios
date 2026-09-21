@testable import DistrictNetwork
import Foundation

extension EndpointTable {
    static func membership() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .members,
                DistrictEndpoints.members(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/members?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .addMember,
                DistrictEndpoints.addMember(workspaceId: "ws_1", email: "ada@example.com", role: nil),
                .post,
                "\(host)/api/district/workspace/members",
                .json(#"{"email":"ada@example.com","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .changeMemberRole,
                DistrictEndpoints.changeMemberRole(workspaceId: "ws_1", email: "ada@example.com", role: "client"),
                .patch,
                "\(host)/api/district/workspace/members",
                .json(#"{"email":"ada@example.com","role":"client","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .removeMember,
                DistrictEndpoints.removeMember(workspaceId: "ws_1", email: "ada@example.com"),
                .delete,
                "\(host)/api/district/workspace/members?workspaceId=ws_1&email=ada%40example.com"
            ),
            EndpointExpectation(
                .renameWorkspace,
                DistrictEndpoints.renameWorkspace(workspaceId: "ws_1", name: "North Studio"),
                .patch,
                "\(host)/api/district/workspace/rename",
                .json(#"{"name":"North Studio","workspaceId":"ws_1"}"#)
            ),
        ]
    }

    static func workflows() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .workflows,
                DistrictEndpoints.workflows(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workflows?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .workflowRuns,
                DistrictEndpoints.workflowRuns(workspaceId: "ws_1", workflowId: "wf_1", limit: 10, offset: 0),
                .get,
                "\(host)/api/district/workflows/runs?workspaceId=ws_1&workflowId=wf_1&limit=10&offset=0"
            ),
            EndpointExpectation(
                .setWorkflowActive,
                DistrictEndpoints.setWorkflowActive(workspaceId: "ws_1", workflowId: "wf_1", active: false),
                .patch,
                "\(host)/api/district/workflows",
                .json(#"{"active":false,"workflowId":"wf_1","workspaceId":"ws_1"}"#)
            ),
            EndpointExpectation(
                .campaignStatus,
                DistrictEndpoints.campaignStatus(workspaceId: "ws_1"),
                .get,
                "\(host)/api/district/workspace/campaign-status?workspaceId=ws_1"
            ),
            EndpointExpectation(
                .setCampaignEnabled,
                DistrictEndpoints.setCampaignEnabled(workspaceId: "ws_1", infiniteSdrEnabled: false),
                .patch,
                "\(host)/api/district/workspace/campaign-status",
                .json(#"{"infiniteSdrEnabled":false,"workspaceId":"ws_1"}"#)
            ),
        ]
    }

    static func devices() -> [EndpointExpectation] {
        [
            EndpointExpectation(
                .devices,
                DistrictEndpoints.devices(),
                .get,
                "\(host)/api/auth/native/devices"
            ),
            EndpointExpectation(
                .revokeDevice,
                DistrictEndpoints.revokeDevice(deviceId: "device-12345678"),
                .post,
                "\(host)/api/auth/native/devices/revoke",
                .json(#"{"deviceId":"device-12345678"}"#)
            ),
            EndpointExpectation(
                .revokeAllDevices,
                DistrictEndpoints.revokeAllDevices(),
                .post,
                "\(host)/api/auth/native/revoke-all",
                .json("{}")
            ),
            EndpointExpectation(
                .registerPushToken,
                DistrictEndpoints.registerPushToken(token: "fcm-token"),
                .post,
                "\(host)/api/district/devices/register",
                .json(#"{"platform":"ios","token":"fcm-token"}"#)
            ),
            EndpointExpectation(
                .unregisterPushToken,
                DistrictEndpoints.unregisterPushToken(),
                .post,
                "\(host)/api/district/devices/unregister",
                .json("{}")
            ),
        ]
    }
}
