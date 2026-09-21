import DistrictModel
@testable import DistrictNetwork
import Foundation
import XCTest

/// The one thing a routing-rule editor must never do: lose a key.
///
/// ⛔ `POST workspace/routing-rules` REPLACES THE STORED ARRAY WHOLESALE, its per-rule
/// zod schema is `.passthrough()` naming only `voice` and `model`, and the column is
/// `Json` holding whatever anyone ever wrote. The committed fixture proves the danger
/// rather than illustrating it: two of its three rows are shaped
/// `{id, match, action, target}`, which is not the shape the web's own rule builder
/// edits at all. Every assertion below is about what SURVIVES a round trip.
final class RoutingRuleDraftTests: XCTestCase {
    /// A rule in the shape the editor understands, plus a key nothing models.
    private let builderRow = WireJSON.object([
        "id": .string("rule-1"),
        "field": .string("industry"),
        "operator": .string("contains"),
        "value": .string("tech"),
        "voice": .string("Fenrir"),
        "instruction": .string("Speak with high energy."),
        "model": .string(""),
        // ⛔ THE UNMODELLED KEY. Nothing in this client reads it; everything in this
        // client must carry it.
        "createdBy": .string("someone@example.com"),
    ])

    /// The fixture's other shape, which this build cannot read at all.
    private let legacyRow = WireJSON.object([
        "id": .string("rule-contract-2"),
        "match": .string("support"),
        "action": .string("knowledge"),
        // ⚠️ AN EXPLICIT NULL INSIDE THE BLOB, which is part of the value rather than
        // an absence. ``JSONValue/carrying(_:)`` is lossless precisely for this.
        "target": .null,
    ])

    // MARK: - Hydration

    func testARecognisedRowHydratesItsSixFields() {
        let draft = RoutingRuleDraft(id: 0, row: builderRow)
        XCTAssertEqual(draft.field, "industry")
        XCTAssertEqual(draft.ruleOperator, "contains")
        XCTAssertEqual(draft.value, "tech")
        XCTAssertEqual(draft.voice, "Fenrir")
        XCTAssertEqual(draft.instruction, "Speak with high energy.")
        XCTAssertEqual(draft.model, "")
        XCTAssertTrue(draft.isRecognised)
    }

    /// ⛔ A LEGACY ROW OPENS ENTIRELY BLANK AND IS MARKED UNRECOGNISED, which is the
    /// honest rendering of "this build cannot read this rule". Defaulting its fields
    /// to `industry`/`contains` would make an un-editable rule LOOK editable, and
    /// saving would then change who gets routed where.
    func testALegacyRowIsNotRecognisedAndInventsNothing() {
        let draft = RoutingRuleDraft(id: 0, row: legacyRow)
        XCTAssertFalse(draft.isRecognised)
        XCTAssertEqual(draft.field, "")
        XCTAssertEqual(draft.ruleOperator, "")
        XCTAssertEqual(draft.voice, "")
    }

    /// ⚠️ A FIELD OR OPERATOR THIS BUILD HAS NEVER HEARD OF ALSO READS AS
    /// UNRECOGNISED, so a rule naming a vocabulary entry added after this build
    /// shipped is carried rather than rewritten.
    func testAnUnknownVocabularyEntryReadsAsUnrecognised() {
        let future = WireJSON.object([
            "field": .string("lifetimeValue"),
            "operator": .string("contains"),
            "value": .string("high"),
        ])
        XCTAssertFalse(RoutingRuleDraft(id: 0, row: future).isRecognised)

        let negation = WireJSON.object([
            "field": .string("industry"),
            "operator": .string("notContains"),
            "value": .string("tech"),
        ])
        XCTAssertFalse(RoutingRuleDraft(id: 0, row: negation).isRecognised)
    }

    // MARK: - Rendering

