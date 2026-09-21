import DistrictModel
import Foundation
import SwiftUI

/// One renderable row of a DGI dossier. Ported from Android's `DossierField.kt`.
///
/// ⛔ THE DOSSIER HAS NO SCHEMA AND CANNOT BE GIVEN ONE. ``Contact/intelligence``
/// is a Prisma `Json?` column written by a model whose prompt changes; the keys it
/// carries today are not the keys it carried last month, and a struct pinned here
/// would break the screen on every prompt revision — silently, since a decode
/// failure on an Optional just yields nil. The shape is walked at render time
/// instead, and this is the intermediate the walk produces.
///
/// ⛔ AND THE WALK MUST NEVER THROW OR DROP. This is the one place in the app
/// rendering data no gate validates: the contract fixtures pin the CONTAINER
/// (`intelligence` is an object) and say nothing about what is inside it. Every
/// branch below therefore has a fallback, and the fallback is always "show the raw
/// JSON" rather than "show nothing" — an operator who can see an unfamiliar shape
/// can report it, whereas a silently dropped field looks like an enrichment that
/// found nothing.
struct DossierField: Identifiable {
    /// ⚠️ THE RAW JSON KEY, NOT A `UUID` AND NOT THE LABEL. Keys are unique within
    /// one object, which is exactly the scope a `ForEach` needs; a fresh UUID per
    /// render would rebuild every card on every redraw, and ``humanize(_:)`` can
    /// map two distinct keys (`executive_summary`, `executiveSummary`) onto one
    /// label.
    let id: String
    let label: String
    /// The scalar, or a joined list. nil when this field is a heading for
    /// ``children``.
    let value: String?
    /// Exactly ONE level of nesting. See ``dossierFields(_:)``.
    var children: [DossierField] = []
    /// True when ``value`` is formatted JSON rather than prose, so the renderer
    /// can say "this is a shape we did not recognise" rather than passing it off
    /// as something the model wrote.
    var raw = false
}

/// Flatten a dossier blob into rows.
///
/// ⛔ ONE LEVEL DEEP, DELIBERATELY, AND THE SECOND LEVEL DEGRADES TO RAW JSON
/// RATHER THAN RECURSING. Unbounded recursion over a model-authored object is
/// unbounded UI: a deeply nested blob renders as an accordion of nested cards
/// nobody can read and no test can pin.
///
/// ⚠️ NULLS AND EMPTIES ARE DROPPED. A key whose value is JSON null, an empty
/// array or an empty object carries no information, and a row reading
/// "Objections: —" is worse than its absence.
///
/// ⛔ ORDER IS ALPHABETICAL BY KEY, WHICH IS A REAL DIVERGENCE FROM ANDROID AND IS
/// NOT A CHOICE. kotlinx.serialization's `JsonObject` preserves the document's
/// insertion order, so the Kotlin client can render the dossier in the order the
/// model wrote it. ``WireJSON/object(_:)`` is a Swift `Dictionary`, whose order is
/// seeded per process — so "the model's order" is not merely unavailable here, it
/// would be a DIFFERENT arbitrary order on every launch. Sorting is the only
/// stable answer available; recovering the authored order would mean an
/// order-preserving decode in `DistrictModel`, which is a change to the wire type
/// rather than to this screen.
func dossierFields(_ source: WireJSON?) -> [DossierField] {
    guard let fields = source?.objectValue else { return [] }
    return fields.keys.sorted().compactMap { key in
        fields[key].flatMap { topLevelField(key: key, $0) }
    }
}

private func topLevelField(key: String, _ element: WireJSON) -> DossierField? {
    let label = humanize(key)
    switch element {
    case .null:
        return nil
    case .string, .integer, .number, .bool:
        return scalarText(element).map { DossierField(id: key, label: label, value: $0) }
    case let .array(values):
        return arrayField(id: key, label: label, values)
    case let .object(fields):
        return objectField(id: key, label: label, fields)
    }
}

