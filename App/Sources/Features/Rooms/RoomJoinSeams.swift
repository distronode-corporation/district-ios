import AVFoundation
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation

/// The two things ``ActiveRoomModel/join()`` waits on that a test has to hold: the token
/// read and the OS permission prompts.
///
/// ⚠️ ``live(_:)`` EVERYWHERE BUT A TEST. A test parks the token read so a leave or a yield
/// can land inside the join, which is the window the model's join generation closes.
struct RoomJoinSeams {
    var fetchToken: @MainActor (RoomName) async -> Result<RoomTokenResponse, ApiError>
    var askPermissions: @MainActor () async -> RoomPermissions

    static func live(_ rooms: RoomsRepository) -> RoomJoinSeams {
        RoomJoinSeams(
            fetchToken: { await rooms.token(roomName: $0) },
            askPermissions: { await askTheSystem() }
        )
    }

    /// ⚠️ ASKED FOR SEPARATELY AND IN ORDER, because the two answers are not one
    /// outcome. `AVCaptureDevice.requestAccess` returns the current grant immediately
    /// when it has already been answered, so this is one path rather than two.
    private static func askTheSystem() async -> RoomPermissions {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        return RoomPermissions(
            requested: true,
            microphoneGranted: microphone,
            cameraGranted: camera
        )
    }
}
