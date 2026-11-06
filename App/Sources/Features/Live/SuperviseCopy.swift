import DistrictCall
import DistrictL10n
import DistrictModel

/// The Live calls screen's words, and the few decisions about which one to say.
///
/// ⛔ THE WEBSITE'S SENTENCES, WORD FOR WORD, AND SEAN'S SEVEN FOR THE APPS. Every member the
/// generated file adds comes from the Live page's `liveI18n.ts` in both languages, or from
/// the approved list (2026-11-05); the catalog note on each one says which. The four drafts
/// are this app's own (a busy device, a system call that never started, the quoted first
/// words) and say so in their notes.
///
/// ⛔ A REFUSAL IS SAID BY ITS CODE, NEVER BY THE SERVER'S ENGLISH. `call_ended`,
/// `call_has_no_receptionist`, `call_not_in_progress` and the rest have their sentences in
/// the core's `ApiErrorTable` in both languages, which is the table the website reads too;
/// a code this build does not know gets the action's own fallback, as on the website.
enum SuperviseCopy {
    /// The longest note the whisper route takes, in UTF-16 units (it counts JavaScript string
    /// length). The watch relay applies the same limit.
    static let whisperLimit = WatchLiveComposer.whisperLimit

    /// The sentence for a refused or failed request, or `fallback` when no code says more.
    static func refusal(_ error: ApiError, fallback: String) -> String {
        switch error {
        case .http:
            if let code = error.code, let sentence = ApiErrorText.sentence(for: code) {
                return sentence
            }
            return fallback
        case .transport:
            // ⚠️ THE CONNECTION, NOT THE CALL: "could not connect you to the call" would blame
            // the call for the phone being offline.
            return SessionCopy.appearOfflineCheckConnection
        case .decoding:
            return fallback
        }
    }

    /// The line beside the control that last went wrong, or nil.
    ///
    /// ⚠️ A DROPPED LISTEN ROOM SAYS THE CONNECT SENTENCE: the person is out of the call and
    /// Listen is offered again, which is the website's state after its room drops.
    static func problem(_ problem: SuperviseProblem?) -> String? {
        switch problem {
        case .none:
            nil
        case let .listenRefused(error):
            refusal(error, fallback: monitorConnectFailed)
        case .listenFailed, .listenDropped:
            monitorConnectFailed
        case let .takeoverRefused(error):
            refusal(error, fallback: takeoverFailed)
        case .takeoverJoinFailed, .takeoverDropped:
            takeOverJoinFailed
        }
    }

    /// The receipt for the latest note: whether it was used, then the words or the reason.
    ///
    /// ⛔ `reason` IS WIRE VOCABULARY AND IS NEVER SHOWN RAW. As on the website, `taken_over`
    /// has its sentence and every other reason (including one this build does not know) is
    /// the transfer's.
    ///
    /// ⚠️ THE FIRST WORDS ARE CUSTOMER SPEECH, quoted as said and never translated.
    static func receipt(_ receipt: WhisperReceipt) -> (headline: String, detail: String?) {
        if receipt.applied {
            let words = receipt.firstWords.trimmingCharacters(in: .whitespacesAndNewlines)
            return (whisperApplied, words.isEmpty ? nil : whisperFirstWords(words))
        }
        let sentence = receipt.reason?.isTakenOver == true ? whisperNotUsedTakenOver : whisperNotUsedTransfer
        return (whisperNotApplied, reasonOnly(sentence))
    }

    /// The website's "not used" sentences open with "Not used: " / « Consigne non utilisée : »,
    /// which repeats the approved line above them (Sean, 2026-11-05: "Approved line + reason
    /// only").
    ///
    /// ⛔ THE REASON COMES FROM THE AGENT'S CODE (`transfer`, `taken_over`), NEVER FROM FREE TEXT;
    /// this only trims the catalog's own sentence for that code, so the website's words stay the
    /// one source. ⚠️ EXACTLY THESE TWO PREFIXES, and a sentence without one is returned as it
    /// was. What remains starts with a capital.
    static let notUsedPrefixes = ["Not used: ", "Consigne non utilisée\u{00A0}: "]

    static func reasonOnly(_ sentence: String) -> String {
        guard let prefix = notUsedPrefixes.first(where: sentence.hasPrefix) else { return sentence }
        let rest = sentence.dropFirst(prefix.count)
        guard let first = rest.first else { return sentence }
        return first.uppercased() + rest.dropFirst()
    }
}
