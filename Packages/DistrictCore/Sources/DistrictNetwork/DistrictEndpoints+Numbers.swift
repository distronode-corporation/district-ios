import Foundation

/// Phone-number provisioning: the regulatory paperwork, and the two things that can
/// be done to a number the workspace already has.
///
/// ⛔ THERE IS NO PURCHASE HERE AND THERE MUST NOT BE. `workspace/numbers/purchase`
/// charges a setup fee AND opens a recurring monthly charge for a service consumed
/// inside the app, which is App Store Review Guideline 3.1.1: an in-app purchase or
/// nothing at all. It has no ``EndpointID`` case, no ``DistrictPaths`` constant and
/// no function here, and since ``ApiRequestDescriptor``'s initialiser is internal it
/// is UNCONSTRUCTIBLE from outside this module rather than merely undocumented.
/// `EndpointSurfaceTests` pins that.
/// ⛔ 3.1.1 ALSO COVERS STEERING, so nothing in this client links to the web
/// marketplace either — not a button, not a Safari sheet, not a tappable URL.
/// ``MarketplaceCopy/readOnly`` names the site in prose and stops. The ⛔ at the top
/// of `MarketplaceView.swift` explains why a 3.1.3(b) citation does not license a
/// button here.
/// ⛔ THE NEXT READER WILL WANT TO FINISH THE SET IN GOOD FAITH: everything else on
/// the web marketplace's six tabs is ported, and purchase is the deliberate hole.
///
/// ⚠️ THE OTP FLOW IS ALSO ABSENT AND FOR A DIFFERENT REASON.
/// `workspace/verify/start` and `workspace/verify/check` are live POSTs
/// (agency/client); an OTP entry screen owns its own retry, expiry and
/// attempt-ceiling states, so it is a feature rather than two descriptors.
/// ``DistrictEndpoints/verifyService(workspaceId:)`` and its POST are the service's
/// CONFIGURATION, which is what this one ports.
///
/// ⚠️ ITS OWN FILE RATHER THAN MORE OF `DistrictEndpoints+Config.swift`, which is
/// where the workspace-settings family lives: this is a new family with its own
/// traps, and that file is already carrying the three wholesale-replace writes'
/// worth of commentary. The carrier-account half (A2P, toll-free verification, SIP
/// and the Verify service, plus the billable lookup) is in
/// `DistrictEndpoints+Carrier.swift` for SwiftLint's 500-line `file_length`.
public extension DistrictEndpoints {
    /// Which carriers this workspace has credentials for, and what they say.
    ///
    /// ⛔ NO `success` FLAG AT ALL, AND TWO DIFFERENT KEY SETS. A workspace with no
    /// resolvable credentials answers `{connected: false, provider: null}` —
    /// SINGULAR, and always null. Anything else answers `{connected, providers:
    /// {…}}` — PLURAL, a map keyed by carrier id. One letter apart, mutually
    /// exclusive, and a decoder that modelled only the plural would read a
    /// disconnected workspace as contract drift. See ``ProviderStatusResponse``,
    /// which is why nothing may reach for `ResponseEnvelope.affirm` on this route.
    ///
    /// ⚠️ A MANAGED PROVIDER REPORTS CONNECTIVITY AND NOTHING ELSE, and that is a
    /// privacy property rather than an omission. `getAccountInfo` describes the
    /// AUTHENTICATING account, which for a managed provider is the platform's own
    /// shared one — so its name, prepaid balance and total number count are
    /// Distronode's figures plus every other managed tenant's, never this caller's.
    /// The route short-circuits those before asking the carrier anything.
    ///
    /// ⚠️ ADMITS `viewer`, unlike almost everything else in this family.
    ///
    /// ⚠️ A CARRIER THAT REFUSES ITS CREDENTIALS IS A **200** carrying `{connected:
    /// false, error: "Invalid credentials"}` on that carrier's entry, not an HTTP
    /// failure. Per-carrier trouble is content here.
    static func providerStatus(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .providerStatus,
            .get,
            DistrictPaths.providerStatus,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// What a country's regulator asks for before a number there can be bought.
    ///
    /// ⛔ `purchasable` AND `requirements` ANSWER DIFFERENT QUESTIONS AND NEITHER MAY
    /// BE INFERRED FROM THE OTHER. The route's own header says so in terms:
    /// `purchasable` is "can I buy one today", `requirements` is "what would it
    /// take". A country can publish perfectly readable rules and still not be
    /// sellable here, because the purchase path also has to attach the resulting
    /// bundle and the number has to be routable to a bridge that serves it.
    ///
    /// ⛔ A `requirements` OF **NULL IS NOT A FAILURE**. It means the country
    /// publishes no regulation for that number type, i.e. no registration is
    /// required — a real and common answer. A failed lookup THROWS and arrives as a
    /// 500, so the two stay distinguishable; collapsing them would tell a customer
    /// to file paperwork that does not exist, or that none is needed when we simply
    /// could not ask.
    ///
    /// - Parameters:
    ///   - country: ⚠️ UPPERCASED SERVER-SIDE AND THEN PATTERN-CHECKED
    ///     (`/^[A-Z]{2}$/`), so anything that is not two letters is a **400** rather
    ///     than an empty answer. Sent as typed; the server owns the normalisation.
    ///   - numberType: ⚠️ THE QUERY PARAMETER IS SPELLED **`type`**, not
    ///     `numberType`, and the route defaults it to `local`. Twilio's own
    ///     vocabulary is `local`, `mobile`, `national`, `toll free` — note the SPACE
    ///     in the last one, which is the carrier's spelling and not `tollFree`.
    ///     ⛔ That is a different vocabulary from ``searchNumbers``' `type`, which
    ///     takes `local`/`tollFree`/`mobile`. Two routes, two spellings, one word
    ///     apart.
    ///   - endUserType: ⛔ IT CHANGES THE ANSWER RATHER THAN THE WORDING OF IT. A
    ///     business and an individual are asked for entirely different documents in
    ///     the same country, so a form built for one from the other's regulation asks
    ///     for papers they do not have. ⚠️ Anything other than the literal
    ///     `"individual"` reads as `business`, which is the carrier's default and
    ///     what every customer buying through us is today — so a typo silently
    ///     answers the business question.
    static func numberRequirements(
        workspaceId: String,
        country: String,
        numberType: String?,
        endUserType: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .numberRequirements,
            .get,
            DistrictPaths.numbersRequirements,
            query: [
                ApiQueryItem("workspaceId", workspaceId),
                ApiQueryItem("country", country),
                // ⚠️ Nil is DROPPED rather than sent empty, which is what makes the
                // route's own `|| "local"` default the one that applies.
                ApiQueryItem("type", numberType),
                ApiQueryItem("endUserType", endUserType),
            ]
        )
    }

