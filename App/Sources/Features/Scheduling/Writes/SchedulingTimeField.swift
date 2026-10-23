import DistrictData
import SwiftUI

/// The text of a working-hours time field, both ways.
///
/// ⛔ THE DRAFT HOLDS THE WIRE VALUE AND THE FIELD SHOWS THE LANGUAGE'S. The scheduler
/// refuses anything but zero-padded `HH:MM`, so the drafts keep it; until this the field
/// showed it too, « 09:00 » on a French screen whose every other time reads « 9 h ». Both
/// directions are DistrictCore's ``SchedulingWallClock``.
enum SchedulingTimeFieldText {
    /// What the field shows for a stored value: « 9 h 30 » in French, `09:30` in English.
    static func text(forStored stored: String) -> String {
        SchedulingWallClock.fieldText(stored)
    }

    /// What a typed value is stored as: its `HH:MM` when it is a time, otherwise the text as
    /// typed, so the editor's validator shows its format error against what is on screen.
    static func stored(fromTyped typed: String) -> String {
        SchedulingWallClock.wireValue(typed) ?? typed
    }
}

/// One time field of the working-hours and date-override editors.
///
/// ⚠️ THE TEXT IS REWRITTEN ONLY WHILE THE FIELD IS NOT BEING EDITED. Reformatting each
/// keystroke would turn a half-typed « 9 h 3 » into something else under the cursor; the
/// draft is updated on every keystroke (so Save always sends what is typed) and the field
/// takes its language's form when focus leaves it, or when the draft changes from outside
/// (copy to weekdays, add a range).
struct SchedulingTimeField: View {
    /// The wire value the field holds.
    let stored: String
    /// The wire value shown as the placeholder.
    let placeholder: String
    let onChange: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(SchedulingTimeFieldText.text(forStored: placeholder), text: $text)
            .focused($focused)
            .onAppear { text = SchedulingTimeFieldText.text(forStored: stored) }
            .onChange(of: text) { _, typed in
                if focused {
                    onChange(SchedulingTimeFieldText.stored(fromTyped: typed))
                }
            }
            .onChange(of: stored) { _, value in
                if !focused {
                    text = SchedulingTimeFieldText.text(forStored: value)
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    text = SchedulingTimeFieldText.text(forStored: stored)
                }
            }
            .districtField()
    }
}
