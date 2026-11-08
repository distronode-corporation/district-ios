@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// What steps 1 to 3 send: the website read's drafts, step 1's facts and rename, and the
/// persona fields step 3 owns. Steps 4 to 6 are `SetupLaterStepModelTests`.
@MainActor
final class SetupStepModelTests: SetupStepTestCase {
    // MARK: - Step 1

    /// ⛔ DRAFTS, NEVER LIVE FACTS, AND NO HOURS: the read appends services and questions switched
    /// off, keeps what was stored, and sends no `weeklyHours`.
    func testTheWebsiteReadAppendsDraftsSwitchedOffAndNeverHours() async throws {
        let transport = SetupTransport([SetupFixture.lookupRoute: [(200, SetupFixture.lookup)]])
        let stored = "{\"services\":[{\"name\":\"Cleaning\",\"enabled\":true}]}"
        let wizard = await wizard(transport, facts: stored)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup(facts: stored))
        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport))
        model.country = ""
        model.websiteUrl = " example.com "

        await model.readWebsite()

        let lookup = try XCTUnwrap(transport.bodies(SetupFixture.lookupRoute).first)
        XCTAssertEqual(lookup["websiteUrl"] as? String, "example.com")
        XCTAssertEqual(lookup["locale"] as? String, "en")
        let facts = try XCTUnwrap(transport.bodies(SetupFixture.patchRoute).first?["businessFacts"] as? [String: Any])
        XCTAssertNil(facts["weeklyHours"], "drafted hours are never stored")
        XCTAssertNil(facts["address"], "the drafted address fills the form, it is not saved by the read")
        let services = try XCTUnwrap(facts["services"] as? [[String: Any]])
        XCTAssertEqual(services.map { $0["name"] as? String }, ["Cleaning", "Whitening"], "the duplicate is skipped")
        XCTAssertEqual(services.map { $0["enabled"] as? Bool }, [true, false])
        XCTAssertEqual((facts["faqs"] as? [[String: Any]])?.first?["enabled"] as? Bool, false)
        XCTAssertEqual(model.city, "Toronto")
        XCTAssertEqual(model.country, "CA")
        XCTAssertEqual(model.subdivision, "ON")
        XCTAssertEqual(
            model.notice,
            .found("Found 2 services and 1 question. They are saved as drafts for step 4. "
                + "We found opening hours on your website; confirm them in step 4.")
        )
    }

    func testAnUnreadableWebsiteSaysSoAndWritesNothing() async {
        let transport = SetupTransport([SetupFixture.lookupRoute: [(422, SetupFixture.unreadable)]])
        let model = await SetupBusinessModel(wizard: wizard(transport), workspaces: workspaces(transport))
        model.websiteUrl = "example.invalid"

        await model.readWebsite()

        XCTAssertEqual(model.notice, .failed("That website could not be read."))
        XCTAssertTrue(transport.sent(SetupFixture.patchRoute).isEmpty)
    }

    func testAnEmptyFormIsRefusedOnTheDeviceAndSendsNothing() async {
        let transport = SetupTransport([:])
        let model = await SetupBusinessModel(wizard: wizard(transport), workspaces: workspaces(transport))
        model.businessName = " "
        model.city = ""

        await model.save()

        XCTAssertTrue(model.showErrors)
        XCTAssertEqual(model.nameError, "Enter your business name.")
        XCTAssertEqual(model.cityError, "Enter your city.")
        XCTAssertTrue(transport.sent(SetupFixture.patchRoute).isEmpty)
    }

    /// The facts, then a rename only because the name changed, then the step's state.
    func testSavingWritesThePlaceAndWhatYouDoRenamesAndCompletes() async throws {
        let renameBody = "{\"success\":true,\"name\":\"Bright Smiles\"}"
        let transport = SetupTransport([SetupFixture.renameRoute: [(200, renameBody)]])
        let wizard = await wizard(transport)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup())
        transport.add(SetupFixture.patchRoute, SetupFixture.setup(["done", "todo", "todo", "todo", "todo", "todo"]))
        var renamed = false
        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport), onRenamed: { renamed = true })
        model.businessName = "Bright Smiles"
        model.what = "Family dentist"
        model.choose(country: "CA")
        model.subdivision = "QC"
        model.city = "Laval"
        model.language = .fr

        await model.save()

        let facts = try XCTUnwrap(transport.bodies(SetupFixture.patchRoute).first?["businessFacts"] as? [String: Any])
        XCTAssertEqual(facts["timezone"] as? String, "America/Toronto")
        XCTAssertEqual(facts["address"] as? [String: String], ["city": "Laval", "region": "QC", "country": "CA"])
        let faqs = try XCTUnwrap(facts["faqs"] as? [[String: Any]])
        XCTAssertEqual(faqs.first?["question"] as? String, "Que fait l'entreprise?", "in the receptionist's language")
        XCTAssertEqual(faqs.first?["enabled"] as? Bool, true)
        XCTAssertEqual(transport.bodies(SetupFixture.renameRoute).first?["name"] as? String, "Bright Smiles")
        XCTAssertTrue(renamed)
        XCTAssertEqual(wizard.draft.language, .fr)
        XCTAssertEqual(wizard.active, .number)
    }

    /// A rename and then a rename back both reach the service: the comparison is with the name it
    /// holds now, not the one the wizard opened with.
    func testRenamingBackToTheOriginalNameIsSent() async {
        let renames: [(status: Int, body: String)] = [
            (200, "{\"success\":true,\"name\":\"Bright Smiles\"}"),
            (200, "{\"success\":true,\"name\":\"Northside Dental\"}"),
        ]
        let transport = SetupTransport([SetupFixture.renameRoute: renames])
        let wizard = await wizard(transport)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup())
        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport))
        model.choose(country: "US")
        model.subdivision = "NY"
        model.city = "Albany"

        model.businessName = "Bright Smiles"
        await model.save()
        wizard.back()
        model.businessName = "Northside Dental"
        await model.save()

        XCTAssertEqual(
            transport.bodies(SetupFixture.renameRoute).compactMap { $0["name"] as? String },
            ["Bright Smiles", "Northside Dental"]
        )
        XCTAssertEqual(wizard.workspaceName, "Northside Dental")
    }

    func testAnAddressOnlyReadStillSaysWhatItDid() {
        XCTAssertEqual(
            SetupBusinessModel.foundSentence(services: 0, faqs: 0, hours: false, address: true),
            "We filled in your address from your website. Check it below."
        )
        XCTAssertEqual(SetupBusinessModel.foundSentence(services: 0, faqs: 0, hours: false), "")
    }

    func testAnUnchangedNameIsNotRenamed() async {
        let transport = SetupTransport([:])
        let wizard = await wizard(transport)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup())
        let model = SetupBusinessModel(wizard: wizard, workspaces: workspaces(transport))
        model.businessName = "Northside Dental"
        model.choose(country: "US")
        model.subdivision = "NY"
        model.city = "Albany"

        await model.save()

        XCTAssertTrue(transport.sent(SetupFixture.renameRoute).isEmpty)
    }

    // MARK: - Step 3

    /// ⚠️ THE STARTER GREETING IS REPLACED BY THE BUSINESS'S OWN, and only what the step owns is sent.
    func testTheStarterGreetingBecomesTheBusinesssAndOnlyTheStepsFieldsAreSent() async throws {
        let starter = "Thanks for calling. This is Ava. How can I help you today?"
        let transport = SetupTransport([
            SetupFixture.configRoute: [(200, SetupFixture.config(name: "Ava", greeting: starter))],
            SetupFixture.optionsRoute: [(200, SetupFixture.options)],
            SetupFixture.personaRoute: [(200, SetupFixture.success)],
        ])
        let wizard = await wizard(transport)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup(["done", "done", "done", "todo", "todo", "todo"]))
        wizard.updateDraft(SetupBusinessDraft(
            businessName: "Bright Smiles",
            country: "CA",
            subdivision: "ON",
            city: "Toronto",
            language: .en
        ))
        let model = SetupReceptionistModel(wizard: wizard, workspaces: workspaces(transport))

        await model.load()
        XCTAssertEqual(model.greeting, "Thanks for calling Bright Smiles, this is Ava. How can I help?")
        XCTAssertEqual(model.voiceGroups.flatMap(\.options).map(\.value), ["Joanna", "Matthew"])
        model.name = "Mia"
        model.nameChanged()
        XCTAssertEqual(model.greeting, "Thanks for calling Bright Smiles, this is Mia. How can I help?")
        model.voice = "Matthew"
        await model.save()

        let body = try XCTUnwrap(transport.bodies(SetupFixture.personaRoute).first)
        XCTAssertEqual(
            Set(body.keys),
            ["workspaceId", "name", "greeting", "voice", "language"],
            "every other persona key is left as it is"
        )
        XCTAssertEqual(body["voice"] as? String, "Matthew")
        XCTAssertEqual(body["language"] as? String, "en-US")
        XCTAssertEqual(wizard.active, .callers)
    }

    func testAGreetingTheOwnerWroteIsKept() async {
        let transport = SetupTransport([
            SetupFixture.configRoute: [(200, SetupFixture.config(name: "Ada", greeting: "Hello, Ada here."))],
            SetupFixture.optionsRoute: [(200, SetupFixture.options)],
        ])
        let model = await SetupReceptionistModel(wizard: wizard(transport), workspaces: workspaces(transport))

        await model.load()
        model.name = "Mia"
        model.nameChanged()

        XCTAssertEqual(model.greeting, "Hello, Ada here.")
    }

    /// ⛔ A FAILED CONFIG READ IS A RETRY AND NO FORM.
    func testAFailedPersonaReadOffersARetryNotAForm() async {
        let transport = SetupTransport([
            SetupFixture.configRoute: [(500, "{\"error\":\"Boom\"}")],
            SetupFixture.optionsRoute: [(200, SetupFixture.options)],
        ])
        let model = await SetupReceptionistModel(wizard: wizard(transport), workspaces: workspaces(transport))

        await model.load()
        await model.save()

        guard case .failed = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertTrue(transport.sent(SetupFixture.personaRoute).isEmpty)
    }
}
