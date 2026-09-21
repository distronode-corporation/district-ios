import DistrictModel
import Foundation

// The scheduling admin's settings, recordings, developer and upload rows, gated
// against the fifteen fixtures they model.
//
// ⛔ SPLIT OUT BECAUSE `ImplementedFixtures.swift` IS AT ITS 500-LINE CEILING, the
// same reason `+MessageThread.swift`, `+SchedulingAdmin.swift` and
// `+SchedulingB.swift` were. SwiftLint's `file_length` warning is an ERROR under
// `--strict`, so one line added inline reds the LINT job rather than the gate — a
// failure a long way from the change that caused it.

extension ImplementedFixtures {
    // MARK: - Settings, recordings, developer and the image upload

    /// ⛔ FOURTEEN RPC PAYLOADS PLUS ONE THAT IS NOT AN RPC PAYLOAD AT ALL, AND
    /// THE ODD ONE IS THE REASON TO READ THIS LIST RATHER THAN SKIM IT.
    /// `district-scheduling-upload.json` is the MULTIPART route's answer: it is not
    /// in the op catalog, it has no `op` name, and it arrives from
    /// `/api/district/scheduling/admin/upload` — yet it wears
    /// ``SchedulingAdminSuccess`` because that route deliberately answers the
    /// catalog's envelope, `{ok:false, failure, status}` at HTTP **200** included,
    /// so both surfaces have one failure vocabulary. Gating it here is what pins
    /// that deliberate agreement; if the upload route ever stopped matching, this
    /// entry fails and nothing else would.
    ///
    /// ⛔ THREE CONTAINER CONVENTIONS LIVE IN THESE FIFTEEN FILES AND THEY ARE NOT
    /// DERIVABLE FROM THE OP'S NAME. `apiKeys.list`, `oauth.connections.list`,
    /// `webhooks.list` and `webhooks.deliveries` use the catalog's shared
    /// `items(...)` helper, so they gate through ``SchedulingItems``;
    /// `recordings.list` and `recordings.consent` declare `recordings` and
    /// `consents` BY HAND and gate through their own types; and every settings op
    /// answers a bare object with no container at all. Reading one through
    /// another's container is a missing-key decode error that presents as an
    /// outage, which is exactly the failure the strict gate turns into a named
    /// line.
    ///
    /// ⛔ THE TWO "CREATED" BODIES ARE SEPARATE TYPES FROM THEIR LIST ROWS, NOT
    /// OPTIONAL FIELDS ON THEM, AND THE GATE IS WHAT MAKES THAT SAFE RATHER THAN
    /// MERELY TIDY. `district-scheduling-api-key-created.json` carries `key` — the
    /// plaintext credential, shown once — and `-webhook-created.json` carries
    /// `secret`. Modelled as Optionals on ``SchedulingAPIKey`` and
    /// ``SchedulingWebhook``, both would ROUND-TRIP CLEANLY against the list
    /// fixtures too (a nil Optional writes an absent key), so the gate would not
    /// object and "is the secret here" would become a runtime question asked in
    /// every cell. Two types make it a compile-time question asked once.
    ///
    /// ⚠️ FOUR EXPLICIT NULLS ACROSS THREE OF THE FIFTEEN, so
    /// ``ContractManifest/expectedAllowedNullPaths`` moves by four and
    /// `AllowedExplicitNulls+SchedulingC.swift` says which columns and why. ⛔ The
    /// twelve others carry NONE — checked against the fixture bytes rather than
    /// inferred from the types — and that includes the three whose rows look most
    /// like candidates: the failed recording missing six of eight keys, the guest
    /// with no consent timestamp, and the delivery that got no answer are all
    /// ABSENT keys, which a nil Optional already round-trips.
    ///
    /// ⚠️ ``ContractManifest/expectedFixtureCount`` DOES NOT MOVE. It counts files
    /// on disk; all fifteen have been there since the generator ran, and the only
    /// thing changing is which of the two lists they are in.
    static var schedulingC: [ImplementedFixture] {
        settingsFixtures + recordingsFixtures + developerFixtures
    }

