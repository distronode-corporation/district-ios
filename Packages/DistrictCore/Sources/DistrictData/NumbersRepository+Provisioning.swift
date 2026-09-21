import DistrictModel
import DistrictNetwork
import Foundation

/// Whether sending one of the number writes a second time is the same write a second
/// time.
///
/// ⛔ A PROPERTY OF THE CALL, DECLARED AT THE CALL SITE, because only the caller knows
/// which call it is making. Each method below states its answer in its own doc comment
/// and it is copied to the call site rather than guessed.
///
/// ⚠️ IT IS NOT "IS THIS SCARY". Uploading a document sounds consequential and is
/// ``idempotent`` — the route replaces the row for that requirement rather than adding a
/// second one. Releasing a number sounds like tidying up and is ``once``.
public enum NumberWriteRepeat: Sendable {
    /// Safe to send again: the server converges on the same state.
    case idempotent

    /// ⛔ A REPEAT COSTS SOMETHING THAT CANNOT BE TAKEN BACK. A release cannot happen
    /// twice but its 403-on-retry hides whether the first one worked; a submit files a
    /// regulated application; an A2P registration pays a carrier brand fee; a toll-free
    /// verification enters a manual review queue and churns a live number's routing
    /// state; a Verify enable mints a billable OTP sender that outlives our pointer to
    /// it; a lookup is billed by the carrier per call.
    case once
}

/// Whether a failed write may be sent again from the control it failed in.
///
/// ⛔ THE CONSERVATIVE RULE: A REPEAT IS OFFERED ONLY WHEN THE FAILURE **PROVES** THE
/// WRITE DID NOT HAPPEN, never when it merely might not have. The three ``ApiError``
/// cases are not equally informative and that asymmetry is the whole decision:
///
///   - `.http` in 400...499 is the server having REFUSED before it did any work — the
///     role guard, the ownership check against the hub index, the rate limiter, a
///     missing row, a malformed body. Nothing was spent. A repeat is honest.
///   - `.http` at 500 and above is the server having THROWN, which on this family it
///     can do after the carrier call has already landed. Ambiguous.
///   - `.transport` is no answer at all, which is the lost-response case. Ambiguous.
///   - `.decoding` is NOT ambiguous and is the one that reads as harmless. It is only
///     ever produced from a **2xx** — `ApiErrorNormalizer` guards on `isSuccess` — so
///     the server answered success and the write DID happen. A repeat spends it again,
///     guaranteed rather than possibly.
///
/// ⚠️ THE 4xx BRANCH IS SAFE HERE FOR A REASON WORTH STATING, BECAUSE IT IS NOT SAFE
/// EVERYWHERE. On `numbers/release` a **403** after a successful release is the
/// EXPECTED answer — the ownership row the guard needs has just been deleted — so a
/// re-armed control that is pressed again gets the same 403 and spends nothing. What
/// makes that acceptable is that the second failure is also free; it is emphatically
/// not evidence that the first attempt failed, and a screen must not word it that way.
///
/// ⚠️ THIS IS THE SECOND STATEMENT OF ONE RULE IN THIS REPOSITORY AND THAT IS WORTH
/// KNOWING RATHER THAN HIDING. ``SupportResubmit`` says the same thing for the support
/// writes and was written first. Consolidating the two into one home in `DistrictData`
/// is worth doing and is deliberately not done as part of a feature change. ⛔ When the
/// consolidation happens it should take both; a third copy is the signal that it is
/// overdue.
/// ⚠️ `Equatable` IS STATED RATHER THAN LEFT OUT, unlike ``SupportResubmit``, so a test can
/// assert `.refused` directly rather than only the negation of ``isAllowed``. The two are
/// not the same claim: `isAllowed == false` is satisfied by any future third case, and the
/// thing worth pinning is which answer was given.
public enum NumberWriteResubmit: Sendable, Equatable {
    case allowed

    /// The control is gone and the only way on is a fresh read.
    case refused
}

public extension NumberWriteResubmit {
    var isAllowed: Bool {
        switch self {
        case .allowed:
            true
        case .refused:
            false
        }
    }

