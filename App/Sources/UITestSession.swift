#if DEBUG

    import DistrictAuthCore
    import Foundation

    /// A session handed to the app by a UI-test runner, instead of a sign-in.
    ///
    /// ⛔ THE WHOLE FILE IS INSIDE `#if DEBUG`, AND THAT IS THE SECURITY BOUNDARY
    /// RATHER THAN A TIDINESS ONE. Measured on this project rather than assumed from
    /// XcodeGen's documentation, because the spec sets no such flag itself:
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` appears exactly ONCE in the
    /// generated `project.pbxproj`, and `xcodebuild -showBuildSettings` resolves it
    /// in the **Debug** configuration and reports it **absent** in **Release**. The
    /// archive is a Release build, so these symbols do not exist in a shipped binary.
    /// `archive-imac.sh` re-proves that per archive with `strings … | grep -c
    /// 'DISTRICT_UITEST'` = 0 rather than trusting this comment.
    ///
    /// ⛔ IT GRANTS NOTHING THE TOKEN DOES NOT ALREADY GRANT. There is no bypass
    /// here: the runner supplies a real session minted server-side for an
    /// ordinary review account, and the app then behaves exactly as it
    /// would for that account signed in by hand. A seam that skipped authorisation
    /// would be a different and much worse thing than one that skips the keyboard.
    ///
    /// ⛔ ONE MINT, ONE `app.launch()` PER RUN. Refresh rotation is single-use: a
    /// replayed refresh token is treated as theft and REVOKES THE WHOLE FAMILY, so a
    /// second launch on the same injected session does not merely fail, it destroys
    /// the session the rest of the run depends on. The operator revokes after.
    ///
    /// ⚠️ IN MEMORY, NEVER THE KEYCHAIN. Nothing this seam introduces survives the
    /// process, so a test run cannot leave a credential on a handset — which matters
    /// most on a test device that is also somebody's personal phone.
    struct UITestSession {
        let tokens: NativeTokens
        let deviceId: String
        let baseURL: URL?

        /// The launch argument that arms the seam. ⚠️ Both halves are required: the
        /// argument alone does nothing, so an app launched with it by accident (or
        /// by a curious person) still signs in normally.
        static let launchArgument = "-UITestSession"
        static let sessionVariable = "DISTRICT_UITEST_SESSION"
        static let baseURLVariable = "DISTRICT_UITEST_BASE_URL"

        /// The injected session, or nil.
        ///
        /// ⚠️ THE ENVIRONMENT IS READ ONLY WHEN THE ARGUMENT IS PRESENT, and the
        /// argument is honoured only when the environment parses. Two independent
        /// conditions, because either one alone is a shape that can occur by
        /// accident: CI sets stray variables, and a stale scheme can carry an
        /// argument nobody meant to keep.
        /// Whether a UI-test runner launched this process at all, session or not.
        ///
        /// ⚠️ SEPARATE FROM ``current()`` ON PURPOSE. The unauthenticated UI lane
        /// passes the argument and NO session, and needs the app to render the real
        /// signed-out gate. Without this the unsigned simulator build cannot read
        /// the Keychain, the coordinator honestly answers `storeUnavailable`, and
        /// the lane only ever sees the "could not read your saved session" branch,
        /// which offers a re-check and no sign-in, so a test waiting for the sign-in
        /// buttons would time out on a button that branch never draws.
        /// Armed-without-session grants nothing: an EMPTY in-memory store, which is
        /// exactly a fresh install's state, in a DEBUG build only.
        static func isArmed(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(launchArgument)
        }

        static func current(
            arguments: [String] = ProcessInfo.processInfo.arguments,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> UITestSession? {
            guard arguments.contains(launchArgument) else { return nil }
            guard let raw = environment[sessionVariable], !raw.isEmpty else { return nil }
            guard let data = raw.data(using: .utf8) else { return nil }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
            return UITestSession(
                tokens: payload.response.tokens,
                deviceId: payload.deviceId,
                baseURL: environment[baseURLVariable].flatMap(URL.init(string:))
            )
        }

        /// ⚠️ THE FIVE `/api/auth/native/token` KEYS PLUS `deviceId`, decoded as the
        /// SAME `NativeTokenResponse` the real exchange decodes. A bespoke struct
        /// here would be a second opinion about the token contract, and it would
        /// drift the first time the server added a field.
        private struct Payload: Decodable {
            let response: NativeTokenResponse
            let deviceId: String

            init(from decoder: Decoder) throws {
                response = try NativeTokenResponse(from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                deviceId = try container.decode(String.self, forKey: .deviceId)
            }

            private enum CodingKeys: String, CodingKey { case deviceId }
        }
    }

#endif
