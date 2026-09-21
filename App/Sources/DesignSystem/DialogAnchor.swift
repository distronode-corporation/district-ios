import SwiftUI

/// The presentation binding for a confirmation attached to the control that asks for
/// it, when one piece of state serves many such controls.
///
/// ⛔ WHY A CONFIRMATION SITS ON ITS TRIGGER AT ALL: ON A REGULAR-WIDTH LAYOUT A
/// `confirmationDialog` IS A POPOVER, AND IT POINTS AT WHATEVER IT IS ATTACHED TO. One
/// attached to a whole screen floats over the middle of that screen with an arrow at
/// nothing; one attached to the button points at the button. On a phone it is the same
/// action sheet from the bottom either way, so the move costs compact width nothing.
///
/// ⛔ ONE STATE, MANY ANCHORS, AND ONLY THE MATCHING ONE PRESENTS. A screen that asks
/// about one row at a time keeps a single "pending" value; every row's control carries
/// its own dialog, bound to `pending == this row`. Without the match every row's dialog
/// would present at once. With it exactly one does, and it is the one whose arrow
/// points at the row that asked.
///
/// ⚠️ `presented` IS A VALUE READ WHEN `body` RUNS, NOT A CLOSURE. That read is what
/// registers the observation, so a change to the pending row re-renders the screen and
/// rebuilds every binding; a closure read only at presentation time would not be
/// tracked the same way.
///
/// ⚠️ THE SETTER ONLY EVER CLOSES. Opening is always the control's own action, so a
/// `true` write has nothing to do; a `false` one is an outside tap or a dismissal by
/// the system, and routes to the same cancel the Cancel button calls.
extension Binding where Value == Bool {
    @MainActor
    static func dialog(_ presented: Bool, onDismiss: @escaping @MainActor () -> Void) -> Binding<Bool> {
        Binding(
            get: { presented },
            set: { value in
                // ⚠️ A BINDING'S SETTER IS NONISOLATED BY TYPE AND IS CALLED ON THE MAIN
                // THREAD BY THE PRESENTATION THAT OWNS IT; the cancel it routes to is the
                // screen's, which is main-actor state.
                if !value {
                    MainActor.assumeIsolated { onDismiss() }
                }
            }
        )
    }
}