    /// What a failed write leaves behind. See the ⛔ on the type.
    static func after(_ error: ApiError, _ repeatable: NumberWriteRepeat) -> NumberWriteResubmit {
        guard case .once = repeatable else { return .allowed }
        guard let status = error.httpStatus, (400 ..< 500).contains(status) else { return .refused }
        return .allowed
    }
}

/// The regulatory paperwork, and the two things that can be done to a number the
/// workspace already holds.
///
/// ⛔ STILL NO PURCHASE. See the ⛔ on ``NumbersRepository`` itself: App Store Review
/// Guideline 3.1.1, and there is no descriptor to call even from inside this module.
public extension NumbersRepository {
    /// Which carriers this workspace has credentials for.
    ///
    /// ⛔ NO `ResponseEnvelope.affirm` HERE, AND THAT IS NOT AN OVERSIGHT. This route
    /// sends no `success` flag at all — the fourth on this surface after the scheduling
    /// pair, `stripeBilling` and `meetings` — so affirming one would look for a key that
    /// does not exist and fail every response. The required non-optional `connected` is
    /// what rejects a `{}` body.
    ///
    /// ⛔ AND IT ANSWERS TWO DIFFERENT KEY SETS, one letter apart. A workspace whose
    /// credentials do not resolve sends `{connected:false, provider:null}` (SINGULAR);
    /// everything else sends `{connected, providers:{…}}` (PLURAL). Both decode into
    /// ``ProviderStatusResponse`` on purpose, so a fresh workspace is an ordinary
    /// answer rather than drift.
    ///
    /// ⚠️ A CARRIER THAT REFUSED ITS CREDENTIALS IS CONTENT, NOT A FAILURE: it arrives
    /// as `{connected:false, error:"Invalid credentials"}` on that carrier's entry
    /// inside a 200. Read ``ProviderStatusResponse/refusedProviders``.
    func providerStatus(workspaceId: String) async -> Result<ProviderStatusResponse, ApiError> {
        await client.send(
            DistrictEndpoints.providerStatus(workspaceId: workspaceId),
            as: ProviderStatusResponse.self
        )
    }

    /// What a country's regulator asks for.
    ///
    /// ⛔ A NULL `requirements` IS NOT A FAILED LOOKUP AND MUST NOT BE CONVERTED INTO
    /// ONE. It means the country publishes no regulation for that number type, i.e. no
    /// registration is required, which is a real and common answer. A failed lookup
    /// throws server-side and arrives as a 500, so the two stay distinguishable — and
    /// collapsing them either way is wrong: upward tells a customer to file paperwork
    /// that does not exist, downward tells them none is needed when nobody could ask.
    ///
    /// ⛔ AND `purchasable` MUST NEVER BE INFERRED FROM `requirements`. The route's own
    /// header says so in terms; being able to describe a rule is not being able to
    /// satisfy it.
    ///
    /// ⚠️ ENVELOPE FIRST. Every field of this body would survive a thin document except
    /// the four required ones, and a half-decoded read would report `purchasable: false`
    /// with no requirements — which reads as "we cannot serve your market" about a
    /// country nobody looked at.
    func numberRequirements(
        workspaceId: String,
        country: String,
        numberType: String? = nil,
        endUserType: String? = nil
    ) async -> Result<NumberRequirementsResponse, ApiError> {
        let descriptor = DistrictEndpoints.numberRequirements(
            workspaceId: workspaceId,
            country: country,
            numberType: numberType,
            endUserType: endUserType
        )
        let outcome = await client.send(descriptor, as: NumberRequirementsResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("NumberRequirementsResponse", response.success, response)
        }
    }

