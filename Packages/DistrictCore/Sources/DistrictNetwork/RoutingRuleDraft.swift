import DistrictModel
import Foundation

/// One dynamic-persona rule, as an editor holds it.
///
/// ⛔ IT CARRIES THE ORIGINAL ROW, AND THAT IS THE WHOLE DESIGN — the same one
/// ``RegulatoryDocumentUpload``'s neighbours make for the transfer directory, for
/// the same reason and with a larger blast radius. `POST workspace/routing-rules`
/// REPLACES the stored array wholesale, its per-rule zod schema is
/// `.passthrough()` naming only `voice` and `model`, and the column is `Json`
/// holding whatever anyone ever wrote. The committed fixture proves the point: two
/// of its three rows are shaped `{id, match, action, target}`, which is not the
/// shape the web's own rule builder edits at all. A row rebuilt from the six fields
/// below would strip the rest and be answered **200** — a silent deletion INSIDE
/// somebody's rule rather than of one.
///
/// ⛔ SO ``rendered()`` OVERWRITES EXACTLY THE SIX KEYS THIS FORM OWNS AND TOUCHES
/// NOTHING ELSE. A row whose `field` this build has never heard of round-trips
/// byte-identically as long as nobody edits it, which is what makes it safe to open
/// an editor over a corpus this client does not fully understand.
///
/// ⚠️ `source` IS nil FOR A RULE THE OPERATOR ADDED, the only case where there is
/// nothing to preserve.
public struct RoutingRuleDraft: Identifiable, Sendable, Equatable {
    /// ⛔ THE EDITOR'S OWN IDENTITY, NOT THE RULE'S `id` COLUMN. Rules are stored
    /// with an `id` that is sometimes a uuid, sometimes a timestamp string and
    /// sometimes absent entirely (the fixture's third row has none), so keying
    /// SwiftUI on it would make a row without one un-addressable and two rows
    /// sharing one animate as the same row. The stored `id` is carried through
    /// ``source`` untouched.
    public let id: Int

    public var field: String
    public var ruleOperator: String
    public var value: String
    public var voice: String
    public var instruction: String
    /// ⛔ `""` IS A REAL, MEANINGFUL VALUE AND IS NOT AN ABSENCE. The route reads a
    /// falsy `model` as "no override, use the workspace engine", and the web's own
    /// picker keeps an empty-string option for exactly that. Dropping the key
    /// instead would work today and is a different instruction the day the route
    /// starts distinguishing them.
    public var model: String

    private let source: WireJSON?

    /// Hydrate from a stored row.
    ///
    /// ⚠️ EVERY FIELD FALLS BACK TO `""` RATHER THAN TO A DEFAULT VALUE. A rule
    /// shaped `{id, match, action, target}` has none of the six keys, so it opens
    /// entirely blank — which is the honest rendering of "this build cannot read
    /// this rule", and ``isRecognised`` is what a screen asks before offering to
    /// edit it.
    public init(id: Int, row: WireJSON?) {
        self.id = id
        source = row
        field = RoutingRuleDraft.text(row?["field"])
        ruleOperator = RoutingRuleDraft.text(row?["operator"])
        value = RoutingRuleDraft.text(row?["value"])
        voice = RoutingRuleDraft.text(row?["voice"])
        instruction = RoutingRuleDraft.text(row?["instruction"])
        model = RoutingRuleDraft.text(row?["model"])
    }

    /// A new rule, on the same defaults the web's Add button uses.
    ///
    /// ⛔ THE DEFAULTS ARE THE WEB'S EXACTLY (`industry` / `contains` / `Puck`),
    /// because a rule created on one platform and opened on the other must not look
    /// like somebody changed it. ⚠️ `value` and `instruction` start empty, so a
    /// freshly added rule matches nothing until it is filled in — see
    /// ``isIncomplete``.
    public static func added(id: Int) -> RoutingRuleDraft {
        var draft = RoutingRuleDraft(id: id, row: nil)
        draft.field = RoutingRuleField.industry.rawValue
        draft.ruleOperator = RoutingRuleOperator.contains.rawValue
        draft.voice = defaultRuleVoice
        return draft
    }

