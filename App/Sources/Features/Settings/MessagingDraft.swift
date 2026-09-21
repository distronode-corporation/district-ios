import DistrictModel
import DistrictNetwork
import Foundation

/// One credential field on the account form.
///
/// ⛔ ``isSecret`` IS WHAT MAKES A BLANK FIELD SAFE. The route's `SECRET_FIELDS` map is
/// the server-side twin of this list: for a secret, a blank or absent incoming value
/// means "keep the stored ciphertext", which is the only reason an edit form can exist
/// against a read that returns no credential at all. For a PLAINTEXT field
/// (`projectId`) a blank is just a blank — it merges field-wise over the stored config
/// like any other key, so leaving it empty on an edit preserves it only because the
/// key is OMITTED entirely rather than sent as `""`.
struct MessagingCredentialField: Identifiable {
    let key: String
    let label: String
    let isSecret: Bool

    var id: String {
        key
    }
}

/// The carriers, their credential fields and the channels, mirrored from the route.
///
/// ⛔ A KEY SPELLED DIFFERENTLY HERE IS NOT A VALIDATION ERROR ANYWHERE.
/// `buildEncryptedProviderConfig` carries unknown keys through as PLAINTEXT
/// identifiers, so a misspelled `authToken` would be stored unencrypted and the real
/// one deleted (its `else` arm drops a secret field that arrives blank with nothing
/// stored). These are the route's own spellings.
enum MessagingCatalog {
    /// ⛔ The route's `PROVIDERS`, in its own order. Anything else is a 400
    /// "Unsupported provider".
    static let providers = ["twilio", "sinch", "telnyx"]

    /// ⛔ `managed` IS AN ENTITLEMENT, NOT A PREFERENCE, AND THE SERVER DECIDES.
    /// Sending it makes the credentials resolver hand this workspace the PLATFORM's
    /// shared keys, so the route checks entitlement independently and answers **403**
    /// naming support when the workspace is not on a managed plan. This client offers
    /// the option and surfaces the refusal; it must never pre-decide entitlement,
    /// because nothing it can read tells it.
    static let credentialSources = ["byok", "managed"]

    /// ⛔ The route validates against exactly these three; a fourth is a 400 naming the
    /// value.
    static let channels = ["sms", "voice", "whatsapp"]

    /// ⚠️ SINCH'S `projectId` IS NOT A SECRET and is stored in the clear, which is why
    /// it is on the form at all. ⚠️ `smsRegion` is deliberately NOT offered: it is a
    /// stored plaintext key defaulting to `us` server-side, and a free-text region box
    /// on a phone is a way to break an EU account's routing with a typo. An edit from
    /// here omits the key, so a stored value survives the merge untouched.
    static func credentialFields(for provider: String) -> [MessagingCredentialField] {
        switch provider {
        case "twilio":
            [
                MessagingCredentialField(key: "accountSid", label: "Account SID", isSecret: true),
                MessagingCredentialField(key: "authToken", label: "Auth token", isSecret: true),
            ]
        case "sinch":
            [
                MessagingCredentialField(key: "projectId", label: "Project id", isSecret: false),
                MessagingCredentialField(key: "keyId", label: "Key id", isSecret: true),
                MessagingCredentialField(key: "keySecret", label: "Key secret", isSecret: true),
                MessagingCredentialField(key: "applicationKey", label: "Application key", isSecret: true),
                MessagingCredentialField(
                    key: "applicationSecret",
                    label: "Application secret",
                    isSecret: true
                ),
            ]
        case "telnyx":
            [MessagingCredentialField(key: "apiKey", label: "API key", isSecret: true)]
        default:
            // ⚠️ EMPTY RATHER THAN A CRASH. A provider added server-side must not break
            // the settings screen on an already-installed build; the form draws no
            // credential boxes and the save is refused by the route's own allowlist,
            // which is the honest place for that refusal.
            []
        }
    }

    static func providerLabel(_ provider: String) -> String {
        provider.prefix(1).uppercased() + provider.dropFirst()
    }
}

