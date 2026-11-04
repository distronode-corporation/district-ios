import SwiftUI
import UIKit

/// The dialler's number field: a `UITextField` that formats the number as it is typed.
///
/// ⛔ UIKit RATHER THAN A SwiftUI `TextField`, BECAUSE THE SwiftUI ONE LOST DIGITS. Measured in
/// the simulator: with the formatted number written back through SwiftUI state, typing
/// `4165550199` at speed left `(416) 5` in the field. SwiftUI pushes the new text into the
/// underlying `UITextField` after the keystroke has been handled, and a keystroke that
/// arrives in between is overwritten. A dropped middle digit can leave a valid number that is
/// not the one typed. Here the edit is applied and formatted inside
/// `textField(_:shouldChangeCharactersIn:replacementString:)`, synchronously, so there is no
/// window for a keystroke to fall into. Typing, paste and autofill all arrive there.
///
/// ⚠️ THE CARET GOES TO THE END AFTER EACH EDIT. Formatting moves characters around, and a
/// caret kept at its old offset would land inside a group; the end is where the next digit
/// belongs in the overwhelming case.
///
/// ⚠️ A DONE KEY ABOVE THE PAD, because `.phonePad` has no Return. Done ends the edit; that
/// and any other loss of focus (or Return on a hardware keyboard) is ``onCommit``, the moment a
/// wrong-length number is said (see ``DialerModel/entryProblem(_:lengthChecked:)``), never
/// while digits are still arriving. ⚠️ Neither key dials: Call is its own button, and a stray
/// Return must not spend money.
struct DialerNumberField: UIViewRepresentable {
    let placeholder: String
    let text: String
    let isEnabled: Bool
    let ink: Color
    let placeholderInk: Color
    /// Apply one edit: the field's whole proposed text in, the text it should show out.
    let onEdit: (String) -> String
    /// The operator stopped: the field lost focus, or Return or Done was pressed.
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, onCommit: onCommit)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        // ⚠️ `.phonePad`, so `+`, `*` and `#` are reachable for an international number.
        field.keyboardType = .phonePad
        field.textContentType = .telephoneNumber
        field.autocorrectionType = .no
        // ⚠️ THE SIZE OF ``DistrictType/bodySmall`` (14 pt, `callout`), scaled with Dynamic Type.
        field.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 14))
        field.adjustsFontForContentSizeCategory = true
        field.accessibilityIdentifier = A11yID.Dialer.entry
        field.inputAccessoryView = Self.doneBar(for: field)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onEdit = onEdit
        context.coordinator.onCommit = onCommit
        // ⚠️ RE-TITLED HERE, NOT ONLY AT CREATION, so a language switch reaches the key.
        (field.inputAccessoryView as? UIToolbar)?.items?.last?.title = DialerCopy.done
        // ⚠️ ONLY WHEN IT DIFFERS: a call-back row, a Handoff or a country pick changes the
        // entry from outside. While typing, the delegate has already written this value.
        if field.text != text {
            field.text = text
        }
        field.isEnabled = isEnabled
        field.textColor = UIColor(ink)
        field.accessibilityLabel = placeholder
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(placeholderInk)]
        )
    }

    /// The bar above the pad: Done at the trailing edge, as on every iOS number pad.
    private static func doneBar(for field: UITextField) -> UIToolbar {
        let done = UIBarButtonItem(
            title: DialerCopy.done,
            primaryAction: UIAction { [weak field] _ in field?.resignFirstResponder() }
        )
        done.style = .done
        done.accessibilityIdentifier = A11yID.Dialer.entryDone
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        bar.sizeToFit()
        return bar
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onEdit: (String) -> String
        var onCommit: () -> Void

        init(onEdit: @escaping (String) -> String, onCommit: @escaping () -> Void) {
            self.onEdit = onEdit
            self.onCommit = onCommit
        }

        func textFieldDidEndEditing(_: UITextField) {
            onCommit()
        }

        /// ⚠️ RETURN (A HARDWARE KEYBOARD) SAYS THE LENGTH WITHOUT ENDING THE EDIT: the caret
        /// stays in the field for the correction.
        func textFieldShouldReturn(_: UITextField) -> Bool {
            onCommit()
            return false
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = textField.text ?? ""
            guard let span = Range(range, in: current) else { return false }
            textField.text = onEdit(current.replacingCharacters(in: span, with: string))
            let end = textField.endOfDocument
            textField.selectedTextRange = textField.textRange(from: end, to: end)
            return false
        }
    }
}