    /// ⚠️ The web's own starting voice for a new rule.
    public static let defaultRuleVoice = "Puck"

    /// Whether this build understands the rule well enough to edit it.
    ///
    /// ⛔ A ROW THAT IS NOT RECOGNISED IS SHOWN AND NOT OFFERED AN EDITOR, rather
    /// than being hidden or rewritten. The committed fixture's `{id, match, action,
    /// target}` rows are live rules the agent evaluates; an editor over them would
    /// have to invent the six keys, and saving would then add them beside the four
    /// it could not read.
    public var isRecognised: Bool {
        RoutingRuleField.known(field) != nil && RoutingRuleOperator.known(ruleOperator) != nil
    }

    /// ⚠️ A RULE WITH NOTHING TO MATCH ON IS FLAGGED, NOT REFUSED. It is legal, it
    /// is stored, and it simply never fires — which is exactly what an operator
    /// opened the screen to find out. Deleting it on their behalf is not this
    /// type's decision.
    public var isIncomplete: Bool {
        RoutingRuleDraft.trimmed(value).isEmpty
    }

    /// Whether this row is worth sending at all.
    ///
    /// ⛔ ONLY AN ADDED ROW THAT WAS NEVER TOUCHED IS DROPPED, which is the Add
    /// button pressed and abandoned. A row that came from the server is NEVER blank
    /// by this test, because it carries its ``source``: dropping one would be a
    /// deletion the operator did not ask for, through a route that replaces the
    /// array wholesale.
    public var isBlank: Bool {
        guard source == nil else { return false }
        return RoutingRuleDraft.trimmed(value).isEmpty
            && RoutingRuleDraft.trimmed(instruction).isEmpty
    }

    /// The row to send: the original with this form's six keys overwritten.
    ///
    /// ⛔ IT STARTS FROM THE STORED OBJECT, NEVER FROM AN EMPTY ONE. See the ⛔ on
    /// this type.
    ///
    /// ⚠️ A TRIMMED-EMPTY FIELD IS WRITTEN AS AN EMPTY STRING RATHER THAN DROPPED,
    /// matching ``DirectoryDraft``'s reasoning: on a wholesale replace, dropping the
    /// key leaves the old value in place, which is the one direction that looks like
    /// the save silently failed.
    public func rendered() -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if case let .object(stored) = source {
            fields = stored.mapValues(JSONValue.carrying)
        }
        fields["field"] = .string(RoutingRuleDraft.trimmed(field))
        fields["operator"] = .string(RoutingRuleDraft.trimmed(ruleOperator))
        fields["value"] = .string(RoutingRuleDraft.trimmed(value))
        fields["voice"] = .string(RoutingRuleDraft.trimmed(voice))
        fields["instruction"] = .string(RoutingRuleDraft.trimmed(instruction))
        fields["model"] = .string(RoutingRuleDraft.trimmed(model))
        return .object(fields)
    }

    /// The row exactly as it was read, for a rule this build will not edit.
    ///
    /// ⛔ THE OTHER HALF OF ``isRecognised``. A screen that could only send
    /// ``rendered()`` would have to either drop an unrecognised rule or stamp six
    /// invented keys onto it; this carries it through byte-identically instead, so a
    /// save that edits one rule leaves the rest of the array exactly as the server
    /// holds it.
    ///
    /// ⚠️ nil ONLY FOR AN ADDED ROW, which by construction has no stored form.
    public func carriedUnchanged() -> JSONValue? {
        source.map(JSONValue.carrying)
    }

    private static func text(_ value: WireJSON?) -> String {
        value?.stringValue ?? ""
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
