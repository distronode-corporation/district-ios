import Foundation
import UIKit
import XCTest

/// A recorded fixture with one field changed, for a state the service records no file for
/// (an empty list, a viewer's role, a row in another status).
///
/// ⚠️ THE REST OF THE BODY STAYS THE SERVICE'S OWN, so the screen still decodes the shape the
/// service really sends; only the field the test names is moved.
extension FixtureTransport.Reply {
    /// The fixture `name`, decoded as a JSON object, passed through `edit`, and re-encoded.
    static func recorded(_ name: String, with edit: (inout [String: Any]) -> Void) -> Self {
        let data = FixtureTransport.fixtureData(name)
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            XCTFail("\(name).json is not a JSON object")
            return Self(status: 200, body: data)
        }
        edit(&object)
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            XCTFail("\(name).json did not re-encode after the edit")
            return Self(status: 200, body: data)
        }
        return Self(status: 200, body: body)
    }

    /// The service's refusal envelope with `status`, as `ApiErrorNormalizer` reads it.
    static func refused(_ status: Int, _ message: String = "Internal error") -> Self {
        .json(#"{"success":false,"error":"\#(message)"}"#, status: status)
    }
}

extension [String: Any] {
    /// The object at `key` with `edit` applied, written back; a missing or non-object value fails.
    mutating func editObject(_ key: String, _ edit: (inout [String: Any]) -> Void) {
        guard var inner = self[key] as? [String: Any] else {
            XCTFail("no object at \(key)")
            return
        }
        edit(&inner)
        self[key] = inner
    }

    /// Every object in the array at `key` with `edit` applied, written back.
    mutating func editEach(_ key: String, _ edit: (inout [String: Any]) -> Void) {
        guard let rows = self[key] as? [[String: Any]] else {
            XCTFail("no array of objects at \(key)")
            return
        }
        self[key] = rows.map { row in
            var row = row
            edit(&row)
            return row
        }
    }
}

/// Small real media bodies for the attachment states.
enum ScopeMedia {
    /// A 4x4 solid PNG that `UIImage(data:)` decodes.
    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    /// The first bytes of a PDF, which is not an image and so is offered as a file.
    static let pdf = Data("%PDF-1.4\n%fixture\n".utf8)
}
