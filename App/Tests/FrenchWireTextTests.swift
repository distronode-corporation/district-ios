@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import Foundation
import XCTest

/// What the W4 French pass changed: a French screen shows the vocabulary's labels, the
/// core's dates and numbers, never an English wire word or an ISO instant. Since 3.0.1 an
/// English screen shows the vocabulary's English label for every value it lists.
final class FrenchWireTextTests: XCTestCase {
    private static let nbsp = "\u{00A0}"

    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    // MARK: - Wire labels

    /// ⛔ 3.0.1: ENGLISH IS THE VOCABULARY'S LABEL TOO. The Overview showed `completed` beside
    /// "Transferred" while English drew the value as sent.
    func testBothLanguagesShowTheVocabularysLabelNeverTheWireValue() {
        XCTAssertEqual(AppWire.label(.callStatus, "completed"), "Completed")
        XCTAssertEqual(AppWire.label(.messageDeliveryStatus, "delivered"), "Delivered")
        XCTAssertEqual(AppWire.label(.numberStatus, "active"), "Active")
        XCTAssertEqual(french { AppWire.label(.callStatus, "completed") }, "Terminé")
        XCTAssertEqual(french { AppWire.label(.messageDeliveryStatus, "delivered") }, "Livré")
        XCTAssertEqual(french { AppWire.label(.numberStatus, "active") }, "Actif")
        // DistrictCore 7.0.2: Twilio's `in-use` is labelled as an active line.
        XCTAssertEqual(french { AppWire.label(.numberStatus, "in-use") }, "Actif")
    }

    /// ⛔ AN UNLISTED VALUE IS NEVER SHOWN AS ITSELF IN FRENCH: it takes the category's
    /// fallback, or « Autre ». English keeps it as sent (`WireLabel.knownLabel` is nil).
    func testAnUnlistedValueReadsAsTheFallbackInFrench() {
        XCTAssertEqual(AppWire.label(.callStatus, "machine"), "machine")
        XCTAssertEqual(french { AppWire.label(.callStatus, "machine") }, "Autre")
    }

    /// ⚠️ A BLANK VALUE STAYS ABSENT, so a card's own blank guard still hides it.
    func testAnAbsentOrBlankValueHasNoLabel() {
        XCTAssertNil(french { AppWire.label(.sentiment, ifAny: nil) })
        XCTAssertNil(french { AppWire.label(.sentiment, ifAny: "  ") })
        XCTAssertEqual(AppWire.label(.sentiment, ifAny: "positive"), "Positive")
    }

    func testACallLengthIsTheServersInEnglishAndWrittenFromTheSecondsInFrench() {
        XCTAssertEqual(AppWire.duration(sent: "1m 5s", seconds: 65), "1m 5s")
        XCTAssertEqual(
            french { AppWire.duration(sent: "1m 5s", seconds: 65) },
            "1\(Self.nbsp)min\(Self.nbsp)5\(Self.nbsp)s",
            "3.0.2: no plain space, so « 3 min » never wraps away from « 4 s »"
        )
    }

    func testACountIsPlainInEnglishAndGroupedInFrench() {
        XCTAssertEqual(AppWire.count(1204), "1204")
        XCTAssertEqual(french { AppWire.count(1204) }, "1\(Self.nbsp)204")
    }

    /// ⚠️ ONLY THE SERVICE'S OWN PLACEHOLDERS ARE TRANSLATED; a real name is data.
    func testAPlaceholderAuthorIsTranslatedAndARealNameIsNot() {
        XCTAssertEqual(AppWire.placeholder("You"), "You")
        XCTAssertEqual(french { AppWire.placeholder("You") }, "Vous")
        XCTAssertEqual(french { AppWire.placeholder("Distronode Support") }, "Soutien Distronode")
        XCTAssertEqual(french { AppWire.placeholder("Dana Booker") }, "Dana Booker")
    }