/// One account being created or edited.
///
/// ⛔ ``secrets`` IS KEYED BY THE ROUTE'S OWN FIELD NAMES AND A BLANK ENTRY MEANS
/// "KEEP". That is the whole reason this form can exist against a read that carries no
/// credential: `buildEncryptedProviderConfig` reuses `existing[field]` when the
/// incoming value is blank or absent, so an operator editing a label never touches a
/// credential. ``providerConfig(includingProvider:)`` therefore OMITS a blank rather
/// than sending `""`, because the two are only equivalent for SECRET fields — for a
/// plaintext one an empty string would be merged in and stored.
///
/// ⛔ CHANGING ``provider`` ON AN EXISTING ACCOUNT DISCARDS THE STORED SECRETS. The
/// route only reuses `existingEnc` when the provider is unchanged, so on a switch a
/// blank box means "store nothing" rather than "keep" — ``secretsRequired`` is what the
/// form uses to say so.
///
/// ⛔ ``phoneNumbers`` IS SENT ONLY WHEN ``numbersEdited``. Sending the parsed list
/// unconditionally would make "open the form, change the label, save" rewrite the
/// account's numbers from whatever this client happened to render, and an empty box
/// would REMOVE them all and release their hub claims. The read gives us the numbers,
/// so the round trip is usually lossless; "usually" is not good enough for the field
/// that routes inbound calls.
struct MessagingDraft {
    /// ⚠️ Nil for a create. The server mints `acct-<uuid>`; nothing here may invent
    /// one.
    var accountId: String?
    var provider = "twilio"
    var credentialSource = "byok"
    var label = ""
    var secrets: [String: String] = [:]
    /// ⚠️ One per line as typed. Parsed by ``parsedNumbers``; never sent unless
    /// ``numbersEdited``.
    var phoneNumbers = ""
    var numbersEdited = false
    var makeDefault = false
    /// ⚠️ The provider this draft STARTED on, so a switch can be detected. Nil for a
    /// create.
    var originalProvider: String?

    var isCreate: Bool {
        accountId == nil
    }

    /// ⛔ TRUE WHEN A BLANK SECRET WOULD BE STORED AS ABSENT RATHER THAN PRESERVED — a
    /// create, or an edit that switched provider. The form says so instead of letting
    /// someone save an account with no credentials at all, which the route accepts (it
    /// deletes the key) and which then fails at send time with nothing pointing back
    /// here.
    var secretsRequired: Bool {
        guard let originalProvider else { return true }
        return originalProvider != provider
    }

    /// ⚠️ Blank entries dropped and each one trimmed, mirroring the route's own filter.
    var parsedNumbers: [String] {
        phoneNumbers
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// ⛔ EVERY SECRET FIELD MUST BE FILLED WHEN ``secretsRequired``, BECAUSE A
    /// HALF-FILLED SET IS WORSE THAN AN EMPTY ONE. The route encrypts what it gets and
    /// drops what it does not, so saving Twilio with a SID and no auth token stores a
    /// credential that can never authenticate.
    var credentialsComplete: Bool {
        MessagingCatalog.credentialFields(for: provider)
            .filter(\.isSecret)
            .allSatisfy { !value(for: $0.key).isEmpty }
    }

    var canSave: Bool {
        !secretsRequired || credentialsComplete
    }

    /// ⛔ THE PROBE NEEDS PLAINTEXT THIS FORM ACTUALLY HOLDS, so it is offered only when
    /// every field the test route reads for this provider is filled — including Sinch's
    /// PLAINTEXT `projectId`, which its client constructor requires and which is not a
    /// secret. Sending blanks would report a carrier's 401 as though the STORED
    /// credentials were broken, on the one screen where believing that leads someone to
    /// retype a live carrier secret.
    var canTest: Bool {
        let fields = MessagingCatalog.credentialFields(for: provider)
        return !fields.isEmpty && fields.allSatisfy { !value(for: $0.key).isEmpty }
    }

    func value(for key: String) -> String {
        secrets[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The wire shape.
    ///
    /// ⚠️ `provider` IS OMITTED FOR A SAVE AND SET FOR THE PROBE. The save route deletes
    /// the key on arrival, so including it would be harmless and misleading;
    /// `messaging/test` dispatches on it.
    ///
    /// ⛔ ``JSONValue/object(_:)`` DROPS A NIL PAIR, WHICH IS THE OMIT-VERSUS-EMPTY RULE
    /// REACHING THE WIRE. A blank box produces nil here and therefore no key at all.
    func providerConfig(includingProvider: Bool) -> JSONValue {
        var pairs: [(String, JSONValue?)] = [
            ("provider", includingProvider ? .string(provider) : nil),
            ("phoneNumbers", numbersEdited ? .array(parsedNumbers.map { JSONValue.string($0) }) : nil),
        ]
        for field in MessagingCatalog.credentialFields(for: provider) {
            let typed = value(for: field.key)
            pairs.append((field.key, typed.isEmpty ? nil : .string(typed)))
        }
        return .object(pairs)
    }

    /// Seed a draft from an account the read returned.
    ///
    /// ⛔ NO SECRET IS SEEDED AND NONE CAN BE. The GET projects five keys and not one of
    /// them is a credential; there is nothing on this device to pre-fill with, which is
    /// exactly why a blank box has to mean "keep".
    ///
    /// ⚠️ ``numbersEdited`` STARTS FALSE even though the box is pre-filled from the
    /// read. The box shows what is stored so the operator can see it; only a keystroke
    /// makes the list part of the save.
    static func editing(_ account: MessagingAccount) -> MessagingDraft {
        let provider = account.provider ?? "twilio"
        return MessagingDraft(
            accountId: account.id,
            provider: provider,
            credentialSource: account.credentialSource ?? "byok",
            label: account.label ?? "",
            phoneNumbers: account.phoneNumbers.joined(separator: "\n"),
            numbersEdited: false,
            originalProvider: provider
        )
    }
}
