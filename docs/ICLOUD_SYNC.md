# iCloud sync (experimental)

Settings → sync uses a single opt-in switch on each Mac. Regular profiles, pins/groups and appearance share a workspace; ordinary open tabs appear as per-Mac lists and open only when selected. New remote profiles have empty local website storage. Sensitive device state stays local through explicit field allowlists in `ICloudSyncProjection`.

The feature ships as experimental and stays off by default on every Mac. Owen has provisioned iCloud. Two-Mac testing is unavailable, so live delivery, concurrent edits and recovery across Macs remain unverified. That validation gap is recorded here and in settings; the privacy policy describes the feature’s data handling and experimental status.

## Reference behavior

[Arc Sync](https://resources.arc.net/hc/en-us/articles/20272860828823-Arc-Sync) shares Spaces, folders and tabs with a single settings switch. Arc's current sync replaced its old iCloud implementation in 2024 and uses its own account and encryption/recovery system. [Arc profiles](https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing) don't sync. loaf follows the simple enable-on-each-device flow and shared pins/groups, adds profile metadata and browser preferences, and keeps ordinary windows separate. [Safari's iCloud model](https://support.apple.com/guide/icloud/what-you-can-do-with-icloud-and-safari-mm9b8da4f328/1.0/icloud/1.0) also distinguishes browsing organization and tabs on other devices.

## Apple configuration reference

Provisioning is reported complete. These are the configuration requirements for the existing setup and future signing or schema changes, rather than a request to provision again. The offline suite does not inspect the deployed CloudKit schema.

1. In the Apple Developer account for team `2Z7G4AHZG9`, enable iCloud/CloudKit and Push Notifications for `app.tryloaf.loaf`, and associate `iCloud.app.tryloaf.loaf`. Create or update the development and Developer ID provisioning profiles with those entitlements. Developer ID distributions need the CloudKit-enabled profile embedded in the signed app; a bare Developer ID or ad-hoc signature is insufficient.
2. Build a development-provisioned app and enable sync with a disposable iCloud account to create the `LoafSyncV1` private custom zone and `LoafSyncDocumentV1` record type. The **new** `payloadV1` field must be encrypted Bytes, written through `CKRecord.encryptedValues`. Do not create a plain Bytes field with this name first; CloudKit cannot convert an existing field to encrypted storage. No query indexes or public records are used.
3. Deploy the development schema to Production in CloudKit Console. Release uses the Production environment and production push entitlement; Debug uses Development. Keep environments separate during testing.
4. Verify the signed entitlements and embedded profile for distribution. Multi-Mac testing in Production and Development remains future validation work while the feature is experimental.

### Request and schema errors

CloudKit error 12 means an invalid request. It does not mean the local sync journal is corrupt. A production-schema rejection requires checking `LoafSyncDocumentV1` and its encrypted Bytes `payloadV1` field in the configured container's Production environment. Deploying the Development schema is separate from configuring signing and provisioning. Do not reset local sync data to repair a missing server schema.

The app distinguishes explicit production-schema rejections from other invalid requests and preserves useful configuration errors inside partial failures. Status messages do not expose raw CloudKit error details. These messages and the offline tests cannot verify whether the production schema has been deployed.

No credentials, developer account changes, schema deployment, or live iCloud transfers are performed by the offline automated tests.

## Storage and recovery

`icloud-sync-v1.json` is an atomic, owner-only local journal containing document data, a durable dirty-record outbox, last exported values, archived CKRecord system fields, account binding, and CKSyncEngine state serialization. Local session storage remains independent of network availability. Incoming data is decoded before live changes; session changes are persisted before advancing the sync token. Read failures pause sync and retain the journal. The settings repair action saves an owner-only backup, resets only the local sync cache and keeps sync off until deliberately reenabled. Runtime errors can be retried by turning sync on again after correcting the cause. Transient service/network errors remain queued. The UI reports storage, account and provisioning errors without recording URLs or credentials in diagnostics.

Each shared field has a logical counter and a random installation identifier. Merge takes the greatest stamp, avoiding wall-clock skew. Pins and groups are separate fields so different items merge independently; edits inside the same group resolve as one item. Profile deletion is a permanent tombstone and defeats later offline edits. CloudKit save conflicts merge against the server record and retry with the new change tag. Bootstrap fetches and a known-zone existence check precede uploads, so a deleted cloud copy cannot be recreated by queued offline edits. Incoming session writes must succeed before sync tokens advance. The engine handles incremental fetches, token expiry, throttling and retry scheduling. Changes are fetched on activation and once per minute while running in addition to the engine's automatic schedule. Record batches are capped below CloudKit's 250-record limit; oversized payloads pause without silently truncating data.

Account changes disable sync before another batch can be provided. Enabling for another account is deliberate and seeds from the current local workspace. Cloud-zone removal retains local data and disables other active clients when they receive the deletion. It never automatically republishes a deleted zone following a fetched reset. Deletion records persist until the zone is removed. Inactive tab snapshots are hidden after 30 days but remain stored until their source updates them or the zone is removed.

CloudKit encrypted fields are used without promising an independent loaf end-to-end encryption scheme. [Apple's encrypted-field documentation](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues) and [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5) explain the platform behavior.

## Verification

Build Debug with `xcodebuild -project loaf.xcodeproj -scheme loaf -configuration Debug -destination "platform=macOS" -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`, then run `scripts/test-icloud-sync.sh`. It covers projection exclusions, hostile addresses, independent/conflicting edits, permanent deletions, offline journal round trips, remote profile application, local-data preservation, and encrypted-record payloads without signing into iCloud.

Before removing the experimental designation, use two provisioned Macs to verify: first enable with existing data on both; profile/pin/group add, edit, reorder and delete; offline concurrent changes; app termination before/after upload; Wi-Fi loss; iCloud storage full; account sign-out/switch; zone deletion on one Mac while the other is offline; reset encrypted iCloud data; Production schema; and remote tabs opening in their own profile without closing the source. The offline tests cannot establish live CloudKit delivery or provisioning correctness.

## Local validation on October 11, 2026

Debug builds successfully. The sync suite passes 96 offline checks, including canonical encoding (unchanged snapshots never manufacture edits), local session-write failure, corrupt-cache recovery and preservation of already-open tabs when a shared pin is removed. The rendered settings view was inspected. The legal-agreement suite passes 17 checks; legal document copies match; website tests pass 17 cases; release-pipeline unit tests pass six cases.

The broader session-lifecycle test passes all eight SIGKILL/atomic-save restoration cases. Its active-WebKit/download fixture fails before the interruption boundary because the fixture transfer is not active; those three active-transfer crash cases remain unverified. No live iCloud tests or schema deployment were performed by the coding agent; Owen reports provisioning complete. The full-source privacy release-review fingerprint must be refreshed as part of release review; policy consistency checks alone do not replace that review.
