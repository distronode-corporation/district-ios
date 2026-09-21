import DistrictModel

/// The dialer's call-back list: the workspace's recent INBOUND callers.
///
/// ⛔ ITS OWN STATE, READ AND FAILING INDEPENDENTLY OF THE KEYPAD, which is the
/// property Android states explicitly on `DialerUiState.callbacks`. The call log
/// and `POST /api/district/calls/dial` are unrelated server surfaces, so an outage
/// of the first must never present as an inability to place a call. Nothing in
/// ``DialerModel/canPlaceCall`` mentions this type, and that absence is the
/// enforcement.
///
/// ⚠️ `ready([])` IS A LEGITIMATE ANSWER ON A HEALTHY WORKSPACE. Nobody has called
/// in, or the newest twenty rows of the log were all outbound. It renders as an
/// explanatory empty state and must never read as a failure, because "we could not
/// look" and "there is nothing" are different answers.
///
/// ⚠️ THE ROWS ARRIVE UNDEDUPLICATED. One person who called three times is three
/// rows, each with its own time; ``CallsRepository/recentCallbacks(workspaceId:limit:)``
/// says so, and collapsing them would be a display decision to make and comment
/// here rather than something the data already did.
enum DialerCallbacksState {
    case loading
    case ready([CallSummary])
    case failed(FailureText)
}
