@testable import DistrictAI
import DistrictL10n
import XCTest

/// The account's stored language follows the app's (``LocaleSync``).
@MainActor
final class LocaleSyncTests: XCTestCase {
    private final class Server {
        var received: [L10nLocale] = []
        var accepts = true
    }

    private func sync(_ server: Server) -> LocaleSync {
        LocaleSync { locale in
            server.received.append(locale)
            return server.accepts
        }
    }

    func testASignedInSessionWritesTheResolvedLanguageOnce() async {
        let server = Server()
        let model = sync(server)
        await model.sync(signedIn: true, locale: .frCA)
        await model.sync(signedIn: true, locale: .frCA)
        XCTAssertEqual(server.received, [.frCA])
    }

    func testASignedOutAppWritesNothing() async {
        let server = Server()
        let model = sync(server)
        await model.sync(signedIn: false, locale: .frCA)
        XCTAssertEqual(server.received, [])
    }

    /// ⚠️ A LANGUAGE CHANGE IS WRITTEN, and changing back is written too.
    func testALanguageChangeIsWritten() async {
        let server = Server()
        let model = sync(server)
        await model.sync(signedIn: true, locale: .en)
        await model.sync(signedIn: true, locale: .frCA)
        await model.sync(signedIn: true, locale: .en)
        XCTAssertEqual(server.received, [.en, .frCA, .en])
    }

    /// ⛔ A REFUSED WRITE IS NOT REMEMBERED AS WRITTEN, so the next moment tries again.
    func testARefusedWriteIsTriedAgainAtTheNextMoment() async {
        let server = Server()
        server.accepts = false
        let model = sync(server)
        await model.sync(signedIn: true, locale: .frCA)
        server.accepts = true
        await model.sync(signedIn: true, locale: .frCA)
        await model.sync(signedIn: true, locale: .frCA)
        XCTAssertEqual(server.received, [.frCA, .frCA])
    }

    /// ⚠️ SIGNING OUT FORGETS THE WRITE, so the next account gets its own.
    func testSigningOutForgetsTheWrite() async {
        let server = Server()
        let model = sync(server)
        await model.sync(signedIn: true, locale: .frCA)
        await model.sync(signedIn: false, locale: .frCA)
        await model.sync(signedIn: true, locale: .frCA)
        XCTAssertEqual(server.received, [.frCA, .frCA])
    }

    /// The value the route stores, which is not the language tag (`fr`, never `fr-CA`).
    func testTheStoredValueIsTheRoutesNotTheTag() {
        XCTAssertEqual(L10nLocale.frCA.settingsValue, "fr")
        XCTAssertEqual(L10nLocale.en.settingsValue, "en")
        XCTAssertEqual(L10nLocale.frCA.languageTag, "fr-CA")
    }
}
