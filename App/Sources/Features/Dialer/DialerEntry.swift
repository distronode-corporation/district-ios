import DistrictCall
import DistrictData

/// The country the dialler reads the field in, and where that country comes from.
///
/// ⚠️ ONE STORED VALUE ON ``DialerModel`` RATHER THAN FOUR, because `DialerModel.swift` sits
/// at the 500-line `file_length` ceiling `swiftlint --strict` enforces.
///
/// ⛔ THE HOME COUNTRY IS THE WORKSPACE'S OWN NUMBERS' COUNTRY, read from
/// `GET /api/district/workspace/provider/numbers`, which the app already decodes and every
/// role may read. No response field was added for it: a new field breaks the mobile
/// contracts. A workspace with no numbers has no home country, and the operator picks one
/// (remembered per workspace, ``DialerCountryMemory``) or types `+`.
struct DialerCountries {
    /// The country on the button, or nil until one is picked or a `+` names one.
    var current: String?
    /// The workspace's own country, or nil.
    var home: String?
    var memory: DialerCountryMemory
    let numbers: NumbersRepository?
    let workspaceId: String

    init(
        workspaceId: String,
        numbers: NumbersRepository?,
        memory: DialerCountryMemory = UserDefaultsDialerCountryMemory()
    ) {
        self.workspaceId = workspaceId
        self.numbers = numbers
        self.memory = memory
        home = memory.home(workspaceId: workspaceId)
        current = home ?? memory.picked(workspaceId: workspaceId)
    }
}

/// Everything about the number in the field: what it discloses, and whether the
/// Call button may light up.
///
/// ⛔ IT EXISTS BECAUSE A CALL CAN REACH THE WRONG COUNTRY AND BE BILLED FOR IT.
/// A Canadian mobile typed as `+4165550123` instead of `+14165550123` dials `+41`,
/// which is SWITZERLAND. Dialler design A answers it by putting the country in front of
/// the number: a flag and calling code the operator can see and change, a field that
/// takes the number the local way, and a line under it naming the country and the whole
/// international number before Call. A pasted `+41…` moves the flag to Switzerland.
///
/// ⛔ WHAT IS SENT IS THE E.164 NUMBER THAT LINE SHOWED (``DialPlan/Reading/e164``), not
/// the text in the field. The server normalises its own copy before Do-Not-Call and the
/// dial, and an E.164 number passes through it unchanged, so the compliance check sees
/// the number the operator was shown.
///
/// ⚠️ ITS OWN FILE, LIKE ``DialerCopy``, AND FOR THE SAME REASON: `swiftlint
/// --strict` promotes the `file_length` warning at 500 lines to an error, and
/// `DialerModel.swift` is at it with the call machinery alone.
extension DialerModel {
    /// The field, read in the country on the button.
    ///
    /// ⚠️ DERIVED ON READ RATHER THAN STORED. It is a pure function of ``entry`` and the
    /// country, and a cached copy would be one more thing to keep in step.
    var destination: DialPlan.Reading {
        DialPlan.read(entry, country: countries.current)
    }

    /// ⛔ ONE GATE: A COMPLETE NUMBER IN A KNOWN SHAPE. ``DialPlan`` sets
    /// ``DialPlan/Reading/e164`` only for a number with at least
    /// ``DialEntry/minimumDigits`` digits, the route's own floor after normalising, so the
    /// button cannot light for a number the server would answer with a 400.
    var canPlaceCall: Bool {
        guard canDial, call == nil, !placing else { return false }
        return destination.e164 != nil
    }

    /// What the field becomes for `value`, moving the button's country when the number
    /// names its own.
    ///
    /// ⛔ A `+` (OR `011`, `00`) NUMBER SWITCHES THE FLAG and the field drops to the local
    /// form, so the flag always says where the digits in the field ring. A +1 number
    /// flips between Canada and the United States by its area code.
    func absorb(_ value: String) -> String {
        let reading = DialPlan.read(value, country: countries.current)
        if let iso = reading.iso {
            countries.current = iso
        }
        return reading.national
    }

    /// The operator stopped typing: the field lost focus, or Return or Done was pressed, or a
    /// Call was refused. A number of a length its country never issues is said from now until
    /// the next edit (``onEntryChange(_:)`` clears it). See ``entryProblem(_:lengthChecked:)``.
    func checkLength() {
        lengthChecked = true
    }

    /// The operator chose a country in the list.
    ///
    /// ⚠️ THE DIGITS ALREADY TYPED ARE KEPT and read again in the new country. On a
    /// workspace with no home country the pick is remembered, so it is made once.
    func pickCountry(_ iso: String) {
        countries.current = iso
        if countries.home == nil {
            countries.memory.rememberPicked(iso, workspaceId: workspaceId)
        }
        onEntryChange(entry.filter(DialEntry.isDigit))
    }

    /// Learn the workspace's country from its numbers.
    ///
    /// ⚠️ A FAILED READ CHANGES NOTHING: the cached country, a remembered pick or none stays,
    /// and the keypad works either way. ⚠️ THE BUTTON MOVES ONLY IF THE OPERATOR HAS NOT
    /// STARTED: an empty field still showing the country it opened on.
    func loadHomeCountry() async {
        guard let numbers = countries.numbers else { return }
        // ⛔ READ BEFORE THE AWAIT. A country picked while the read is in flight is remembered,
        // and read afterwards it would look like the country the keypad opened on, so the
        // answer would overwrite the operator's own pick.
        let openedOn = countries.current
        guard case let .success(response) = await numbers.owned(workspaceId: workspaceId) else { return }
        guard let home = Self.homeCountry(fromNumbers: response.numbers.map(\.phoneNumber)) else { return }
        adoptHomeCountry(home, openedOn: openedOn)
    }

    /// Record the workspace's country, and move the button to it only if nothing has moved
    /// it since the keypad opened on `openedOn` and the field is still empty.
    func adoptHomeCountry(_ home: String, openedOn: String?) {
        countries.memory.rememberHome(home, workspaceId: workspaceId)
        countries.home = home
        if entry.isEmpty, countries.current == openedOn {
            countries.current = home
        }
    }

    /// The country most of the workspace's numbers belong to; on a tie, the first listed.
    /// nil when none of them reads as a known country.
    nonisolated static func homeCountry(fromNumbers numbers: [String]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for number in numbers {
            let reading = DialPlan.read(number, country: nil)
            // ⚠️ A TOLL-FREE +1 NUMBER IS NOT EVIDENCE OF ANY COUNTRY (Seer on PR #95): a Canadian
            // workspace with only 1-800 numbers would otherwise read as American.
            guard let iso = reading.iso,
                  !(reading.callingCode == "1" && DialPlan.isNANPTollFree(reading.nationalNumber)) else { continue }
            if counts[iso] == nil {
                order.append(iso)
            }
            counts[iso, default: 0] += 1
        }
        return order.max { lhs, rhs in
            counts[lhs, default: 0] < counts[rhs, default: 0]
        }
    }

    /// A call-back row was tapped.
    ///
    /// ⛔ IT FILLS THE FIELD AND DOES NOT DIAL. One tap must never place a call,
    /// least of all from a list where a mis-scroll lands on a row; the operator
    /// still presses Call, which is property 1 on ``DialerModel``.
    ///
    /// ⚠️ THE ROW'S NUMBER IS THE SERVER'S OWN AND IS ALREADY E.164, so it moves the
    /// flag to its country and lands in the field in that country's local form.
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