    /// ⛔ 3.0.2: A FRENCH DOSSIER HEADS A KEY THE VOCABULARY LISTS IN THE PORTAL'S WORDS, not
    /// the key humanized into English (« Core pain points »). English, and a key the
    /// vocabulary does not list, keep the humanized key.
    func testAFrenchDossierKeyReadsAsTheVocabularysLabel() {
        XCTAssertEqual(french { dossierLabel("corePainPoints") }, "Enjeux CRM déduits")
        XCTAssertEqual(french { dossierLabel("executiveSummary") }, "Résumé du dossier")
        // DistrictCore 7.0.2: the three keys the portal heads but the vocabulary did not list.
        XCTAssertEqual(french { dossierLabel("estimatedValue") }, "Évaluation DGI")
        XCTAssertEqual(french { dossierLabel("person") }, "Profil du contact")
        XCTAssertEqual(french { dossierLabel("callerIntel") }, "Renseignements sur l'appelant")
        XCTAssertEqual(dossierLabel("corePainPoints"), "Core pain points")
        XCTAssertEqual(french { dossierLabel("budget_notes") }, "Budget notes")
        XCTAssertEqual(
            french { dossierFields(.object(["corePainPoints": .string("Slow quotes")])).first?.label },
            "Enjeux CRM déduits"
        )
    }

    // MARK: - Workflows

    /// ⛔ FRENCH SHOWS THE CODE'S LABEL AND NEVER THE ENGLISH DETAIL after the colon.
    func testAnActionReasonIsTheSentenceInEnglishAndTheCodesLabelInFrench() {
        XCTAssertEqual(
            WorkflowActionReason.label("dnc: +14165550100 is on the list"),
            "dnc: +14165550100 is on the list"
        )
        XCTAssertEqual(french { WorkflowActionReason.label("dnc: +14165550100 is on the list") }, "Liste d'exclusion")
        XCTAssertEqual(french { WorkflowActionReason.label("http-503: upstream down") }, "HTTP 503")
        XCTAssertEqual(french { WorkflowActionReason.label("something-new") }, "Autre")
    }

    /// 3.0.3 (DistrictCore 7.0.3): the team push codes read as their sentence in French,
    /// where they fell back to « Autre ». English still shows the sentence as sent.
    func testTheTeamPushReasonsHaveTheirOwnFrenchSentence() {
        XCTAssertEqual(
            french { WorkflowActionReason.label("no-devices: 0 of 3 members") },
            "Aucun membre de l'équipe n'a l'application sur un appareil qui peut recevoir des notifications"
        )
        XCTAssertEqual(
            french { WorkflowActionReason.label("push-not-delivered: apns 410") },
            "Aucun appareil n'a accepté la notification"
        )
        for code in ["no-message", "push-lookup-failed", "signing-unavailable"] {
            XCTAssertNotEqual(french { WorkflowActionReason.label("\(code): detail") }, "Autre", code)
        }
        XCTAssertEqual(WorkflowActionReason.label("no-devices: 0 of 3 members"), "no-devices: 0 of 3 members")
    }

    // MARK: - Devices

    func testADevicePlatformIsTheProductName() {
        XCTAssertEqual(DevicePlatformName.of("ios"), "iOS")
        XCTAssertEqual(DevicePlatformName.of(" android "), "Android")
        XCTAssertEqual(DevicePlatformName.of("tizen"), "tizen")
        XCTAssertEqual(DevicePlatformName.of(" "), DevicesCopy.unknownPlatform)
    }

    // MARK: - Dates and numbers

    /// ⛔ THE CORE'S FRENCH, WHATEVER FRENCH THE DEVICE SPEAKS: « 12 sept. 2026, 10 h 30 ».
    func testAnInstantIsWrittenByTheCoreInFrench() {
        let toronto = TimeZone(identifier: "America/Toronto")
        XCTAssertEqual(
            french { WireDate.display("2026-09-12T14:30:00Z", in: toronto) },
            "12 sept. 2026, 10 h 30"
        )
        XCTAssertEqual(french { WireDate.display("soon") }, "soon")
    }

