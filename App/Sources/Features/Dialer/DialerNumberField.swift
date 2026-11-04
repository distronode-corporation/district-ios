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
struct DialerNumberField: UIViewRepresentable {
    let placeholder: String
    let text: String
    let isEnabled: Bool
    let ink: Color
    let placeholderInk: Color
    /// Apply one edit: the field's whole proposed text in, the text it should show out.
    let onEdit: (String) -> String

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit)
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
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onEdit = onEdit
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

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onEdit: (String) -> String

        init(onEdit: @escaping (String) -> String) {
            self.onEdit = onEdit
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
