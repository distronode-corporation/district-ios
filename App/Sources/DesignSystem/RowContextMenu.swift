import DistrictModel
import SwiftUI
import UIKit

/// One entry in a list row's context menu (a secondary click, or a long press).
///
/// ⛔ COPY ONLY, AND THAT IS A DECISION ABOUT WHAT ALREADY EXISTS, NOT A PLACEHOLDER. A row
/// menu may offer only what the app can already do from that row's data without a new
/// request: the dialler has no way to be opened with a number in it, and compose has no
/// path in from a row, so "Call back" and "Message" would each be a new feature wearing a
/// menu item. Copying a value the row already shows is neither.
///
/// ⚠️ NOT GATED BY ROLE. Every role that can see a row can read what it copies, and copying
/// spends no request, so there is nothing for ``RouteGate`` to refuse.
struct RowContextAction: Hashable, Identifiable {
    let title: String
    let value: String

    var id: String {
        title
    }
}

/// The actions each kind of row offers.
enum RowContextActions {
    /// A call-log row: the caller's number, on an inbound call that carried one.
    ///
    /// ⛔ INBOUND ONLY, FOR THE REASON THE DIALLER'S CALL-BACK LIST GIVES. On an outbound row
    /// ``CallSummary/from`` is the workspace's OWN line, so "Copy number" there would hand
    /// the operator their own number as if it were the customer's. A row with no direction
    /// is excluded for the same reason. ⚠️ And the number goes through ``CallerIdentity``,
    /// because a withheld caller's `from` is an English sentence, not a number.
    static func call(direction: String?, from: String?) -> [RowContextAction] {
        guard direction == "inbound", let number = CallerIdentity.resolved(from) else { return [] }
        return [RowContextAction(title: "Copy Number", value: number)]
    }

    /// A contact row: its phone number and its email, whichever it has.
    static func contact(phone: String?, email: String?) -> [RowContextAction] {
        [
            usable(phone).map { RowContextAction(title: "Copy Number", value: $0) },
            usable(email).map { RowContextAction(title: "Copy Email", value: $0) },
        ].compactMap(\.self)
    }

    /// An Inbox row: the address its latest message was exchanged with.
    ///
    /// ⚠️ THE COUNTERPART IS STORED IN DISPLAY FORM, which for an email can be
    /// `Name <address>`; the address inside the brackets is what is copied, because a name
    /// pasted into a To field is not an address.
    static func thread(counterpart: String) -> [RowContextAction] {
        var address = counterpart
        if let open = address.lastIndex(of: "<"), let close = address.lastIndex(of: ">"), open < close {
            address = String(address[address.index(after: open) ..< close])
        }
        return usable(address).map { [RowContextAction(title: "Copy Address", value: $0)] } ?? []
    }

    private static func usable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension View {
    /// A context menu of ``RowContextAction``s, or none at all when there are none.
    ///
    /// ⚠️ NO MENU RATHER THAN AN EMPTY ONE. An empty `contextMenu` still lifts the row on a
    /// long press and then shows nothing, which reads as a broken gesture.
    @ViewBuilder
    func rowContextMenu(_ actions: [RowContextAction]) -> some View {
        if actions.isEmpty {
            self
        } else {
            contextMenu {
                ForEach(actions) { action in
                    Button(action.title, systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = action.value
                    }
                }
            }
        }
    }
}