    /// `me.*` and the four `settings.*` namespaces.
    ///
    /// ⛔ THE THREE SETTINGS BODIES ARE TINY BECAUSE THE CATALOG STRIPPED THEM, NOT
    /// BECAUSE THE FORK IS. `settings.llm` answers two fields here and six more at
    /// the far end (`endpoint`, `model`, `api_key_set`, `configured`, `active`,
    /// `base_prompt`); notetaker drops `stt_api_key_set` and `stt_base_url`;
    /// storage drops all three `backups_*`. Every one of those names an INSTANCE
    /// credential or a resource shared with other tenancies. ⚠️ So a DTO grown
    /// "to match the fork" would model keys that cannot arrive, and this gate would
    /// report them as ADDED on re-encode — which is the right failure, in the right
    /// place, for the right reason.
    private static var settingsFixtures: [ImplementedFixture] {
        [
            gate("district-scheduling-me.json", SchedulingAdminSuccess<SchedulingMe>.self),
            gate("district-scheduling-branding.json", SchedulingAdminSuccess<SchedulingBranding>.self),
            gate("district-scheduling-storage.json", SchedulingAdminSuccess<SchedulingStorageSettings>.self),
            gate("district-scheduling-notetaker.json", SchedulingAdminSuccess<SchedulingNotetakerSettings>.self),
            gate("district-scheduling-llm.json", SchedulingAdminSuccess<SchedulingLLMSettings>.self),
            // ⚠️ NOT AN OP. The multipart route's answer — see the ⛔ on
            // ``schedulingC``. It is filed beside branding because `logo` and
            // `banner` are the two targets a branding screen sends.
            gate("district-scheduling-upload.json", SchedulingAdminSuccess<SchedulingUploadResult>.self),
        ]
    }

    /// `recordings.*`.
    ///
    /// ⛔ THE LIST FIXTURE'S SECOND ROW IS THE ONE THAT MATTERS: `{id, status}` and
    /// nothing else, a capture that FAILED and therefore has no room, no duration,
    /// no file and no booker. A DTO that required `booking_id` would throw on the
    /// one row an operator most needs to see, and the failure would present as
    /// "recordings are broken" rather than "one recording failed". Row 0 is fully
    /// populated, so the pair proves every Optional in both directions.
    ///
    /// ⚠️ `-recordings-deleted.json` IS TWO INTEGERS AND IS GATED ANYWAY. `failed:
    /// 1` beside `deleted: 4` is a PARTIAL failure reported at HTTP 200, and a
    /// client that dropped the second number would tell a customer their recordings
    /// are gone while one of them is still in the bucket. The gate is what stops
    /// the field being quietly dropped from the DTO later.
    private static var recordingsFixtures: [ImplementedFixture] {
        [
            gate("district-scheduling-recordings.json", SchedulingAdminSuccess<SchedulingRecordingList>.self),
            gate(
                "district-scheduling-recordings-deleted.json",
                SchedulingAdminSuccess<SchedulingRecordingsDeleted>.self
            ),
            gate(
                "district-scheduling-recordings-consent.json",
                SchedulingAdminSuccess<SchedulingRecordingConsents>.self
            ),
        ]
    }

    /// `apiKeys.*`, `oauth.connections.*` and `webhooks.*`.
    ///
    /// ⚠️ THE THREE `items` LISTS ALL CARRY A SECOND ROW WHOSE NULLS ARE THE POINT,
    /// and they are not the same null. The unused API key nulls `last_used_at`; the
    /// OAuth connection nulls that AND `expires_at`, where nil means "does not
    /// expire" rather than "expired"; the inactive webhook nulls `fields`, where nil
    /// means "the fork's default set" rather than "no fields". Three fixtures, three
    /// different wrong readings, each one a claim a customer would act on.
    private static var developerFixtures: [ImplementedFixture] {
        [
            gate(
                "district-scheduling-api-keys.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingAPIKey>>.self
            ),
            gate("district-scheduling-api-key-created.json", SchedulingAdminSuccess<SchedulingAPIKeyCreated>.self),
            gate(
                "district-scheduling-oauth-connections.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingOAuthConnection>>.self
            ),
            gate(
                "district-scheduling-webhooks.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingWebhook>>.self
            ),
            gate("district-scheduling-webhook-created.json", SchedulingAdminSuccess<SchedulingWebhookCreated>.self),
            gate(
                "district-scheduling-webhook-deliveries.json",
                SchedulingAdminSuccess<SchedulingItems<SchedulingWebhookDelivery>>.self
            ),
        ]
    }
}