    /// This workspace's regulatory filings, newest first.
    ///
    /// ⚠️ THE READ SPENDS A CARRIER CALL PER IN-REVIEW BUNDLE, so it is not free and
    /// must not be put on a timer. There is no background poller anywhere: Twilio's
    /// review is asynchronous (~26h observed) and calls nobody back, so a status is
    /// refreshed HERE, at most once per bundle per request, and only for the two
    /// statuses that can still move. Both verbs on this path share one 60/hour
    /// budget per workspace.
    ///
    /// ⛔ IT DEGRADES RATHER THAN FAILS, WHICH IS WHY A STATUS MAY BE STALE. A
    /// workspace whose carrier credentials are missing, or a carrier having a bad
    /// minute, still gets "here are your four registrations" with the STORED status —
    /// showing it late is strictly better than showing nothing. So a screen must not
    /// present a status as live-as-of-now.
    ///
    /// ⛔ `approvedCountries` AND `platformCountries` LIVE ON THIS RESPONSE AND NOT ON
    /// ``searchNumbers``, and that is a contract constraint rather than a filing
    /// choice: the search response is byte-frozen by an Android contract fixture, so
    /// widening it breaks a client decoding with `ignoreUnknownKeys = false`.
    ///
    /// ⚠️ EXCLUDES `viewer` ON BOTH VERBS — the list carries a customer's filing
    /// status and their rejection reasons.
    static func numberRegistrations(workspaceId: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .numberRegistrations,
            .get,
            DistrictPaths.numbersRegistrations,
            query: [ApiQueryItem("workspaceId", workspaceId)]
        )
    }

    /// Open a new draft registration.
    ///
    /// ⛔ THE WORKSPACE IS A QUERY PARAMETER, NOT A BODY FIELD, AND THE ORDER IS THE
    /// POINT. The route runs auth, the limiter and the billing check before it reads
    /// a body at all, so an id carried in the JSON would leave
    /// `requireWorkspaceRole` with null while the body reads perfectly correct. Same
    /// shape as `desk/logo` and the documents route.
    ///
    /// ⛔ A DRAFT IS A LOCAL ROW AND NOTHING AT THE CARRIER. No EndUser, no Bundle,
    /// no anything: assembly happens once, at
    /// ``submitNumberRegistration(workspaceId:bundleId:endUserAttributes:)``. The
    /// alternative leaves a half-built bundle on a customer's own Twilio sub-account
    /// every time somebody opens the form and wanders off, with no reconciliation
    /// path that could tell those from real ones.
    ///
    /// ⚠️ ANSWERS **201**, not 200, and echoes the whole created row.
    ///
    /// ⚠️ ITS REFUSALS ARE NOT ALL 400 AND TWO OF THEM ARE ORDINARY ANSWERS. **409**
    /// is either "you already have a registration for this country and number type"
    /// (one per workspace per pair, the schema's own constraint) or "this combination
    /// publishes no regulation, so there is nothing to file" — the second is not an
    /// error at all and must not read as one. **502** is "we could not read that
    /// country's requirements", which is retryable. Surface the server's sentence;
    /// this client can pre-compute none of them.
    ///
    /// - Parameters:
    ///   - numberType: ⚠️ Validated against Twilio's vocabulary — `local`, `mobile`,
    ///     `national`, `toll free` — and defaulted to `local`. Note the SPACE in the
    ///     last one.
    ///   - endUserType: ⚠️ `business` or `individual`, defaulted to `business`.
    ///     Anything else is a 400 here, unlike
    ///     ``numberRequirements(workspaceId:country:numberType:endUserType:)`` where
    ///     an unrecognised value silently reads as business.
    ///   - friendlyName: ⚠️ Ours to choose and Twilio shows it in the CUSTOMER'S own
    ///     console. Capped at 120 characters server-side (Twilio's own field length);
    ///     blank is stored as null.
    static func createNumberRegistration(
        workspaceId: String,
        isoCountry: String,
        numberType: String?,
        endUserType: String?,
        friendlyName: String?
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .createNumberRegistration,
            .post,
            DistrictPaths.numbersRegistrations,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([
                ("isoCountry", .string(isoCountry)),
                ("numberType", .optional(numberType)),
                ("endUserType", .optional(endUserType)),
                ("friendlyName", .optional(friendlyName)),
            ]))
        )
    }

    /// Attach one supporting document to a draft registration.
    ///
    /// ⛔ THE THIRD MULTIPART ROUTE ON THIS SURFACE AND ITS PART LIST MATCHES NEITHER
    /// OF THE OTHER TWO. `messages/media` sends `workspaceId` as a form FIELD and
    /// nothing else; `desk/logo` sends NO fields and reads the workspace off the
    /// query; this one reads the workspace off the QUERY **and** sends two fields
    /// that are not the workspace. Copying either neighbour's parts is a 400 from a
    /// request whose URL reads correctly — which is precisely why
    /// `EndpointTable.ExpectedBody.multipart` carries its fields per row.
    ///
    /// ⛔ THE WORKSPACE IS IN THE QUERY BECAUSE `formData()` BUFFERS THE WHOLE BODY
    /// BEFORE ANYTHING CAN LOOK AT IT. An id carried in the body would force that
    /// buffering on unauthenticated callers; with it in the URL, auth, the limiter
    /// and the billing check all run before a single body byte is parsed.
    ///
    /// ⛔ DRAFT ONLY. Once a bundle has been submitted the carrier and the regulator
    /// hold a copy of exactly the documents that were sent, so a swap on our side
    /// would leave our record disagreeing with the filing under review and the
    /// customer believing they had corrected something they had not. That refusal is
    /// **409**, not 403: the request is well-formed and will be valid again if the
    /// filing comes back rejected.
    ///
    /// ⚠️ ITS REFUSALS ARE NOT ALL 400. **404** for a bundle that is not this
    /// workspace's (deliberately identical to one that does not exist), **409** for a
    /// bundle past draft, **413** over 10 MiB, **415** for a type that is not PDF /
    /// PNG / JPEG **or whose bytes disagree with the declared type** (the declared
    /// value is used for exactly one thing: disagreeing with the sniffed one), **502**
    /// when the object store refused, **503** when the workspace's region has no
    /// document storage. Surface the server's own sentence.
    ///
    /// ⚠️ RE-UPLOADING THE SAME REQUIREMENT REPLACES IT and CLEARS the carrier's copy
    /// pointer, which is what makes the later push treat it as unsatisfied again.
    /// There is one document per requirement, enforced in the route rather than by an
    /// index.
    ///
    /// - Parameter document: ⛔ A TYPE RATHER THAN FIVE LOOSE ARGUMENTS. Four of them are
    ///   strings, so a transposition at a call site would compile and file a document against
    ///   the wrong requirement — and the requirement name is what the later push reads to decide
    ///   what is still unsatisfied. See ``RegulatoryDocumentUpload``.
    static func uploadRegistrationDocument(
        workspaceId: String,
        document: RegulatoryDocumentUpload
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .uploadRegistrationDocument,
            .post,
            DistrictPaths.numbersRegistrationDocuments,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .multipart(MultipartBody(
                // ⛔ TWO FIELDS, AND NEITHER IS THE WORKSPACE. See the ⛔ on this function.
                fields: [
                    "bundleId": document.bundleId,
                    "requirementName": document.requirementName,
                ],
                fileName: document.fileName,
                contentType: document.mimeType,
                bytes: document.bytes
            ))
        )
    }

    /// Remove one document from a draft registration.
    ///
    /// ⛔ **THE ONLY DELETE ON THIS API THAT CARRIES A BODY.** Every other one reads
    /// query parameters and would ignore a body; this route reads `bundleId` and
    /// `documentId` off `req.json()` and only the workspace off the query. Sending
    /// them as query parameters is a 400 ("A bundleId and documentId are required")
    /// from a URL that looks entirely reasonable.
    /// `EndpointTableTests.testNoDeleteCarriesABodyExceptTheOneThatMust` records the
    /// exception rather than dropping the convention.
    ///
    /// ⛔ THE OBJECT GOES FIRST AND THE ROW SECOND, WHICH IS THE OPPOSITE OF
    /// `desk/logo`'S ORDER AND IS WHY A FAILURE HERE IS A **502 THAT CHANGED
    /// NOTHING**. There, clearing the column is what stops the image being SHOWN, so
    /// it must not be blocked by a storage error. Here nothing displays the document
    /// and `storageKey` is the ONLY pointer to the bytes, so dropping the row first
    /// would leave an identity document in a bucket under a name nobody can
    /// reconstruct. A refused object delete keeps the row, which is retryable.
    ///
    /// ⚠️ DRAFT ONLY, like the upload, and with the same 409.
    static func deleteRegistrationDocument(
        workspaceId: String,
        bundleId: String,
        documentId: String
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .deleteRegistrationDocument,
            .delete,
            DistrictPaths.numbersRegistrationDocuments,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([
                ("bundleId", .string(bundleId)),
                ("documentId", .string(documentId)),
            ]))
        )
    }

    /// File the registration with the carrier.
    ///
    /// ⛔ THE ONE MOMENT A REGISTRATION LEAVES THIS PLATFORM. Everything before it is
    /// local rows and stored bytes; this assembles an EndUser, a SupportingDocument
    /// per requirement and a Bundle tying them together on the workspace's OWN
    /// carrier account, and submits a REGULATED APPLICATION IN THE CUSTOMER'S NAME.
    /// It needs an explicit confirmation, and nothing in this client may send it
    /// automatically. 5/hour per workspace, against its siblings' 60.
    ///
    /// ⚠️ A RE-SUBMIT IS SAFE AT THE CARRIER AND THAT IS NOT A LICENCE TO AUTOMATE
    /// ONE. The route persists each carrier id the moment it exists, so a retry
    /// re-uses the EndUser and every uploaded document rather than filing a second
    /// copy of a customer's passport. What it makes cheap is an OPERATOR's second
    /// tap.
    ///
    /// ⛔ A **422 IS "YOUR PAPERWORK IS WRONG" AND THE FILING STAYS A DRAFT**; a
    /// **502 IS "WE COULD NOT REACH THE CARRIER"** and is retryable. Two answers, two
    /// next actions, and the route separates them on purpose — a 502 dressed as a 422
    /// would send a customer to re-check documents that are perfectly correct.
    /// ⚠️ THE 422's DETAIL DOES NOT SURVIVE ``ApiError``. That body carries
    /// `failures`, `reasons`, `missingFields` or `missingRequirements` alongside
    /// `error`, and the normaliser keeps only the sentence. That is recoverable rather
    /// than lost: the route STORES the carrier's structured failures verbatim on the
    /// row, so a re-read of ``numberRegistrations(workspaceId:)`` returns them as
    /// `rejectionReasons`. Read the list again after a refusal.
    ///
    /// ⚠️ THE REVIEW EMAIL IS THE SESSION'S, resolved by auth, never anything a
    /// request supplied — so there is no address parameter here and cannot be one.
    ///
    /// - Parameter endUserAttributes: ⛔ FLAT, AND THE REGULATION DECIDES THE KEYS.
    ///   Text, numbers, true/false or a list of text; a nested object, an explicit
    ///   null or a mixed array is a **400** rather than a coerced value, because a
    ///   silently dropped attribute is a bundle that evaluates as noncompliant for a
    ///   reason the customer cannot see in their own form. The field list is per
    ///   country AND per number type AND per end-user type and changes without
    ///   notice, so it comes from
    ///   ``numberRequirements(workspaceId:country:numberType:endUserType:)`` rather
    ///   than from any form drawn here.
    static func submitNumberRegistration(
        workspaceId: String,
        bundleId: String,
        endUserAttributes: [String: JSONValue]
    ) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .submitNumberRegistration,
            .post,
            DistrictPaths.numbersRegistrationSubmit,
            query: [ApiQueryItem("workspaceId", workspaceId)],
            body: .json(.object([
                ("bundleId", .string(bundleId)),
                // ⚠️ SENT EVEN WHEN EMPTY. The route reads `endUserAttributes ?? {}`
                // so an absent key is legal, but an explicit `{}` is what makes a
                // captured request say "no attributes were supplied" rather than
                // "this client forgot the key".
                ("endUserAttributes", .object(endUserAttributes)),
            ]))
        )
    }

    /// Rebind one number's webhooks to this workspace.
    ///
    /// ⛔ IT IS NOT THE HARMLESS ONE IT SOUNDS LIKE, AND ITS FAILURE MODE IS A 200. On
    /// Twilio the number-level voice URLs and a trunk binding are MUTUALLY EXCLUSIVE,
    /// so the route restates the EU trunk binding on every call — a reconfigure that
    /// sent only the URLs would UNBIND an EU DID from the EU trunk, and the number
    /// would keep ringing while being answered by the United States hub,
    /// contradicting what `/sovereign/data-residency` publishes. Nothing about that is
    /// visible in the response.
    ///
    /// ⛔ THE TRUNK IS RESOLVED FROM THE NUMBER'S COUNTRY, NEVER THE WORKSPACE'S
    /// REGION: a +372 number held by a `us` workspace is still answered in Frankfurt.
    /// And the route FAILS CLOSED with a **503** when the EU trunk sid is not
    /// configured, because the degrade there is a state CHANGE dressed as a no-op.
    ///
    /// ⚠️ **403 "Phone number not found in this workspace"** IS THE CROSS-TENANT
    /// GUARD, NOT A ROLE REFUSAL. On shared managed accounts the resolved credentials
    /// could reconfigure ANY tenant's number, so ownership is asserted against the hub
    /// index before anything is rebound.
    ///
    /// ⚠️ **409** NAMES A PROVIDER MISMATCH and is an instruction rather than a fault:
    /// the number was provisioned on a carrier this workspace has no credentials for,
    /// and rebinding through a vendor that has never heard of it is
    /// indistinguishable from success at this layer. Reconnect that account; do not
    /// retry.
    ///
    /// ⚠️ ANSWERS A BARE `{success: true}` — no echo, so a caller needing fresh state
    /// re-reads ``ownedNumbers(workspaceId:)``. Its errors are `{error: …}` with no
    /// `success: false`, which is why nothing here affirms an envelope.
    static func configureNumber(workspaceId: String, phoneNumber: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .configureNumber,
            .post,
            DistrictPaths.numbersConfigure,
            body: .json(.object([
                // ⚠️ THE WORKSPACE IS IN THE BODY HERE AND IN THE QUERY ON THE
                // REGISTRATION ROUTES. This route reads `req.json()` first and
                // `requireWorkspaceRole` is called with the parsed value, so a query
                // parameter alone would be a 400 "Missing workspaceId or phoneNumber".
                ("workspaceId", .string(workspaceId)),
                ("phoneNumber", .string(phoneNumber)),
            ]))
        )
    }

    /// Give one number back to the carrier.
    ///
    /// ⛔ IRREVERSIBLE, AND THE MOST DESTRUCTIVE CALL ON THIS FAMILY. The number
    /// returns to the general pool, so it is generally NOT reclaimable, and every
    /// inbound call and message routed to it stops — the tenant's callers reach
    /// nothing. It needs an explicit confirmation, and a failed attempt must NOT
    /// silently re-arm the control. ⚠️ Unlike a purchase there is no carrier balance
    /// that eventually stops a runaway: a loop keeps working until the workspace has
    /// no numbers left, and the only brake is 10/hour per workspace.
    ///
    /// ⛔ A **200 MAY CARRY `warnings`, AND THAT IS NOT A PARTIAL RELEASE.** The
    /// number is gone; what failed is a cleanup step AFTER the irreversible part —
    /// the inbound trunk still lists it, or its monthly charge could not be ended. A
    /// client that dropped the array would leave an operator believing they had
    /// stopped a charge they had not. See ``NumberReleaseResponse``.
    ///
    /// ⛔ A **502 MEANS NOTHING WAS CHANGED**, deliberately: the route refuses to run
    /// any cleanup after a carrier refusal, because every step below it assumes the
    /// number is gone. The surviving ownership row is what makes a retry possible, and
    /// it is also why a retry AFTER a success answers 403 rather than releasing twice.
    ///
    /// ⚠️ **403** is the same cross-tenant ownership guard the configure route has;
    /// **409** is the same provider mismatch, and reconnecting the named account is
    /// the fix rather than retrying.
    ///
    /// ⚠️ A MANAGED NUMBER IS NOT THE TENANT'S TO RELEASE. `managed: true` on
    /// ``ListedNumber`` means the line is held on Distronode's carrier account, so the
    /// row is theirs to USE and not to administer, and no release control may be
    /// offered for one.
    static func releaseNumber(workspaceId: String, phoneNumber: String) -> ApiRequestDescriptor {
        ApiRequestDescriptor(
            .releaseNumber,
            .post,
            DistrictPaths.numbersRelease,
            body: .json(.object([
                ("workspaceId", .string(workspaceId)),
                ("phoneNumber", .string(phoneNumber)),
            ]))
        )
    }
}
