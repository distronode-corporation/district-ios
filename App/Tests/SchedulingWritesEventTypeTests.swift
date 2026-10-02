@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The event-type editor: what it refuses, what it sends, and what it says when
/// the booking system refuses back.
@MainActor
final class SchedulingWritesEventTypeTests: XCTestCase {
    // MARK: - The slug nobody types

    /// ⛔ THE SLUG IS DERIVED AND PERMANENT. It is the last segment of a public URL
    /// and `eventTypes.patch` cannot change it, so the derivation is the only
    /// chance to get it right.
    func testTheSlugIsTheWebsSlug() {
        XCTAssertEqual(SchedulingEventTypeSlug.fromName("Phone consultation"), "phone-consultation")
        XCTAssertEqual(SchedulingEventTypeSlug.fromName("  Café  Crème  "), "cafe-creme")
        XCTAssertEqual(SchedulingEventTypeSlug.fromName("30 min / intro!!"), "30-min-intro")
    }

    /// ⚠️ AN EMPTY RESULT IS NOT AN EMPTY SLUG. The fork requires one character.
    func testANameWithNothingUsableStillProducesASlug() {
        XCTAssertEqual(SchedulingEventTypeSlug.fromName("—"), "event-type")
        XCTAssertEqual(SchedulingEventTypeSlug.fromName(""), "event-type")
    }

    /// ⛔ THE CUT TO 200 CAN PUT A TRAILING HYPHEN BACK, and the fork refuses one.
    func testTheLengthCutCannotLeaveATrailingHyphen() {
        let name = String(repeating: "a", count: 199) + " tail"
        let slug = SchedulingEventTypeSlug.fromName(name)
        XCTAssertEqual(slug.count, 199)
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    func testACollisionWithARowOnScreenWalksToTheNextNumber() {
        let slug = SchedulingEventTypeSlug.unique(
            from: "Phone consultation",
            taken: ["phone-consultation", "phone-consultation-2"]
        )
        XCTAssertEqual(slug, "phone-consultation-3")
    }

    // MARK: - Create

    /// ⛔ FOUR KEYS AND NOT FOURTEEN. `eventTypes.create` REFUSES fourteen of the
    /// fields `eventTypes.patch` accepts, so a create carrying them is a 400
    /// naming a control the operator was invited to fill in.
    func testACreateSendsExactlyTheFourKeysTheWebSends() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        var saved: SchedulingEventType?
        let model = Self.editor(transport) { change in
            if case let .saved(row) = change {
                saved = row
            }
        }
        model.form.name = "Phone consultation"
        model.form.duration = "45"
        model.form.location = "phone"
        await model.save()

        let call = SchedulingWritesFixtures.lastCall(transport)
        XCTAssertEqual(call?.op, "eventTypes.create")
        XCTAssertEqual(Set((call?.params ?? [:]).keys), [
            "slug",
            "name",
            "duration_minutes",
            "location_type",
        ])
        XCTAssertEqual(call?.params["slug"] as? String, "phone-consultation")
        XCTAssertEqual(call?.params["duration_minutes"] as? Int, 45)
        XCTAssertEqual(call?.params["location_type"] as? String, "phone")
        XCTAssertEqual(saved?.slug, "phone-consultation")
    }