/// ⚠️ AN ARRAY OF SCALARS IS A LIST; ANYTHING ELSE IS A SHAPE. The dossier's
/// arrays are usually `["wants thursday", "budget confirmed"]`, which reads as
/// bullet-ish prose. An array of objects is not something this renderer can
/// flatten honestly, so it degrades to raw JSON rather than to noise.
private func arrayField(id: String, label: String, _ values: [WireJSON]) -> DossierField? {
    guard !values.isEmpty else { return nil }
    let scalars = values.compactMap(scalarText)
    guard scalars.count == values.count else {
        return DossierField(id: id, label: label, value: prettyJSON(.array(values)), raw: true)
    }
    let joined = scalars.filter { !$0.isEmpty }.joined(separator: " · ")
    return joined.isEmpty ? nil : DossierField(id: id, label: label, value: joined)
}

/// ⚠️ A NESTED OBJECT BECOMES A HEADING PLUS SCALAR CHILDREN. A child that is
/// ITSELF a container becomes a raw-JSON child, which is the depth cap. An object
/// whose every value is empty produces no children and is dropped whole, rather
/// than leaving an empty heading.
private func objectField(id: String, label: String, _ fields: [String: WireJSON]) -> DossierField? {
    guard !fields.isEmpty else { return nil }
    let children = fields.keys.sorted().compactMap { key in
        fields[key].flatMap { childField(key: key, $0) }
    }
    guard !children.isEmpty else { return nil }
    return DossierField(id: id, label: label, value: nil, children: children)
}

private func childField(key: String, _ element: WireJSON) -> DossierField? {
    let label = humanize(key)
    switch element {
    case .null:
        return nil
    case .string, .integer, .number, .bool:
        return scalarText(element).map { DossierField(id: key, label: label, value: $0) }
    case let .array(values):
        return arrayField(id: key, label: label, values)
    case let .object(fields):
        // ⛔ THE DEPTH CAP. A grandchild object is shown as JSON, never as a third
        // card level.
        guard !fields.isEmpty else { return nil }
        return DossierField(id: key, label: label, value: prettyJSON(.object(fields)), raw: true)
    }
}

/// A scalar's text, or nil when it is not a scalar or has nothing in it.
///
/// ⚠️ THE STRING'S CONTENT, NOT ITS JSON SPELLING. Kotlin's equivalent trap is
/// `JsonPrimitive.toString()`, which re-serialises a string WITH its quotes so
/// every dossier value renders wrapped in `"`; numbers and booleans are
/// unaffected, which is exactly what makes it easy to miss in a spot check.
private func scalarText(_ element: WireJSON) -> String? {
    switch element {
    case let .string(value):
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    case let .integer(value):
        return String(value)
    case let .number(value):
        return String(value)
    case let .bool(value):
        return String(value)
    case .array, .object, .null:
        return nil
    }
}

/// "executiveSummary" → "Executive summary".
///
/// ⚠️ SPLITS ON camelCase AND ON snake_case, because the dossier has carried both.
/// A key matching neither is returned with only its first letter capitalised
/// rather than mangled: the point is legibility, not a guarantee of prose.
///
/// ⚠️ HAND-ROLLED RATHER THAN A REGEX, matching Kotlin's `([a-z0-9])([A-Z])`
/// boundary exactly. A `Regex` literal would be a second Swift-version question
/// on a screen that only the Mac can compile.
private func humanize(_ key: String) -> String {
    var spaced = ""
    var previous: Character?
    for character in key {
        if character == "_" {
            spaced.append(" ")
            previous = nil
            continue
        }
        if let previous, previous.isLowercase || previous.isNumber, character.isUppercase {
            spaced.append(" ")
        }
        spaced.append(character)
        previous = character
    }
    let trimmed = spaced.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first else { return key }
    // Lowercase the remaining words so "Executive Summary" reads as a label
    // rather than a title.
    return String(first).uppercased() + trimmed.dropFirst().lowercased()
}

