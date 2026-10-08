import SwiftUI
import Testing
import UIKit

/// A SwiftUI view drawn in a real window, read back the way VoiceOver reads it.
///
/// ⚠️ THE ACCESSIBILITY TREE, NOT A SNAPSHOT AND NOT A VIEW-INSPECTION LIBRARY: SwiftUI draws
/// text into layers, so no `UILabel` holds the words, but the hosting view's accessibility
/// elements carry every label, value and identifier the view declares, which is also what a
/// UI test addresses. Building them runs the view's body, so the window is laid out first.
@MainActor
final class HostedAccessibility {
    /// One element as VoiceOver meets it.
    struct Element: Equatable, CustomStringConvertible {
        let identifier: String
        let label: String
        let value: String

        var description: String {
            "[\(identifier)] \(label)" + (value.isEmpty ? "" : " = \(value)")
        }
    }

    private let window: UIWindow

    init(_ root: some View) throws {
        try Self.automation(true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root.frame(width: 390))
        window.isHidden = false
        window.layoutIfNeeded()
    }

    /// Take the window down; every test calls it, since a window kept by its scene outlives
    /// the test that made it.
    func close() {
        window.isHidden = true
        window.rootViewController = nil
        try? Self.automation(false)
    }

    /// ⛔ SWIFTUI ON iOS BUILDS NO ACCESSIBILITY ELEMENT UNTIL AN ASSISTIVE CLIENT IS RUNNING:
    /// in a unit test the hosting view answers with none at all (measured: every label empty,
    /// not even the pane's identifier). Switching on automation, as XCUITest does for the app
    /// it drives, is what makes it build them. `_AXSSetAutomationEnabled` is the simulator
    /// runtime's own switch in `libAccessibility`, called from this test bundle only; the app
    /// never links or calls it.
    private static func automation(_ enabled: Bool) throws {
        typealias Switch = @convention(c) (Int32) -> Void
        let library = try #require(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        let symbol = try #require(dlsym(library, "_AXSSetAutomationEnabled"))
        unsafeBitCast(symbol, to: Switch.self)(enabled ? 1 : 0)
    }

    /// Every element in the window now, in reading order.
    func elements() -> [Element] {
        window.layoutIfNeeded()
        var found: [Element] = []
        var seen = Set<ObjectIdentifier>()
        Self.collect(window, into: &found, seen: &seen)
        return found
    }

    /// The elements once `condition` holds. ⚠️ A STATE CHANGE IS DRAWN ON SWIFTUI'S NEXT
    /// UPDATE, NOT AT ONCE, so this reads again after each short yield, until the content the
    /// test is waiting for is on screen; it records an issue with the last reading if it never
    /// is, rather than hanging the run.
    func elements(
        when condition: ([Element]) -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [Element] {
        var last = elements()
        var reads = 1
        while !condition(last), reads < 250 {
            try? await Task.sleep(for: .milliseconds(20))
            last = elements()
            reads += 1
        }
        if !condition(last) {
            Issue.record("the condition never held; on screen: \(last)", sourceLocation: sourceLocation)
        }
        return last
    }

    private static func collect(_ object: NSObject, into found: inout [Element], seen: inout Set<ObjectIdentifier>) {
        guard seen.insert(ObjectIdentifier(object)).inserted else { return }
        // ⚠️ BY SELECTOR: SwiftUI's elements answer `accessibilityIdentifier` without declaring
        // `UIAccessibilityIdentification`, so a cast to it finds none of them.
        let getter = NSSelectorFromString("accessibilityIdentifier")
        let identifier = object.responds(to: getter)
            ? object.perform(getter)?.takeUnretainedValue() as? String ?? ""
            : ""
        let label = object.accessibilityLabel ?? ""
        if object.isAccessibilityElement || !identifier.isEmpty {
            found.append(Element(identifier: identifier, label: label, value: object.accessibilityValue ?? ""))
        }
        for child in children(of: object) {
            collect(child, into: &found, seen: &seen)
        }
    }

    private static func children(of object: NSObject) -> [NSObject] {
        var children: [NSObject] = []
        if let elements = object.accessibilityElements as? [NSObject] {
            children = elements
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound {
                children = (0 ..< count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            }
        }
        if let view = object as? UIView {
            children += view.subviews
        }
        return children
    }
}

extension [HostedAccessibility.Element] {
    var labels: [String] {
        map(\.label)
    }

    /// The element carrying `identifier`, if any.
    func identified(_ identifier: String) -> HostedAccessibility.Element? {
        first { $0.identifier == identifier }
    }

    /// The labels of every element carrying `identifier`: an identifier set on a view that is
    /// not itself one element is carried by each element inside it.
    func labels(identified identifier: String) -> [String] {
        filter { $0.identifier == identifier }.map(\.label)
    }
}