    /// ⚠️ THE NAME IS TRIMMED BEFORE IT IS SENT, so a trailing space is not stored
    /// as part of the name and is not part of the slug either.
    func testTheNameIsTrimmed() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport)
        model.form.name = "  Phone consultation  "
        await model.save()
        XCTAssertEqual(SchedulingWritesFixtures.lastCall(transport)?.params["name"] as? String, "Phone consultation")
    }

    /// ⛔ A REFUSED FORM SPENDS NO REQUEST. Being told after a round trip is the
    /// thing mirroring the web's validation exists to avoid.
    func testAnEmptyNameIsRefusedWithoutSendingAnything() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport)
        model.form.name = "   "
        await model.save()

        XCTAssertEqual(model.validation, "Give the event type a name.")
        XCTAssertTrue(SchedulingWritesFixtures.calls(transport).isEmpty)
    }

    func testADurationThatIsNotAWholeMinuteIsRefused() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport)
        model.form.name = "Intro"
        model.form.duration = "0"
        await model.save()

        XCTAssertEqual(model.validation, "The duration has to be a whole number of minutes, at least 1.")
        XCTAssertTrue(SchedulingWritesFixtures.calls(transport).isEmpty)
    }

    // MARK: - Edit

    /// ⛔ THE SLUG IS IN THE BODY AS WELL AS BEING THE ADDRESS. The route validates
    /// the whole params object against a schema that REQUIRES it and strips it
    /// afterwards, so a client that removed it first gets a 400.
    func testAnEditPatchesEveryFieldTheGeneralFormOwns() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport, editing: Self.row())
        model.form.name = "Renamed"
        model.form.interval = "15"
        model.form.isPublic = false
        model.form.bufferAfter = "10"
        await model.save()

        let call = SchedulingWritesFixtures.lastCall(transport)
        XCTAssertEqual(call?.op, "eventTypes.patch")
        XCTAssertEqual(call?.params["slug"] as? String, "phone-consultation")
        XCTAssertEqual(call?.params["name"] as? String, "Renamed")
        XCTAssertEqual(call?.params["slot_interval_minutes"] as? Int, 15)
        XCTAssertEqual(call?.params["is_public"] as? Bool, false)
        XCTAssertEqual(call?.params["buffer_after_minutes"] as? Int, 10)
    }

    /// ⛔ ARCHIVING IS NOT PART OF THE EDITOR. It is a `patch` too, and putting it
    /// on the same form as the name would let a rename hide an event type.
    func testTheEditorNeverSendsArchived() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport, editing: Self.row())
        model.form.name = "Renamed"
        await model.save()

        XCTAssertNil(SchedulingWritesFixtures.lastCall(transport)?.params["archived"])
    }

    /// ⚠️ AN ABSENT `is_active` READS AS ON, WHICH IS THE WIRE'S THREE-STATE
    /// PROBLEM. The key is omitted rather than sent false, so defaulting it to off
    /// would turn every unstamped event type inactive on the first save.
    func testAnAbsentActiveFlagOpensAsActive() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport, editing: Self.row())
        XCTAssertTrue(model.form.isActive)
        await model.save()
        XCTAssertEqual(SchedulingWritesFixtures.lastCall(transport)?.params["is_active"] as? Bool, true)
    }

    func testAnIntervalBelowOneMinuteIsRefused() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport, editing: Self.row())
        model.form.interval = ""
        await model.save()

        XCTAssertEqual(model.validation, "Has to be a whole number of minutes, at least 1.")
        XCTAssertTrue(SchedulingWritesFixtures.calls(transport).isEmpty)
    }

    func testANegativeBufferIsRefused() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport, editing: Self.row())
        model.form.bufferBefore = "-1"
        await model.save()

        XCTAssertEqual(model.validation, "Has to be a whole number, 0 or more.")
    }

    /// ⚠️ A STORED LOCATION THIS BUILD DOES NOT OFFER STAYS ON THE PICKER. The
    /// fork's own CHECK constraint is wider than the catalog's allowlist and the
    /// four tiles are narrower again, so an event type made elsewhere must not be
    /// re-homed by being looked at.
    func testAStoredLocationOutsideTheOfferedFourIsStillSelectable() {
        let transport = SettingsTransport([SchedulingWritesFixtures.eventType()])
        let model = Self.editor(transport, editing: Self.row(extras: #","location_type":"google_meet""#))
        XCTAssertEqual(model.form.location, "google_meet")
        XCTAssertTrue(model.locationChoices.contains { $0.value == "google_meet" })
        // ⛔ The scheduler generates that join link, so there is no value field.
        XCTAssertNil(model.locationValueTitle)
    }

    // MARK: - Refusals

    /// ⛔ THE SENTENCE IS THE BROWSER'S, VERBATIM. Two clients explaining one
    /// refusal two ways is a bug report against whichever was seen second.
    func testAnUnavailableSchedulerGetsTheWebsSentenceAndOffersARetry() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.failure("unavailable")])
        let model = Self.editor(transport)
        model.form.name = "Intro"
        await model.save()

        XCTAssertEqual(model.state.failure?.message, "The booking system did not answer. Try again in a minute.")
        XCTAssertEqual(model.state.failure?.action, .retry)
    }

    /// ⛔ A ROLE REFUSAL OFFERS NO RETRY. The role will not change because somebody
    /// pressed the button again.
    func testAForbiddenWriteOffersNoRetry() async {
        let transport = SettingsTransport([#"{"error":"forbidden"}"#], status: 403)
        let model = Self.editor(transport)
        model.form.name = "Intro"
        await model.save()

        XCTAssertEqual(model.state.failure?.message, "You can view this but not change it.")
        XCTAssertEqual(model.state.failure?.action, FailureText.Action.none)
    }

    // MARK: - Fixtures

    private static func editor(
        _ transport: SettingsTransport,
        editing: SchedulingEventType? = nil,
        onSaved: @escaping (SchedulingEventTypeChange) -> Void = { _ in }
    ) -> SchedulingEventTypeEditorModel {
        SchedulingEventTypeEditorModel(
            admin: SchedulingWritesFixtures.repository(transport),
            workspaceId: "ws_1",
            editing: editing,
            takenSlugs: [],
            onSaved: onSaved
        )
    }

    /// ⚠️ THE MINIMUM THE WIRE GUARANTEES — four keys — so the optional handling is
    /// exercised rather than assumed away by a fat fixture.
    private static func row(extras: String = "") -> SchedulingEventType {
        let json = #"{"id":"et_1","slug":"phone-consultation","name":"Phone","duration_minutes":30\#(extras)}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SchedulingEventType.self, from: Data(json.utf8))
    }
}