/// ⚠️ PRETTY-PRINTED ON PURPOSE: the raw fallback exists to be READ by a person
/// deciding whether an unfamiliar shape is a problem, and a single-line blob is
/// not. `withoutEscapingSlashes` so a URL in the blob is legible, and so the
/// output does not differ between Darwin and Linux — the encoders disagree about
/// `/` and this is display text either way.
private func prettyJSON(_ value: WireJSON) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        return ""
    }
    return text
}

// MARK: - Rendering

/// A label over a value, in a card. The contact detail screen's only card shape.
struct ContactCard: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(value)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.gutter)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }
}

/// The District Global Intelligence dossier, and the two controls that manage it.
///
/// ⛔ THE STATE MACHINE HERE HAS FOUR OUTCOMES, NOT THREE. `dgiStatus` NULL means
/// "no dossier AND none queued" — `clear-intel` resets it to null deliberately so
/// nothing re-crawls — while pending/crawling/synthesizing mean one is running and
/// "failed" means one finished badly. Rendering null as pending would show a
/// spinner for a job that does not exist and leave the enrich control disabled
/// forever.
struct DossierSection: View {
    let contact: Contact
    let canMutate: Bool
    /// ⚠️ ONE `saving` FLAG FOR EVERY MUTATION ON THE SCREEN, so a second cannot
    /// race the first's re-read.
    let busy: Bool
    let isEnrichable: Bool
    let isClearable: Bool
    let onEnrich: () -> Void
    /// ⚠️ CALLED ONLY ONCE THE OPERATOR HAS CONFIRMED. The prompt belongs to the
    /// button, so a regular-width popover points at it; see ``actions``.
    let onClearIntel: () -> Void

    @State private var confirmingClear = false

