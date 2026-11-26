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
/// ⚠️ EVERY DRAWING IS LIGHT, AT THE `.large` TEXT SIZE, AT ONE PIXEL PER POINT, WITH NO SAFE
/// AREA, whatever the simulator or another test in the bundle has set (one did change the text
/// size, and one screen was drawn larger on CI), so a reference depends on neither the machine
/// nor the order the tests run in. 1x keeps every word legible and each image small in git.
///
/// ⚠️ THE TIME ZONE IS FIXED (Toronto, the service's own) so an absolute time draws the same on
/// every runner, and animations are off so nothing is drawn halfway.
@MainActor
class ScreenSnapshotTestCase: XCTestCase {
    /// The sizes every screen is drawn at: an iPhone 13 in portrait and an iPad Pro 11 in landscape.
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
        sequences: [String: [FixtureTransport.Reply]] = [:],
        devices: [Device] = Device.allCases,
        locales: [L10nLocale] = [.en, .frCA],
        expectAllAnswered: Bool = true,
        file: StaticString = #filePath,
        testName: String = #function,
        line: UInt = #line,
        _ make: @escaping (AppContainer) -> some View
    ) async throws {
        // ⛔ JUDGED ON THE iPHONE SIMULATOR ONLY. The iPad leg's simulator lays out at 2x, and
        // pinning the layout's scale in the window changed how text rasterised depending on
        // what ran before (CI runs 45839096836 and 45839155803), so the references, the iPad
        // layouts included, are drawn and compared on the iPhone leg, which runs everywhere.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "snapshots are compared on the iPhone simulator")
        for locale in locales {
            for device in devices {
                L10nRuntime.locale = locale
                let transport = FixtureTransport(replies, sequences: sequences)
                let container = try await container(transport)
                let controller = UIHostingController(
                    // ⚠️ INLINE TITLES: the space under a large title came out 5 points taller in
                    // a long run than in a short one (runs 45891588712 and 45891796773), so a
                    // drawing depended on what ran before it. An inline title has no such gap.
                    rootView: NavigationStack { make(container).toolbarTitleDisplayMode(.inline) }
                        .environment(\.dynamicTypeSize, .large)
                        .transaction { $0.animation = nil }
                )
                // ⛔ NO SAFE AREA FROM THE DEVICE: the drawing is the same on any simulator the
                // job picks, the iPad leg's included.
                controller.safeAreaRegions = []
                let before = transport.requestCount
                let window = try present(controller, device: device)
                await settle(transport, after: before)
                if expectAllAnswered {
                    XCTAssertEqual(transport.unanswered, [], "unstubbed requests", file: file, line: line)
                }
                let drawing = await Self.steadyRender(window)
                assertSnapshot(
                    of: drawing,
                    as: .image(precision: 0.995, perceptualPrecision: 0.98),
                    named: "\(device.rawValue)-\(locale == .frCA ? "fr-CA" : "en")",
                    file: file,
                    testName: testName,
                    line: line
                )
                // ⛔ DETACHED FROM THE SCENE, NOT ONLY HIDDEN. A hidden window stays in the scene, and
                // after a few hundred drawings on CI the later ones lost their glass, their large
                // titles and sometimes everything (run 45884906886 against run 45885167945), so a
                // drawing depended on how many came before it in the process.
                window.isHidden = true
                window.rootViewController = nil
                window.windowScene = nil
            }
        }
    }

    /// ⛔ THE SETTLED WINDOW ITSELF IS DRAWN, NEVER RE-HOSTED. swift-snapshot-testing's
    /// view-controller strategy moves the controller into a window of its own, which makes the
    /// screen disappear and appear again: its `.task` restarts, and a screen that shows its
    /// skeleton while it reads was sometimes drawn mid-read (measured: 3 to 4 of 112 drawings
    /// per local run). Drawing this window at one point per pixel has no such race.
    ///
    /// ⛔ `drawHierarchy`, NOT `layer.render`: the layer renderer cannot draw iOS 26's glass and
    /// material layers, so screens built on them (toolbars, the tab bar, the setup wizard) came
    /// out blank.
    private static func render(_ window: UIWindow) -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The window drawn once three drawings 100 ms apart are the same, at most three seconds on.
    ///
    /// ⛔ A QUIET TRANSPORT IS NOT A DRAWN SCREEN. Locally, a list whose read had been answered
    /// was still drawn as its skeleton about once in thirty runs, the rows landing a moment
    /// later; waiting for the picture itself to stop changing closes that gap.
    private static func steadyRender(_ window: UIWindow) async -> UIImage {
        var image = render(window)
        var same = 0
        for _ in 0 ..< 30 {
            try? await Task.sleep(for: .milliseconds(100))
            let next = render(window)
            same = next.pngData() == image.pngData() ? same + 1 : 0
            image = next
            if same >= 2 {
                break
            }
        }
        return image
    }

    /// A window of the device's size, with its traits set on the window rather than taken from
    /// the simulator: light, the `.large` text size, and the device's size classes.
    private func present(_ controller: UIViewController, device: Device) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: device.config.size ?? .zero)
        window.overrideUserInterfaceStyle = .light
        window.traitOverrides.preferredContentSizeCategory = .large
        window.traitOverrides.horizontalSizeClass = device == .iPad ? .regular : .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    /// Waits for the screen's first request, then until no request is in flight and none has
    /// started for a run of short yields, so the drawing is of the settled state.
    ///
    /// ⛔ QUIET BEFORE THE FIRST REQUEST IS NOT SETTLED. A screen's `.task` can start well after
    /// the window appears on a loaded runner, and a wait that counted quiet from the start drew
    /// skeletons as references. A screen that reads nothing is drawn after two seconds.
    private func settle(_ transport: FixtureTransport, after before: Int) async {
        for _ in 0 ..< 100 where transport.requestCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
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
