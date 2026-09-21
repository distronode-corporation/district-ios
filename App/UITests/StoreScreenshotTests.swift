import XCTest

/// Captures the App Store and Play store screenshots, one per section.
///
/// ⛔ IT ASSERTS ALMOST NOTHING, AND THAT IS THE POINT. ``ReadOnlyTourTests``
/// exists to prove the screens WORK, so it taps into a contact, a call and a
/// room and fails when any of them is missing. That makes it useless as a
/// capture tool against a review workspace that has no call history: most of its
/// cases fail and produce no usable frame. This class
/// only needs the section to exist and the app to settle, so an empty section yields
/// an honest screenshot of an empty section rather than a failure and no image.
///
/// ⚠️ THE SIZE COMES FROM THE SIMULATOR, NOT FROM ANYTHING HERE, AND IT CHOOSES THE SET. Run
/// on an iPhone 17 Pro Max, a frame of the screen is 1320x2868, exactly the 6.9-inch set App
/// Store Connect asks for. Run on an iPad Pro 13-inch it is 2064x2752 in portrait; the case
/// turns it to landscape, where it is the 2752x2064 13-inch iPad set, and adds a frame of the
/// sidebar beside a list. The choice is made from the pixels on screen, never from the device
/// type. On any other device the frames are the wrong size and App Store Connect rejects the
/// upload rather than scaling.
///
/// ⚠️ THE FRAMES ARE ATTACHMENTS, AND ALSO FILES WHEN A FOLDER IS GIVEN. With
/// `TEST_RUNNER_DISTRICT_STORE_SCREENSHOTS_DIR` exported, each set is written into its own
/// folder under it (`iphone-6.9` and `ipad-13`), side by side, so the two uploads cannot mix.
///
/// ⚠️ NEEDS A MINTED SESSION, so it skips in CI, where there is none. Pass it by
/// EXPORTING `TEST_RUNNER_DISTRICT_UITEST_SESSION` into xcodebuild's environment.
/// ⛔ Passing it as a build setting on the command line does NOT work: the tests
/// silently SKIP with "no minted review session in this run", which reads like a
/// missing session rather than a plumbing mistake.
final class StoreScreenshotTests: UITestApp {
    /// One App Store Connect screenshot set.
    private struct StoreSet {
        /// The folder the set is written to, under the one the environment names.
        let folder: String
        /// The attachment name's prefix, so the two sets never share a frame name.
        let prefix: String
        let orientation: UIDeviceOrientation
        /// The pixel size every frame must have, when the set is chosen by it.
        let pixels: (width: Int, height: Int)?
    }

    private static let iPhoneSet = StoreSet(folder: "iphone-6.9", prefix: "STORE-", orientation: .portrait, pixels: nil)

    /// ⚠️ LANDSCAPE, LONG SIDE FIRST, as the simulator produces it once turned.
    private static let iPadSet = StoreSet(
        folder: "ipad-13",
        prefix: "STORE-IPAD-",
        orientation: .landscapeLeft,
        pixels: (width: 2752, height: 2064)
    )

    private static let folderVariable = "DISTRICT_STORE_SCREENSHOTS_DIR"

    /// Section, then the frame name. Ordered as the store listing should read:
    /// Overview first because it carries the workspace and its headline numbers.
    private static let screens: [(section: ShellSection, name: String)] = [
        (.overview, "1-overview"),
        (.contacts, "2-contacts"),
        (.calls, "3-calls"),
        (.inbox, "4-inbox"),
        (.account, "5-account"),
    ]

    override func tearDown() {
        ensureOrientation(Self.runOrientation)
        super.tearDown()
    }

    func test_captureStoreScreenshots() throws {
        try requireSession()
        XCTAssertTrue(shellIsUp(timeout: 30), "an injected session must reach the shell")
        let set = isThirteenInchIPad() ? Self.iPadSet : Self.iPhoneSet
        ensureOrientation(set.orientation)
        for screen in Self.screens {
            navigate(to: screen.section, timeout: 30)
            capture(set.prefix + screen.name, in: set)
        }
        guard set.pixels != nil else { return }
        // ⚠️ THE ONE FRAME ONLY A WIDE SCREEN HAS: every section beside the list it opened.
        navigate(to: .inbox, timeout: 30)
        XCTAssertTrue(ShellNavigator.revealSidebar(app), "the sidebar could not be shown for its frame")
        capture(set.prefix + "6-sidebar-inbox", in: set)
    }

    /// ⚠️ THE SCREEN'S PIXELS, IN EITHER ORIENTATION, DECIDE THE SET.
    private func isThirteenInchIPad() -> Bool {
        guard let wanted = Self.iPadSet.pixels else { return false }
        let pixels = Self.pixelSize(of: screenCapture())
        let sides = [pixels.width, pixels.height].sorted()
        return sides == [wanted.height, wanted.width].sorted()
    }

    /// Let the section settle, then attach the frame and write it into the set's folder.
    ///
    /// ⚠️ A FIXED WAIT, DELIBERATELY. There is no single element whose arrival means "this
    /// section has finished loading" across all of them, and a screenshot taken
    /// mid-transition is worse than a slow test.
    ///
    /// ⛔ ``UITestApp/screenCapture()``, NEVER `app.screenshot()`, which crops every landscape
    /// frame and pads it with black; see the ⛔ there. The pixel check below reads the size
    /// with the orientation tag applied, which is the upright frame a person sees.
    private func capture(_ name: String, in set: StoreSet) {
        Thread.sleep(forTimeInterval: 3.0)
        let frame = screenCapture()
        let shot = XCTAttachment(screenshot: frame)
        shot.name = name
        // ⚠️ `keepAlways`, because the default discards a passing run's attachments.
        shot.lifetime = .keepAlways
        add(shot)
        if let wanted = set.pixels {
            let pixels = Self.pixelSize(of: frame)
            XCTAssertTrue(
                pixels == wanted,
                "\(name) is \(pixels.width)x\(pixels.height), not \(wanted.width)x\(wanted.height)"
            )
        }
        write(frame, named: name, in: set)
    }

    /// ⚠️ ONLY WHEN THE ENVIRONMENT NAMES A FOLDER; without one the attachment is the frame.
    /// ⚠️ A LANDSCAPE FILE IS UPRIGHT ONLY BY ITS ORIENTATION TAG: the buffer is 2064x2752,
    /// tagged EXIF 8. See ``UITestApp/screenCapture()``.
    private func write(_ frame: XCUIScreenshot, named name: String, in set: StoreSet) {
        guard let root = ProcessInfo.processInfo.environment[Self.folderVariable], !root.isEmpty else { return }
        let folder = URL(fileURLWithPath: root).appendingPathComponent(set.folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try frame.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("could not write \(name) into \(folder.path): \(error)")
        }
    }

    private static func pixelSize(of screenshot: XCUIScreenshot) -> (width: Int, height: Int) {
        let image = screenshot.image
        return (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
    }
}