    /// ⛔ THE HEADLINE. An edit to one field rewrites that field and NOTHING ELSE —
    /// `createdBy` and `id` survive byte-identically. A row rebuilt from the six
    /// fields this editor owns would strip them and be answered 200, which is a
    /// silent deletion inside somebody's rule rather than of one.
    func testAnEditPreservesEveryKeyTheEditorDoesNotOwn() {
        var draft = RoutingRuleDraft(id: 0, row: builderRow)
        draft.value = "finance"
        guard case let .object(rendered) = draft.rendered() else {
            return XCTFail("expected an object")
        }
        XCTAssertEqual(rendered["value"], .string("finance"))
        XCTAssertEqual(rendered["createdBy"], .string("someone@example.com"))
        XCTAssertEqual(rendered["id"], .string("rule-1"))
        XCTAssertEqual(Set(rendered.keys), Set([
            "id",
            "field",
            "operator",
            "value",
            "voice",
            "instruction",
            "model",
            "createdBy",
        ]))
    }

    /// ⛔ `""` ON `model` IS A REAL, MEANINGFUL VALUE — the route reads a falsy model
    /// as "no override, use the workspace engine" — so it is written rather than
    /// dropped. Dropping it works today and is a different instruction the day the
    /// route starts distinguishing absent from empty.
    func testAnEmptyModelIsWrittenRatherThanDropped() {
        var draft = RoutingRuleDraft.added(id: 0)
        draft.value = "tech"
        guard case let .object(rendered) = draft.rendered() else {
            return XCTFail("expected an object")
        }
        XCTAssertEqual(rendered["model"], .string(""))
    }

    /// ⚠️ WHITESPACE IS TRIMMED ON EVERY FIELD, because a match value that is one
    /// space longer than the caller's industry silently matches nothing.
    func testEveryFieldIsTrimmedOnTheWayOut() {
        var draft = RoutingRuleDraft.added(id: 0)
        draft.value = "  tech  "
        draft.instruction = "\nSpeak up.\n"
        guard case let .object(rendered) = draft.rendered() else {
            return XCTFail("expected an object")
        }
        XCTAssertEqual(rendered["value"], .string("tech"))
        XCTAssertEqual(rendered["instruction"], .string("Speak up."))
    }

    /// ⛔ AN UNRECOGNISED ROW GOES BACK EXACTLY AS IT CAME, EXPLICIT NULL INCLUDED.
    /// ``JSONValue/carrying(_:)`` builds `.object` directly rather than through
    /// ``JSONValue/object(_:)``, whose whole job is to drop nils — dropping one here
    /// would delete `target` on a route that answers 200 either way.
    func testAnUnrecognisedRowIsCarriedBackWithItsNullIntact() {
        let draft = RoutingRuleDraft(id: 0, row: legacyRow)
        guard case let .object(carried)? = draft.carriedUnchanged() else {
            return XCTFail("expected a carried object")
        }
        XCTAssertEqual(carried["target"], .null)
        XCTAssertEqual(Set(carried.keys), Set(["id", "match", "action", "target"]))
    }

    /// ⚠️ nil ONLY FOR AN ADDED ROW, which by construction has nothing stored to
    /// carry.
    func testAnAddedRowHasNothingToCarry() {
        XCTAssertNil(RoutingRuleDraft.added(id: 7).carriedUnchanged())
    }

    // MARK: - Which rows are sent at all

    /// ⛔ A SERVER ROW IS NEVER BLANK, HOWEVER EMPTY ITS FIELDS LOOK. Dropping one
    /// would be a deletion the operator did not ask for, through a route that
    /// replaces the array wholesale — and the legacy rows are exactly the case: every
    /// field the editor reads is empty and the rule is live.
    func testAStoredRowIsNeverTreatedAsBlank() {
        XCTAssertFalse(RoutingRuleDraft(id: 0, row: legacyRow).isBlank)
        XCTAssertFalse(RoutingRuleDraft(id: 0, row: .object([:])).isBlank)
    }

    /// ⚠️ AN ADDED ROW NOBODY FILLED IN IS THE ADD BUTTON PRESSED AND ABANDONED, and
    /// saving it would grow the stored array by one every time.
    func testAnUntouchedAddedRowIsBlankAndATouchedOneIsNot() {
        XCTAssertTrue(RoutingRuleDraft.added(id: 0).isBlank)

        var withValue = RoutingRuleDraft.added(id: 1)
        withValue.value = "tech"
        XCTAssertFalse(withValue.isBlank)

        var withInstruction = RoutingRuleDraft.added(id: 2)
        withInstruction.instruction = "Speak up."
        XCTAssertFalse(withInstruction.isBlank)
    }

