import DistrictModel

// The two states the messaging screen holds that are not save states.
//
// ⚠️ THEIR OWN FILE RATHER THAN THE TOP OF `MessagingModel.swift`, AND IT IS A LINT
// CEILING RATHER THAN A SPLIT WITH MEANING, the same call `SettingsCopy` and `HQCopy`
// record: `swiftlint --strict` promotes the `file_length` warning at 500 lines to an
// error, and the model would go past it. The division follows `SettingsConfigState.swift`,
// which holds that surface's state enums away from the models that drive them.

/// The messaging read's own load state.
///
/// ⚠️ SEPARATE FROM ``SettingsConfigState``, the same call ``KnowledgeListState``
/// makes: this is a different read with a different payload, and reusing the config
/// state would imply this screen hydrates from `workspace/config`, which excludes a
/// viewer — the opposite of this route.
enum MessagingLoadState {
    case loading
    /// ⚠️ An empty `accounts` list is a real answer: a workspace with no carrier
    /// connected.
    case ready(MessagingResponse)
    case failed(FailureText)
}

/// The credential probe's state.
///
/// ⛔ `rejected` AND `unreachable` ARE SEPARATE CASES BECAUSE THEY ARE DIFFERENT
/// ANSWERS. "The carrier says these keys are wrong" is about what was typed; "we could
/// not ask" is about the network. Rendering the second as the first tells someone their
/// working credentials are broken, on the one screen where believing that leads to
/// retyping a live carrier secret.
///
/// ⛔ AND NONE OF THESE CASES IS A RECORD OF WHICH FORM WAS ASKED ABOUT, which is why
/// ``MessagingModel/probeGeneration`` exists beside them rather than a sixth case here.
/// A probe result is only ever meaningful against the draft that was on screen when it
/// was requested, and that is a fact about the MODEL's history rather than about the
/// answer the carrier gave.
enum MessagingProbeState {
    case idle
    case running
    /// - Parameter detail: an account name from Twilio, or a bare confirmation from the
    ///   other two. Nil is a pass that said nothing, which is still a pass.
    case passed(String?)
    /// ⚠️ Arrived as an HTTP **200** with `success:false`. The server's own sentence.
    case rejected(String)
    /// ⛔ Says nothing about the credentials. Includes the 10/min rate limit.
    case unreachable(FailureText)
}