    /// This workspace's regulatory filings, plus the two country gates.
    ///
    /// ⚠️ NOT FREE, AND NOT SAFE ON A TIMER. The route refreshes every in-review bundle
    /// from the carrier on read, at most once per bundle per request, because Twilio's
    /// review is asynchronous and calls nobody back. Both verbs on this path share one
    /// 60/hour budget per workspace, so a poll loop here spends a customer's own carrier
    /// calls.
    ///
    /// ⛔ A STATUS MAY BE STALE AND THE RESPONSE CANNOT SAY SO. The refresh DEGRADES
    /// rather than fails: missing carrier credentials, or a carrier having a bad minute,
    /// return the STORED status with nothing marking it. So a screen must not present a
    /// status as live-as-of-now.
    ///
    /// ⛔ AN EMPTY LIST IS A REAL ANSWER AND A FAILED READ IS NOT ONE. "Nothing filed
    /// yet" is the state every workspace starts in and is the screen where a customer is
    /// told to start; rendering "we could not look" as that would invite a duplicate
    /// filing. The envelope check is what keeps them apart.
    func numberRegistrations(workspaceId: String) async -> Result<NumberRegistrationsResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.numberRegistrations(workspaceId: workspaceId),
            as: NumberRegistrationsResponse.self
        )
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("NumberRegistrationsResponse", response.success, response)
        }
    }

    /// Open a new draft registration.
    ///
    /// ⚠️ ``NumberWriteRepeat/idempotent``, and by refusal rather than by convergence:
    /// there is one bundle per workspace per country and number type, so a second create
    /// is a **409** naming the existing one rather than a duplicate row. A failed create
    /// may be retried.
    ///
    /// ⛔ A DRAFT REACHES NO CARRIER. No EndUser, no Bundle, nothing: assembly happens
    /// once, at ``submitRegistration(workspaceId:bundleId:endUserAttributes:)``. So a
    /// screen must not call a created draft "filed" or "submitted", which is the word a
    /// customer will otherwise use back at us.
    ///
    /// ⚠️ TWO OF ITS REFUSALS ARE ORDINARY ANSWERS RATHER THAN FAULTS, AND BOTH ARE
    /// **409**: "you already have one for this pair", and "this combination publishes no
    /// regulation, so there is nothing to file". The second is a success in disguise and
    /// must not be drawn red. The server's own sentence distinguishes them and this
    /// layer deliberately does not try to.
    func createRegistration(
        workspaceId: String,
        isoCountry: String,
        numberType: String? = nil,
        endUserType: String? = nil,
        friendlyName: String? = nil
    ) async -> Result<NumberRegistrationCreatedResponse, ApiError> {
        let descriptor = DistrictEndpoints.createNumberRegistration(
            workspaceId: workspaceId,
            isoCountry: isoCountry,
            numberType: numberType,
            endUserType: endUserType,
            friendlyName: friendlyName
        )
        let outcome = await client.send(descriptor, as: NumberRegistrationCreatedResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("NumberRegistrationCreatedResponse", response.success, response)
        }
    }

    /// Attach one supporting document to a draft.
    ///
    /// ⚠️ ``NumberWriteRepeat/idempotent``: there is one document per requirement and a
    /// re-upload REPLACES it, sweeping the previous object unless the bytes are
    /// identical (the key is content-addressed, so the same file produces the same key
    /// and nothing is deleted).
    ///
    /// ⛔ THE REPLY IS NOT A LIST ROW. It answers `{id, requirementName, mimeType,
    /// sizeBytes, createdAt}` — `createdAt`, not `updatedAt`, and neither `stored` nor
    /// `submitted` — so a caller cannot splice it into a
    /// ``NumberRegistration/documents`` array. Re-read the list. See
    /// ``UploadedRegistrationDocument``.
    ///
    /// ⛔ IT CLEARS THE CARRIER'S COPY POINTER ON A REPLACEMENT, which is what makes a
    /// later submit treat that requirement as unsatisfied again. A screen that showed a
    /// replaced document as still submitted would let a customer believe a filing cites
    /// the file they just corrected.
    ///
    /// ⚠️ ITS REFUSALS ARE NOT ALL 400 and this layer translates none of them: **404**
    /// for a bundle that is not this workspace's, **409** past draft, **413** over 10
    /// MiB, **415** for a bad type OR for bytes that disagree with the declared type,
    /// **502** when object storage refused, **503** when the workspace's region has no
    /// document storage. Every one is the server's own sentence and every one is
    /// actionable.
    /// - Parameter document: ⛔ A TYPE RATHER THAN FIVE LOOSE ARGUMENTS, four of them strings.
    ///   See ``RegulatoryDocumentUpload``: the requirement name is the carrier's machine name and
    ///   is what the later push reads to decide what is still unsatisfied, so a transposition
    ///   files a document against nothing while compiling perfectly well.
    func uploadRegistrationDocument(
        workspaceId: String,
        document: RegulatoryDocumentUpload
    ) async -> Result<RegistrationDocumentResponse, ApiError> {
        let descriptor = DistrictEndpoints.uploadRegistrationDocument(
            workspaceId: workspaceId,
            document: document
        )
        let outcome = await client.send(descriptor, as: RegistrationDocumentResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("RegistrationDocumentResponse", response.success, response)
        }
    }

    /// Remove one document from a draft.
    ///
    /// ⚠️ ``NumberWriteRepeat/idempotent``: a second removal of the same row is a
    /// **404**, which is the outcome the caller asked for rather than a new problem.
    ///
    /// ⛔ A **502 CHANGED NOTHING AND THE ROW IS STILL THERE**, deliberately. This route
    /// deletes the OBJECT first and the row second — the opposite of the desk logo's
    /// order — because `storageKey` is the only pointer to the bytes and dropping the
    /// row first would abandon an identity document in a bucket under a name nobody can
    /// reconstruct. So a failed removal is retryable and must not be drawn as done.
    func deleteRegistrationDocument(
        workspaceId: String,
        bundleId: String,
        documentId: String
    ) async -> Result<RegistrationDocumentRemovalResponse, ApiError> {
        let descriptor = DistrictEndpoints.deleteRegistrationDocument(
            workspaceId: workspaceId,
            bundleId: bundleId,
            documentId: documentId
        )
        let outcome = await client.send(descriptor, as: RegistrationDocumentRemovalResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("RegistrationDocumentRemovalResponse", response.success, response)
        }
    }

    /// File the registration with the carrier.
    ///
    /// ⛔ ``NumberWriteRepeat/once``, AND IT NEEDS AN EXPLICIT CONFIRMATION. This is the
    /// one moment a registration leaves the platform: it assembles carrier resources on
    /// the workspace's own account and submits a REGULATED APPLICATION IN THE CUSTOMER'S
    /// NAME. 5/hour per workspace against its siblings' 60. ⚠️ The route's persist-as-you-go
    /// ordering means an OPERATOR's second tap re-uses the EndUser and every uploaded
    /// document rather than filing a second copy of a passport — which makes a deliberate
    /// retry cheap and is not a licence for this client to retry on its own.
    ///
    /// ⛔ A **422 IS "YOUR PAPERWORK IS WRONG" AND THE FILING STAYS A DRAFT**; a **502 IS
    /// "WE COULD NOT REACH THE CARRIER"**. Two answers, two next actions, and the route
    /// separates them precisely so a client does not send a customer to re-check
    /// documents that are perfectly correct.
    ///
    /// ⛔ AND THE 422's DETAIL DOES NOT SURVIVE ``ApiError``. That body carries
    /// `failures`, `reasons`, `missingFields` or `missingRequirements` alongside `error`,
    /// and the normaliser keeps only the sentence. It is recoverable rather than lost:
    /// the route stores the carrier's structured failures verbatim on the row, so
    /// ``numberRegistrations(workspaceId:)`` returns them as
    /// ``NumberRegistration/rejectionReasons``. **Re-read the list after a refusal** —
    /// showing only the sentence tells a customer their filing was refused without
    /// saying which part.
    ///
    /// ⚠️ THE REPLY IS THREE FIELDS, NOT A WHOLE ROW, so it has to be merged into the
    /// registration a screen already holds. See ``SubmittedRegistration``.
    func submitRegistration(
        workspaceId: String,
        bundleId: String,
        endUserAttributes: [String: JSONValue]
    ) async -> Result<NumberRegistrationSubmitResponse, ApiError> {
        let descriptor = DistrictEndpoints.submitNumberRegistration(
            workspaceId: workspaceId,
            bundleId: bundleId,
            endUserAttributes: endUserAttributes
        )
        let outcome = await client.send(descriptor, as: NumberRegistrationSubmitResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("NumberRegistrationSubmitResponse", response.success, response)
        }
    }

    /// Rebind one number's webhooks to this workspace.
    ///
    /// ⚠️ ``NumberWriteRepeat/idempotent``: the route writes the same webhooks and the
    /// same trunk binding every time, so a retry converges.
    ///
    /// ⛔ IT IS NOT THE HARMLESS ONE IT SOUNDS LIKE. On Twilio the number-level voice
    /// URLs and a trunk binding are MUTUALLY EXCLUSIVE, so the route restates the EU
    /// trunk binding on every call — and a reconfigure that omitted it would UNBIND an
    /// EU DID from the EU trunk, leaving the number ringing while being answered by the
    /// United States hub, contradicting what `/sovereign/data-residency` publishes, with
    /// a 200 either way. The route fails CLOSED (**503**) rather than degrade when the
    /// trunk sid is missing, which is why that refusal is a real sentence to show.
    ///
    /// ⚠️ **403 "Phone number not found in this workspace"** IS THE CROSS-TENANT
    /// OWNERSHIP GUARD, not a role refusal: on shared managed accounts the resolved
    /// credentials could reconfigure any tenant's number. ⚠️ **409** names a provider
    /// mismatch and is an instruction (reconnect that account), never something to
    /// retry.
    ///
    /// ⛔ THE ERRORS CARRY `{error: …}` WITH NO `success: false`, so there is nothing to
    /// affirm on the failure path — and the SUCCESS is a bare `{success: true}`, which
    /// ``SuccessResponse`` decodes and this method does affirm.
    func configureNumber(workspaceId: String, phoneNumber: String) async -> Result<SuccessResponse, ApiError> {
        let descriptor = DistrictEndpoints.configureNumber(workspaceId: workspaceId, phoneNumber: phoneNumber)
        let outcome = await client.send(descriptor, as: SuccessResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("SuccessResponse", response.success, response)
        }
    }

    /// Give one number back to the carrier.
    ///
    /// ⛔ ``NumberWriteRepeat/once``, IRREVERSIBLE, AND IT NEEDS AN EXPLICIT
    /// CONFIRMATION. The number returns to the carrier's general pool, so it is
    /// generally NOT reclaimable, and every inbound call and message routed to it stops
    /// — the tenant's callers reach nothing. ⚠️ Unlike a purchase there is no carrier
    /// balance that eventually stops a runaway: a loop keeps working until the workspace
    /// has no numbers left, and the only brake is 10/hour per workspace.
    ///
    /// ⛔ A **200 MAY CARRY `warnings`, AND THAT IS NOT A PARTIAL RELEASE.** The number
    /// is gone; a cleanup step after the irreversible part did not finish — the inbound
    /// trunk still lists it, or its monthly charge could not be ended, which means the
    /// workspace KEEPS BEING CHARGED for a number it no longer has. The flag is carried
    /// through inside the success rather than promoted to a failure, for the reason
    /// ``OwnedNumbersResponse``'s `partial` is: only the caller can render the middle
    /// answer, and both collapses lose information the operator needs.
    ///
    /// ⛔ A **502 MEANS NOTHING WAS CHANGED**: the route refuses to run any cleanup after
    /// a carrier refusal, because every step below it assumes the number is gone. That
    /// is also why a retry after a SUCCESS answers **403** — the ownership row the guard
    /// needs has just been deleted — which is the expected answer and must not be worded
    /// as "the release failed".
    ///
    /// ⛔ AND A MANAGED NUMBER IS NOT THE TENANT'S TO RELEASE. `managed: true` on
    /// ``ListedNumber`` means the line is held on Distronode's carrier account, so no
    /// release control may be offered for one — the row is theirs to USE, not to
    /// administer.
    func releaseNumber(workspaceId: String, phoneNumber: String) async -> Result<NumberReleaseResponse, ApiError> {
        let descriptor = DistrictEndpoints.releaseNumber(workspaceId: workspaceId, phoneNumber: phoneNumber)
        let outcome = await client.send(descriptor, as: NumberReleaseResponse.self)
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("NumberReleaseResponse", response.success, response)
        }
    }
}
