import SwiftUI

extension KeyboardShortcut {
    /// ⌘↩, for the one primary action of a compose or save sheet. Its Cancel takes
    /// `.cancelAction` (Esc).
    ///
    /// ⛔ ⌘↩ AND NOT A BARE ↩, which SwiftUI's `.defaultAction` is. Return belongs to the
    /// text field that has focus on every one of these sheets, and a message body or a note
    /// that sent itself on a new line would be the worst kind of shortcut.
    ///
    /// ⛔ NEVER ON AN ACTION THAT DELETES, PLACES A CALL OR SPENDS MONEY. A shortcut removes
    /// the moment of looking at the button, which is the moment those actions keep on
    /// purpose; their sheets give Cancel its Esc and leave the confirm to a tap.
    static let districtSubmit = KeyboardShortcut(.return, modifiers: .command)
}