    func testAMeteredAmountUsesFrenchSeparators() {
        XCTAssertEqual(AnalyticsFormat.amount(1204.25), "1204.25")
        XCTAssertEqual(french { AnalyticsFormat.amount(1204.25) }, "1\(Self.nbsp)204,25")
        XCTAssertEqual(french { AnalyticsFormat.amount(318.5) }, "318,5")
        XCTAssertEqual(french { AnalyticsFormat.amount(412) }, "412")
    }

    /// ⛔ WHOLE MINUTES DROP THE SECONDS IN FRENCH (format-vectors.json, formatMinutesSeconds).
    func testAnAverageDurationIsTheCoresInFrench() {
        XCTAssertEqual(AnalyticsFormat.duration(seconds: 120), "2m 0s")
        XCTAssertEqual(french { AnalyticsFormat.duration(seconds: 120) }, "2\(Self.nbsp)min")
        XCTAssertEqual(french { AnalyticsFormat.duration(seconds: 3600) }, "60\(Self.nbsp)min")
        XCTAssertEqual(french { AnalyticsFormat.duration(seconds: 65) }, "1\(Self.nbsp)min\(Self.nbsp)5\(Self.nbsp)s")
    }

    func testTheIncludedMinutesAreGroupedInFrench() {
        let amount = french { AnalyticsFormat.amount(1522.75) }
        XCTAssertEqual(
            french { BillingCopy.meterUsedOf(amount, included: AppWire.count(1500)) },
            "Minutes utilisées\(Self.nbsp): 1\(Self.nbsp)522,75 sur 1\(Self.nbsp)500 incluses"
        )
        XCTAssertEqual(
            BillingCopy.meterUsedOf(AnalyticsFormat.amount(1522.75), included: AppWire.count(1500)),
            "1522.75 of 1500 included minutes used"
        )
    }

    // MARK: - Billing money

    /// ⛔ ENGLISH IS BYTE-IDENTICAL TO WHAT THE BILLING SCREEN SHOWED BEFORE THE "$" LEFT THE
    /// CATALOG: each line below is the old English, glyph and all, for the same cents.
    func testEnglishBillingLinesAreUnchangedWithTheDollarOutOfTheCatalog() {
        let price = { (cents: Int, currency: String?) in BillingMoneyFormat.price(cents: cents, currency: currency) }
        XCTAssertEqual(BillingCopy.money(price(24900, "cad")), "$249.00")
        XCTAssertEqual(BillingCopy.money(price(-1500, nil)), "$-15.00")
        XCTAssertEqual(BillingCopy.money(price(120_425, "usd")), "$1204.25")
        XCTAssertEqual(BillingCopy.moneyMonthly(price(24900, "cad")), "$249.00 / month")
        XCTAssertEqual(BillingCopy.invoiceTax(price(3237, "cad")), "incl. $32.37 tax")
        XCTAssertEqual(BillingCopy.discountAmount("Founding", amount: price(500, "cad")), "Founding, $5.00 off")
        XCTAssertEqual(
            BillingCopy.spendCapSet(price(5000, nil)),
            "Overage beyond your plan is capped at $50.00 a month."
        )
    }

    /// French names the currency Stripe sends (« $ CA », « $ US ») and a bare « $ » without one.
    func testFrenchBillingLinesNameTheCurrency() {
        let price = { (cents: Int, currency: String?) in BillingMoneyFormat.price(cents: cents, currency: currency) }
        let nbsp = Self.nbsp
        XCTAssertEqual(french { BillingCopy.money(price(24900, "cad")) }, "249,00\(nbsp)$\(nbsp)CA")
        XCTAssertEqual(french { BillingCopy.moneyMonthly(price(24900, "usd")) }, "249,00\(nbsp)$\(nbsp)US / mois")
        XCTAssertEqual(
            french { BillingCopy.spendCapSet(price(5000, nil)) },
            "Les frais de dépassement de votre forfait sont plafonnés à 50,00\(nbsp)$ par mois."
        )
    }

