import XCTest

/// SPIKE (do not merge): launches the app under several `-AppleLanguages` values and
/// prints what the bundle resolved. Every line starts with `SPIKE|` so the job can grep it.
final class FrenchSpikeTests: XCTestCase {
    private var lines: [String] = []

    private func record(_ line: String) {
        let full = "SPIKE|" + line
        print(full)
        lines.append(full)
    }

    override func tearDown() {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "spike-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        super.tearDown()
    }

    /// Foundation's matching algorithm on its own, for bundle layouts this build does not ship.
    func test_1_matchingMatrix() {
        let layouts: [[String]] = [
            ["fr-CA"],
            ["en", "fr-CA"],
            ["en", "fr"],
            ["en", "fr", "fr-CA"],
            ["fr", "fr-CA"],
        ]
        let preferences: [[String]] = [
            ["fr-FR"], ["fr-BE"], ["fr"], ["fr-CA"], ["en-US"], ["fr-FR", "en-US"], ["de-DE"],
        ]
        for layout in layouts {
            for preference in preferences {
                let chosen = Bundle.preferredLocalizations(from: layout, forPreferences: preference)
                record("matrix|available=\(layout)|prefs=\(preference)|chosen=\(chosen)")
            }
        }
    }

    /// The real app, relaunched once per language.
    func test_2_launches() {
        let ids = [
            "spike.preferred",
            "spike.preferredAll",
            "spike.localizations",
            "spike.developmentLocalization",
            "spike.preferredLanguages",
            "spike.pushMessageTitle",
            "spike.pushCallBody",
            "spike.pushGenericBody",
            "spike.mic",
            "spike.deskSubtitle",
        ]
        for language in ["fr-FR", "fr-BE", "fr", "fr-CA", "en-US"] {
            let app = XCUIApplication()
            app.launchArguments = ["-FrenchSpikeProbe", "-AppleLanguages", "(\(language))"]
            app.launch()
            guard app.staticTexts["spike.preferred"].waitForExistence(timeout: 60) else {
                record("launch|AppleLanguages=(\(language))|probe did not appear")
                XCTFail("probe did not appear for \(language)")
                app.terminate()
                continue
            }
            for id in ids {
                let element = app.staticTexts[id]
                let value = element.exists ? element.label : "(missing)"
                record("launch|AppleLanguages=(\(language))|\(id)=\(value)")
            }
            app.terminate()
        }
    }
}
