import Foundation

/// The two vocabularies a dynamic-persona rule matches on.
///
/// ⛔ PINNED IN SWIFT BECAUSE NO ROUTE PUBLISHES THEM, WHICH MAKES THEM THE ONE
/// HARDCODED CATALOGUE IN THIS FEATURE AND THE ONE THAT HAS TO BE. Everything else
/// the routing editor offers is read from `persona/options` precisely so a Swift
/// literal cannot drift — but `field` and `operator` exist only in
/// `PersonaRoutingForm.tsx`'s own `AVAILABLE_FIELDS` and `AVAILABLE_OPERATORS`
/// arrays, and `POST workspace/routing-rules` validates neither. The route's zod
/// schema is `.passthrough()` and names only `voice` and `model`, so a misspelled
/// field is stored, answered **200**, and then matches no caller for the life of
/// the rule.
///
/// ⛔ SO A STORED VALUE THIS LIST DOES NOT KNOW IS SHOWN, NOT CORRECTED. The column
/// is `Json` and predates every schema on it; a rule naming a field retired from
/// the web form is still the rule the agent evaluates today, and an editor that
/// quietly normalised it to `industry` would change who gets routed where on the
/// next save, with nothing on screen saying so.
///
/// ⚠️ COPIED FROM THE WEB FORM VERBATIM, LABELS INCLUDED. Three of the six labels
/// carry their own value hints ("Caller Type (business/consumer)") because the
/// match is a substring test against a value nothing documents on screen; dropping
/// the hint to make the list look tidier is how an operator types "Business" into a
/// field that holds `business`.
public enum RoutingRuleField: String, CaseIterable, Sendable, Equatable {
    /// From contact enrichment.
    case industry
    /// From contact enrichment. ⚠️ A NUMBER-SHAPED STRING, matched as text: the
    /// operators are `contains` and `equals`, so there is no ordering comparison
    /// available and "over £50k" is not expressible.
    case estimatedValue
    /// ⚠️ Caller-ID intelligence, cached per contact by Twilio Lookup on an inbound
    /// call. Absent until a caller has been looked up once.
    case callerType
    /// ⚠️ Caller-ID intelligence. See ``callerType``.
    case lineType
    /// ⚠️ The DGI person block, populated by contact enrichment — which is OFF by
    /// default (`dgiEnabled`), so a rule on this field matches nothing at all for a
    /// workspace that has never consented.
    case isDecisionMaker
    /// ⚠️ The DGI person block. See ``isDecisionMaker``.
    case seniority

    /// ⛔ THE WEB FORM'S OWN LABEL, INCLUDING ITS PARENTHETICAL VALUE HINTS. See the
    /// ⚠️ on the type.
    public var label: String {
        switch self {
        case .industry: "Industry"
        case .estimatedValue: "Estimated Value"
        case .callerType: "Caller Type (business/consumer)"
        case .lineType: "Line Type (mobile/landline/voip)"
        case .isDecisionMaker: "Decision Maker (true/false)"
        case .seniority: "Seniority (e.g. vp, c-suite)"
        }
    }

    /// ⚠️ nil FOR A STORED VALUE THIS BUILD DOES NOT KNOW, which a caller renders as
    /// the raw string rather than replacing. See the ⛔ on the type.
    public static func known(_ wire: String?) -> RoutingRuleField? {
        guard let wire else { return nil }
        return RoutingRuleField(rawValue: wire)
    }
}

/// How a rule's value is compared.
///
/// ⛔ TWO, AND THERE IS NO NEGATION AND NO ORDERING. Both are substring-or-equality
/// tests on a string, so "is not" and "greater than" are not expressible — a rule
/// that needs either has to be inverted into the persona's own instruction instead.
/// Adding a third here without the agent understanding it would store a rule that
/// silently never matches.
public enum RoutingRuleOperator: String, CaseIterable, Sendable, Equatable {
    case contains
    case equals

    public var label: String {
        switch self {
        case .contains: "Contains"
        case .equals: "Equals"
        }
    }

    /// ⚠️ nil FOR A STORED VALUE THIS BUILD DOES NOT KNOW. See ``RoutingRuleField``.
    public static func known(_ wire: String?) -> RoutingRuleOperator? {
        guard let wire else { return nil }
        return RoutingRuleOperator(rawValue: wire)
    }
}

public extension PersonaOptionsResponse {
    /// The voices a ROUTING RULE may name, which is not the persona's own list.
    ///
    /// ⛔ THE WEB FORM HARDCODES FIVE NAMES (`AVAILABLE_VOICES = ["Puck", "Fenrir",
    /// "Aoede", "Charon", "Kore"]`) AND THEY ARE EXACTLY THE GEMINI LIVE CATALOGUE.
    /// Deriving them from the options payload rather than restating them is the
    /// same decision the web made for its MODEL list one line below its voice list
    /// — that one was hand-written, never gained `inworld-pipeline` after the
    /// owner-email allowlist was removed, and a routing rule could not select an
    /// engine the persona form and the agent both supported. The fix there was to
    /// derive; this is the same fix applied to the half that has not needed it yet.
    ///
    /// ⚠️ THE LANGUAGE IS IRRELEVANT AND IT IS STILL CHOSEN EXPLICITLY. Gemini Live
    /// publishes the identical five voices for every language it carries, so the
    /// first published entry is as good as any — but `first(where:)` on the ENGINE
    /// alone is what makes that an assumption rather than a coincidence, so the
    /// entry is looked up by engine and whatever language it came with.
    ///
    /// ⚠️ EMPTY IS A REAL ANSWER. A catalogue with no Gemini Live entry leaves the
    /// picker with nothing to offer, at which point a rule's stored voice is shown
    /// as-is and cannot be changed — which is honest, and is what the ⛔ on
    /// ``RoutingRuleField`` asks for everywhere else on this screen.
    func routingVoices() -> [PersonaLabelledValue] {
        guard let entry = voices.first(where: { $0.engine == PersonaEngineCapabilities.geminiLiveEngine })
        else { return [] }
        return entry.groups.flatMap(\.options)
    }

    /// The engines a routing rule may override the workspace's with.
    ///
    /// ⛔ EVERY ENGINE, NOT ONLY THE IN-REGION ONES, AND THAT IS NOT AN OVERSIGHT
    /// EITHER WAY — it is the one place this client declines to decide. The web's
    /// rule form shows no region badge at all, deliberately, because the residency
    /// consequence of a rule is the same as the workspace's and belongs on the
    /// persona form where the engine is actually chosen. ⚠️ So the caller applies
    /// the same `inRegion` disabling the persona picker does, from the same
    /// ``PersonaEngineOption`` values, rather than this returning a pre-filtered
    /// list that would make the two screens disagree about what exists.
    func routingEngines() -> [PersonaEngineOption] {
        engines
    }
}
