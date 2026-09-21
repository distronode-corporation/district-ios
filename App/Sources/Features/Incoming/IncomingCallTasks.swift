import DistrictCall
import Foundation

/// The three background tasks one inbound call owns.
///
/// ⛔ SPLIT OUT OF `IncomingCallModel.swift` BECAUSE OF THE 500-LINE `file_length`
/// CEILING, WHICH `swiftlint --strict` PROMOTES TO AN ERROR, AND THAT IS THE WHOLE
/// REASON. Nothing here is a separate concern from the model. It is the same call
/// `DialerTasks.swift` makes about the outbound model.
///
/// ⚠️ THE PRICE IS SEVEN MEMBERS THAT WOULD OTHERWISE BE `private` AND ARE
/// MODULE-VISIBLE: `calls`, `callUUID`, `engineTask`, `tickTask`, `timeoutTask`,
/// `apply(_:)` and `nowMilliseconds()`. Swift's `private` is file-scoped, so an
/// extension in another file cannot reach one. ⛔ `state` DELIBERATELY DOES NOT
/// WIDEN — its `private(set)`
/// is what stops a view assigning a phase the reducer never produced.
extension IncomingCallModel {
    /// ⛔ THE ENGINE STREAM IS READ EXACTLY ONCE, HERE. `AsyncStream` delivers each
    /// element to a SINGLE consumer, so a second `for await` would silently split
    /// the events between two readers.
    func startEngine() async {
        let events = await calls.beginCall()
        engineTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                await apply(.engine(event))
            }
        }
    }

    /// One second of an answered call.
    ///
    /// ⛔ STARTED AT THE MEDIA, NOT AT THE PRESS, and the operator will compare it
    /// to an invoice. See ``CallMediaState/elapsedSeconds``.
    func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await apply(.tick)
            }
        }
    }

    /// ⛔ THE LOCAL RING BOUND, AND IT IS LONGER THAN THE SERVER'S ON PURPOSE. The
    /// rendezvous expires at ~25s and ``IncomingCallController/ringTimeoutMilliseconds``
    /// waits 30: timing out FIRST would take the Answer button away while the
    /// server was still willing to accept one, which is the one ordering that turns
    /// a slow thumb into a missed call.
    ///
    /// ⚠️ THE REDUCER IS ASKED RATHER THAN TOLD. `ringHasExpired` is false in every
    /// phase but ringing, so a timer that fires after the press cannot tear down a
    /// conversation thirty seconds in even if the cancellation below is missed.
    func armRingTimeout(uuid: UUID) {
        let milliseconds = IncomingCallController.ringTimeoutMilliseconds
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled, let self, callUUID == uuid else { return }
            guard state.ringHasExpired(atMilliseconds: Self.nowMilliseconds()) else { return }
            await apply(.ringTimedOut)
        }
    }
}