    /// ⚠️ A RULE WITH NOTHING TO MATCH ON IS FLAGGED, NOT REFUSED. It is legal, it is
    /// stored, and it simply never fires — which is what an operator opened the screen
    /// to find out.
    func testARuleWithNoMatchValueIsFlaggedAsIncomplete() {
        XCTAssertTrue(RoutingRuleDraft(id: 0, row: legacyRow).isIncomplete)
        XCTAssertFalse(RoutingRuleDraft(id: 0, row: builderRow).isIncomplete)
    }

    /// ⛔ THE ADD DEFAULTS ARE THE WEB'S EXACTLY. A rule created on one platform and
    /// opened on the other must not look like somebody changed it.
    func testAnAddedRuleStartsOnTheWebFormsOwnDefaults() {
        let added = RoutingRuleDraft.added(id: 3)
        XCTAssertEqual(added.field, RoutingRuleField.industry.rawValue)
        XCTAssertEqual(added.ruleOperator, RoutingRuleOperator.contains.rawValue)
        XCTAssertEqual(added.voice, "Puck")
        XCTAssertEqual(added.value, "")
        XCTAssertEqual(added.instruction, "")
        XCTAssertTrue(added.isRecognised)
    }
}

/// The two vocabularies no route publishes and no route validates.
final class RoutingRuleVocabularyTests: XCTestCase {
    /// ⛔ SIX FIELDS AND TWO OPERATORS, PINNED AGAINST THE WEB ROUTING FORM. The
    /// save route validates neither, so a Swift list that quietly gained a seventh
    /// would offer a field that matches no caller for the life of the rule, with a
    /// 200 and nothing anywhere reporting it.
    func testTheWireVocabulariesAreExactlyTheWebFormsOwn() {
        XCTAssertEqual(
            RoutingRuleField.allCases.map(\.rawValue),
            ["industry", "estimatedValue", "callerType", "lineType", "isDecisionMaker", "seniority"]
        )
        XCTAssertEqual(RoutingRuleOperator.allCases.map(\.rawValue), ["contains", "equals"])
    }

    /// ⚠️ THE LABELS CARRY THEIR VALUE HINTS AND THAT IS LOAD-BEARING. The match is a
    /// substring test against a value nothing documents on screen, so dropping the
    /// parenthetical to make the list look tidier is how an operator types "Business"
    /// into a field that holds `business`.
    func testTheLabelsKeepTheirValueHints() {
        XCTAssertEqual(RoutingRuleField.callerType.label, "Caller Type (business/consumer)")
        XCTAssertEqual(RoutingRuleField.lineType.label, "Line Type (mobile/landline/voip)")
        XCTAssertEqual(RoutingRuleField.isDecisionMaker.label, "Decision Maker (true/false)")
        XCTAssertEqual(RoutingRuleField.seniority.label, "Seniority (e.g. vp, c-suite)")
        XCTAssertEqual(RoutingRuleField.industry.label, "Industry")
        XCTAssertEqual(RoutingRuleField.estimatedValue.label, "Estimated Value")
        XCTAssertEqual(RoutingRuleOperator.contains.label, "Contains")
        XCTAssertEqual(RoutingRuleOperator.equals.label, "Equals")
    }

    /// ⛔ AN UNKNOWN STORED VALUE ANSWERS nil AND IS NOT CORRECTED TO THE FIRST CASE.
    /// `RoutingRuleField(rawValue:)` would do the same; ``RoutingRuleField/known(_:)``
    /// exists so a nil INPUT is answered the same way rather than at a call site.
    func testAnUnknownOrAbsentValueIsNotSilentlyNormalised() {
        XCTAssertNil(RoutingRuleField.known("lifetimeValue"))
        XCTAssertNil(RoutingRuleField.known(nil))
        XCTAssertNil(RoutingRuleOperator.known("notContains"))
        XCTAssertNil(RoutingRuleOperator.known(nil))
        XCTAssertEqual(RoutingRuleField.known("seniority"), .seniority)
        XCTAssertEqual(RoutingRuleOperator.known("equals"), .equals)
    }
}
