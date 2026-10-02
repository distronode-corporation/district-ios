import DistrictCall

/// Everything about the number in the field: what it discloses, and whether the
/// Call button may light up.
///
/// ⛔ IT EXISTS BECAUSE A CALL CAN REACH THE WRONG COUNTRY AND BE BILLED FOR IT.
/// A Canadian mobile typed as `+4165550123` instead of `+14165550123` dials `+41`,
/// which is SWITZERLAND. A digit COUNT alone passes it (ten digits), and no layer
/// on either side of the wire has an opinion about the country code: the server's
/// phone normaliser strips punctuation and stops.
///
/// ⛔ AND IT DOES NOT FIX THAT BY REWRITING THE NUMBER. See property 3 on
/// ``DialerModel`` and the matching note in the Android client's dial formatter: the server
/// normalises its own copy and runs Do-Not-Call, the Contact lookup and the dial
/// against THAT form, so a client that silently prepended `+1` would ship a
/// second opinion whose disagreements are invisible until a call reaches a
/// number the compliance screen never saw. That is a worse bug than a wrong country.
/// What this adds is DISCLOSURE plus one unambiguous refusal.
///
/// ⚠️ ITS OWN FILE, LIKE ``DialerCopy``, AND FOR THE SAME REASON: `swiftlint
/// --strict` promotes the `file_length` warning at 500 lines to an error, and
/// `DialerModel.swift` is near it with the call machinery alone.
extension DialerModel {
    /// Where the entry says the call will ring, and whether it may be placed.
    ///
    /// ⚠️ DERIVED ON READ RATHER THAN STORED. It is a pure function of ``entry``,
    /// and a cached copy would be one more thing ``onEntryChange(_:)`` has to
    /// remember to update.
    var destination: DialEntryAssessment {
        DialEntry.assess(entry)
    }

    /// ⛔ TWO GATES, AND THE DIGIT FLOOR IS STILL ONE OF THEM.
    ///
    /// The floor mirrors the server's own: `POST /api/district/calls/dial`
    /// rejects anything shorter than 8 characters AFTER normalising, so a client
    /// counting the raw string would enable the button for "(416) 5" — thirteen
    /// characters, five digits — and the operator would meet a 400 that reads as
    /// a server fault. The floor and the digit test are DistrictCore's
    /// (``DialEntry/minimumDigits``, ``DialEntry/isDigit(_:)``), so the button and
    /// the refusal sentence count the same characters against the same number.
    ///
    /// ``DialEntry/assess(_:)`` is the addition, and it refuses only what cannot
    /// be E.164 at all — chiefly an entry with no `+`, which names no country and
    /// so cannot be checked against one. ⚠️ A well-formed number for the WRONG
    /// country still dials; the country line beside the field is what catches
    /// that, because the client is not entitled to an opinion about which
    /// countries an operator may ring.
    ///
    /// ⚠️ THE FLOOR IS REDUNDANT AGAINST THE E.164 CHECK TODAY and is kept
    /// anyway: it is the one that mirrors the route, so if the route's floor
    /// moves this is the line that moves with it.
    var canPlaceCall: Bool {
        guard canDial, call == nil, !placing else { return false }
        guard entry.filter(DialEntry.isDigit).count >= DialEntry.minimumDigits else { return false }
        return destination.isDialable
    }

    /// A call-back row was tapped.
    ///
    /// ⛔ IT FILLS THE FIELD AND DOES NOT DIAL. One tap must never place a call,
    /// least of all from a list where a mis-scroll lands on a row; the operator
    /// still presses Call, which is property 1 on ``DialerModel``.
    ///
    /// ⚠️ THE ROW'S NUMBER IS THE SERVER'S OWN AND IS ALREADY E.164, so it lands
    /// dialable — `DialNumberTests` asserts that against the committed
    /// `district-calls.json` fixture rather than against a number typed here.
    ///
    /// ⛔ A WITHHELD CALLER NEVER REACHES THIS. Its placeholder is the literal
    /// sentence `"Inbound SIP Caller"`, so letting the row through would type those
    /// three words into the keypad beside a dead Call button — an offer of a
    /// call-back to somebody who left no number. ``CallsRepository`` drops the row
    /// (see ``CallerIdentity``), so the list never offers it. The gates above stay
    /// as the second line of defence, not as the answer.
    func callBack(_ number: String) {
        onEntryChange(number)
    }
}
