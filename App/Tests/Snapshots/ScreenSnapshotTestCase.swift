@testable import DistrictAI
import DistrictAuthCore
import DistrictL10n
import SnapshotTesting
import SwiftUI
import XCTest

/// The base of the screen snapshot tests: a screen built from a real ``AppContainer`` over a
/// ``FixtureTransport``, drawn in a window once its reads have settled, and compared with the
/// committed reference image for each language and device size.
///
/// ⛔ A REFERENCE IS RECORDED ON CI, NEVER ON A DEVELOPER'S MAC. The image depends on the
/// simulator runtime and the host's rendering, and CI's macos-26 runner is the machine that
/// judges it. A missing reference is recorded and FAILS the run (swift-snapshot-testing's
/// `.missing` mode); the `app` job uploads the new images as the `snapshots-*` artifact, and
/// they are committed from there. A reference that changes is reviewed as an image diff.
///
/// ⚠️ ENGLISH AND FRENCH ARE SET ON ``L10nRuntime/locale`` ITSELF, not through the task-local
/// override: SwiftUI evaluates a body outside the test's task, where a task-local is not set.
/// XCTest runs these one at a time, and ``tearDown()`` puts English back for the tests after.
///
/// ⚠️ THE TIME ZONE IS FIXED (Toronto, the service's own) so an absolute time draws the same on
/// every runner, and animations are off so nothing is drawn halfway.
@MainActor
class ScreenSnapshotTestCase: XCTestCase {
    /// The sizes every screen is drawn at: a phone and an iPad, portrait.
    enum Device: String, CaseIterable {
        case iPhone
        case iPad

        var config: ViewImageConfig {
            switch self {
            case .iPhone: .iPhone13
            case .iPad: .iPadPro11
            }
        }
    }

    /// A signed-in session for the container, so the bearer closure has a token to attach.
    static let session = UITestSession(
        tokens: NativeTokens(
            accessToken: "snapshot-access",
            accessTokenExpiresAt: 4_102_444_800_000,
            refreshToken: "snapshot-refresh",
            refreshTokenExpiresAt: 4_102_444_800_000
        ),
        deviceId: "device_snapshot",
        baseURL: nil
    )

    /// ⚠️ LIGHT, AT 1x. The light appearance whatever the simulator is set to, so a reference
    /// never depends on the machine; and one point per pixel, which keeps every word legible in
    /// review while each committed image stays a tenth of its 3x size.
    static let traits = UITraitCollection(traitsFrom: [
        UITraitCollection(userInterfaceStyle: .light),
        UITraitCollection(displayScale: 1),
    ])

    override func setUp() async throws {
        try await super.setUp()
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() async throws {
        L10nRuntime.locale = .en
        UITestSession.inProcess = nil
        UIView.setAnimationsEnabled(true)
        try await super.tearDown()
    }

    /// A container signed in as ``session`` that sends every request to `transport`.
    func container(_ transport: FixtureTransport) async throws -> AppContainer {
        UITestSession.inProcess = Self.session
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://snapshot.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted),
            transport: transport
        )
        // ⚠️ THE SESSION IS ADOPTED IN A TASK THE CONTAINER STARTS, so wait for it rather than
        // let the screen's first read race it and draw "signed out".
        for _ in 0 ..< 200 {
            if case .available = await container.coordinator.accessToken() {
                return container
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the snapshot session was never adopted")
        return container
    }

    /// Draws the screen `make` builds in every language and device and compares each drawing
    /// with its reference, `<test>.<device>-<language>.png`.
    ///
    /// - Parameters:
    ///   - replies: the transport's overrides; a fresh transport is made for every drawing, so
    ///     one drawing's writes or reads cannot leak into the next.
    ///   - expectAllAnswered: fails the test if the screen asked for a path with no reply,
    ///     which would have drawn a failure state nobody chose.
    func assertScreen(
        _ replies: [String: FixtureTransport.Reply] = [:],
        devices: [Device] = Device.allCases,
        locales: [L10nLocale] = [.en, .frCA],
        expectAllAnswered: Bool = true,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line,
        _ make: @escaping (AppContainer) -> some View
    ) async throws {
        for locale in locales {
            for device in devices {
                L10nRuntime.locale = locale
                let transport = FixtureTransport(replies)
                let container = try await container(transport)
                let controller = UIHostingController(
                    rootView: NavigationStack { make(container) }
                        .transaction { $0.animation = nil }
                )
                let window = try present(controller, size: device.config.size ?? .zero)
                await settle(transport)
                if expectAllAnswered {
                    XCTAssertEqual(transport.unanswered, [], "unstubbed requests", file: file, line: line)
                }
                assertSnapshot(
                    of: controller,
                    as: .image(
                        on: device.config,
                        precision: 0.995,
                        perceptualPrecision: 0.98,
                        traits: Self.traits
                    ),
                    named: "\(device.rawValue)-\(locale == .frCA ? "fr-CA" : "en")",
                    file: file,
                    testName: testName,
                    line: line
                )
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }

    private func present(_ controller: UIViewController, size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    /// Waits until no request is in flight and none has started for a run of short yields,
    /// so the drawing is of the screen's settled state, not of its spinner.
    private func settle(_ transport: FixtureTransport) async {
        var quiet = 0
        var lastCount = -1
        for _ in 0 ..< 400 {
            try? await Task.sleep(for: .milliseconds(20))
            let count = transport.requestCount
            if transport.inFlight == 0, count == lastCount {
                quiet += 1
                if quiet >= 10 {
                    return
                }
            } else {
                quiet = 0
            }
            lastCount = count
        }
    }
}