    func testAMonthIsAsSentInEnglishAndWrittenOutInFrench() {
        XCTAssertEqual(AnalyticsFormat.sentMonth("2026-08"), "2026-08")
        XCTAssertEqual(french { AnalyticsFormat.sentMonth("2026-08") }, "août 2026")
        XCTAssertEqual(french { AnalyticsFormat.sentMonth("soon") }, "soon")
    }

    func testATrendBucketIsTheServersDayInEnglishAndTheIsoDayInFrench() throws {
        let json = #"{"date":"Aug 1","isoDate":"2026-08-01","calls":3,"avgDuration":60}"#
        let point = try JSONDecoder().decode(EngagementPoint.self, from: Data(json.utf8))
        XCTAssertEqual(AnalyticsFormat.bucketLabel(point), "Aug 1")
        XCTAssertEqual(french { AnalyticsFormat.bucketLabel(point) }, "1er août 2026")
    }

    // MARK: - Messaging

    func testAMessagingCarrierIsCapitalisedInEnglishAndNamedInFrench() {
        XCTAssertEqual(MessagingCatalog.providerLabel("twilio"), "Twilio")
        XCTAssertEqual(MessagingCatalog.providerLabel("unknown"), "Unknown")
        XCTAssertEqual(french { MessagingCatalog.providerLabel("twilio") }, "Twilio")
        XCTAssertEqual(french { MessagingCatalog.providerLabel("unknown") }, "Autre")
    }

    // MARK: - Inbox channels

    /// ⛔ 3.0.2 WALK 2: EVERY CHANNEL THE SERVER WRITES HAS A NAME OF ITS OWN. A row's
    /// channels are its messages' `type`: `sms`, `email`, `whatsapp`, and the `voicemail`
    /// the voice agent writes for a message left on a call. Voicemail fell through to the
    /// raw wire word, so a French Inbox drew « VOICEMAIL » (the Mac's #67, ported).
    func testEveryWireChannelHasItsOwnName() {
        let englishNames = ["sms": "SMS", "email": "Email", "whatsapp": "WhatsApp", "voicemail": "Voicemail"]
        let frenchNames = ["sms": "SMS", "email": "Courriel", "whatsapp": "WhatsApp", "voicemail": "Boîte vocale"]
        for (channel, name) in englishNames {
            XCTAssertEqual(ThreadChannelName.of(channel), name, channel)
        }
        for (channel, name) in frenchNames {
            XCTAssertEqual(french { ThreadChannelName.of(channel) }, name, channel)
        }
        XCTAssertEqual(ThreadChannelName.voicemail, "voicemail", "the wire value")
    }

    /// The chips on a mixed-channel Inbox row: English keeps the wire word in capitals,
    /// French names each channel, voicemail included.
    func testAMixedInboxRowNamesItsVoicemailChannel() throws {
        let body = #"""
        {"key":"k","threadKey":"contact:x","counterpart":"+15550101","matchKeys":["15550101"],
         "kind":"phone","channels":["sms","voicemail"],"contactId":"x","contactName":"Casey",
         "contactEmail":null,"contactPhone":"+15550101","canSms":true,"canEmail":false,
         "lastMessage":{"body":"Call me back","direction":"inbound","type":"voicemail",
         "status":"received","createdAt":"2026-10-16T14:00:00.000Z"},"unreadCount":1,"totalMessages":2}
        """#
        let conversation = try JSONDecoder().decode(ConversationSummary.self, from: Data(body.utf8))
        XCTAssertEqual(ConversationDisplay(conversation).channelLabels, ["SMS", "VOICEMAIL"])
        XCTAssertEqual(french { ConversationDisplay(conversation).channelLabels }, ["SMS", "BOÎTE VOCALE"])
    }
}