    /// ⚠️ HOISTED TO A `String` CONSTANT RATHER THAN WRITTEN INLINE. A `+`
    /// concatenation passed straight to `.confirmationDialog` forces the type
    /// checker to choose between the `LocalizedStringKey` overload and the
    /// `StringProtocol` one at the call site. A named `String` picks the second
    /// unambiguously.
    private static let clearPrompt =
        "Clear this contact's Global Intelligence dossier? The contact, its phone number, "
            + "email and timeline are kept. Getting the dossier back means running enrichment again."

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            status
            company
            ForEach(dossierFields(contact.intelligence), id: \.id) { field in
                DossierFieldCard(field: field)
            }
            actions
        }
        // ⛔ `.contain` FIRST, or this identifier is inherited by the enrich and
        // clear-intel controls inside `actions`, both of which SPEND something, so
        // a test that thought it was asserting the section could tap one. See
        // SignInView's note on inheritance.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Contacts.dossier)
    }

    /// The one-line state of the dossier.
    ///
    /// ⚠️ A BADGE WHILE RUNNING, A CARD OTHERWISE. The running state is the only
    /// one worth drawing attention to: it is the one that will change on its own
    /// while the operator watches.
    @ViewBuilder
    private var status: some View {
        if DgiStatus.isInProgress(contact.dgiStatus) {
            DistrictBadge(text: "Building dossier…", tone: .warning)
        } else if let error = contact.dgiError {
            // ⚠️ THE SERVER'S OWN MESSAGE, VERBATIM. It names what the crawl could
            // not do, and a generic "enrichment failed" would throw away the only
            // diagnostic an operator ever gets for a pipeline that ran elsewhere.
            ContactCard(label: "Intelligence dossier", value: "Dossier failed: \(error)")
        } else if contact.intelligence == nil {
            ContactCard(label: "Intelligence dossier", value: "No dossier for this contact.")
        } else {
            ContactCard(label: "Intelligence dossier", value: "Dossier available")
        }
    }

    /// Firmographics.
    ///
    /// ⚠️ RENDERED HERE RATHER THAN BESIDE THE CONTACT'S OWN ATTRIBUTES, because
    /// it is not the contact's own: `company` is written by the SAME enrichment
    /// pipeline that writes `intelligence`, and `clear-intel` nulls both together.
    /// Showing it above, with the phone number, implied it was something the
    /// operator had typed.
    ///
    /// ⚠️ EVERY FIELD EMPTY IS THE SAME AS NO COMPANY AT ALL. The column is `Json?`
    /// and an empty object is a shape the pipeline genuinely writes.
    @ViewBuilder
    private var company: some View {
        let children = companyChildren
        if !children.isEmpty {
            DossierFieldCard(field: DossierField(id: "company", label: "Company", value: nil, children: children))
        }
    }

    private var companyChildren: [DossierField] {
        guard let company = contact.company else { return [] }
        let pairs = [
            ("name", "Name", company.name),
            ("domain", "Domain", company.domain),
            ("industry", "Industry", company.industry),
        ]
        return pairs.compactMap { key, label, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DossierField(id: key, label: label, value: value)
        }
    }

    /// ⛔ ENRICH IS OFFERED ONLY WHEN THE CONTACT IS NULL-OR-FAILED. Offering it
    /// while a crawl is running lets one impatient tap buy a second external crawl
    /// and a second LLM synthesis for a contact already being enriched: the
    /// endpoint is not idempotent and the server's rate limit is fail-open, so
    /// nothing behind this button would stop it.
    ///
    /// ⛔ AND BOTH ARE GATED ON THE ROLE. Both routes exclude `viewer`
    /// server-side, so a viewer would only ever earn a 403 they cannot act on.
    @ViewBuilder
    private var actions: some View {
        if canMutate {
            if isEnrichable {
                Button("Run Global Intelligence", action: onEnrich)
                    .buttonStyle(.districtSecondary)
                    .disabled(busy)
            }
            // ⚠️ Offered whenever there is something to clear, INCLUDING a failed
            // run: clearing is how a failed dossier's error is dismissed and the
            // contact returned to an enrichable state.
            if isClearable {
                Button("Clear dossier") { confirmingClear = true }
                    .buttonStyle(.districtGhost)
                    .disabled(busy)
                    // ⛔ CONFIRMED, BECAUSE CLEARING IS NOT RECOVERABLE AND IS NOT FREE
                    // TO UNDO: getting the dossier back means paying for another crawl
                    // and another model run. The prompt says so rather than asking a
                    // bare "are you sure".
                    .confirmationDialog(Self.clearPrompt, isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear dossier", role: .destructive, action: onClearIntel)
                        Button("Cancel", role: .cancel) {}
                    }
            }
        }
    }
}

/// One dossier row: a scalar, a joined list, or a heading with children.
struct DossierFieldCard: View {
    let field: DossierField

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(field.label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            if let value = field.value {
                // ⚠️ A DIFFERENT STYLE FOR RAW JSON, so a reader can tell "this is
                // a shape we did not recognise" from "this is what the model
                // wrote". The content is the same either way; the distinction is
                // the point.
                Text(value)
                    .font(field.raw ? DistrictType.caption : DistrictType.bodySmall)
                    .foregroundStyle(field.raw ? colors.mutedForeground : colors.foreground)
            }
            // ⚠️ One level deep only. A grandchild arrives already flattened to
            // JSON; see `childField`.
            ForEach(field.children, id: \.id) { child in
                VStack(alignment: .leading, spacing: 0) {
                    Text(child.label)
                        .font(DistrictType.labelSmall)
                        .foregroundStyle(colors.mutedForeground)
                    if let value = child.value {
                        Text(value)
                            .font(DistrictType.bodySmall)
                            .foregroundStyle(colors.foreground)
                    }
                }
                .padding(.top, DistrictSpacing.tight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.gutter)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }
}
