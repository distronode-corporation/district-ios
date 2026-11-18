@testable import DistrictAI
import Foundation
import SwiftUI
import Testing

/// A carrier credential is typed into a `SecureField`, not an ordinary text box.
///
/// ⛔ MASKED ON SCREEN, AND ON THE SYSTEM KEYBOARD. An ordinary field shows the token to
/// anyone looking at the screen and hands every keystroke to whichever keyboard is active;
/// a secure field does neither. The catalog's ``MessagingCredentialField/isSecret`` is what
/// ``MessagingAccountSheet`` passes as ``SettingsField/secure``, so the classification is
/// pinned here alongside the field.
///
/// ⚠️ READ BACK THROUGH ACCESSIBILITY (``HostedAccessibility``): an ordinary field's value
/// is the text typed into it, a secure field's is not.
@MainActor
@Suite(.serialized)
struct SettingsSecretFieldTests {
    private let typed = "tok-visible-0123456789"

    @Test
    func `every carrier secret is classified as one, and only the Sinch project id is not`() {
        let fields = MessagingCatalog.providers.flatMap { MessagingCatalog.credentialFields(for: $0) }
        let secrets = Set(fields.filter(\.isSecret).map(\.key))
        for key in ["accountSid", "authToken", "keyId", "keySecret", "applicationKey", "applicationSecret", "apiKey"] {
            #expect(secrets.contains(key), "\(key) is not classified as a secret")
        }
        #expect(fields.filter { !$0.isSecret }.map(\.key) == ["projectId"])
    }

    @Test
    func `a secure settings field does not show what was typed`() async throws {
        let screen = try HostedAccessibility(SettingsField(label: "Auth token", text: .constant(typed), secure: true))
        defer { screen.close() }

        let shown = await screen.elements { $0.labels.contains("Auth token") }

        #expect(!shown.contains { $0.value.contains(typed) || $0.label.contains(typed) }, "on screen: \(shown)")
    }

    /// ⚠️ THE CONTROL: without it, a reading that never reached the field would pass above.
    @Test
    func `an ordinary settings field still shows what was typed`() async throws {
        let screen = try HostedAccessibility(SettingsField(label: "Project ID", text: .constant(typed)))
        defer { screen.close() }

        let shown = await screen.elements { elements in
            elements.contains { $0.value.contains(typed) }
        }

        #expect(shown.contains { $0.value.contains(typed) }, "on screen: \(shown)")
    }
}
