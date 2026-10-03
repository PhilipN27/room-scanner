# Optional private iCloud backup setup

Phase 6 keeps RoomScanStudio local-first and offline-capable. Cloud backup is
off by default, changing the local opt-in does not make a network request, and
the app performs no CloudKit work at launch. Check account, List backups, Back
up, and Recover are separate explicit actions.

## Operator configuration

The repository intentionally contains no development team, provisioning
profile, iCloud entitlement, or guessed container ID. In a separately managed
macOS signing environment, set the exact operator-owned build setting:

    ROOMSCANSTUDIO_CLOUD_BACKUP_CONTAINER_IDENTIFIER=iCloud.example.operator.container

`Info.plist` reads that setting through
`RoomScanStudioCloudBackupContainerIdentifier`. A blank value or an unresolved
`$(...)` placeholder is treated as **Not configured**; the app never falls
back to `CKContainer.default()`.

Before a real-device validation, the operator must separately provision the
matching private CloudKit container/entitlement/profile in the Apple developer
and CloudKit dashboards. Those external settings are deliberately not added to
this source scaffold.

## Bounded behavior

An explicit backup creates one immutable full-project ZIP snapshot and one
private custom-zone record (`RoomScanStudioBackupsV1`, type
`RSSProjectBackupV1`) with one `CKAsset`. It is a manual recovery mechanism,
not background sync, subscriptions, simultaneous editing, CKSyncEngine,
iCloud Documents, or a source-of-truth migration. The content-addressed record
is idempotent only when its archive and manifest hashes match.

Local snapshots are bounded to 512 MiB and are never silently split. Apple's
current CKAsset documentation does not publish a firm per-asset maximum; older
CloudKit Web Services material references 50 MB. Development-container upload
and recovery testing must therefore establish the practical acceptance limit.

List retains at most 200 valid records and counts/skips at most 200 malformed
successful descriptors; paging stops after either cap and reports that
additional records were not loaded. A successfully fetched record whose
descriptor fails local validation is never offered for recovery. A CloudKit
per-record failure still fails the explicit List operation so account, network,
and service failures are not hidden.

Recovery validates the archive into a marker-owned isolated stage before it
can promote a package. A divergent local project fails closed unless the user
explicitly chooses **Recover as Copy**. A recovery copy rewrites package-owned
project IDs while preserving revision IDs, lineage, and asset bytes; it does
not append an edit revision.

## Required external proof

Run only after the signing/container setup above is confirmed on macOS:

    xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj -scheme RoomScanStudio
    xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -destination 'platform=iOS Simulator,name=<installed simulator>' test

Choose an installed simulator from `xcrun simctl list devices available` rather
than assuming a particular device name exists on the operator machine.

Then use a development-container, signed device test to verify: disabled and
toggle-only zero-call behavior; account availability; missing-zone listing;
explicit upload/idempotency; CKAsset size-limit handling; cancellation lookup;
download copy; exact recovery; recover-as-copy; and marker-owned scratch retry.
None of those Apple/CloudKit operations has been performed on the Windows host.

## 2026-10-01 Slice 7 container setup, backup deletion and schema notes

### (a) Create and assign the iCloud container (operator action)

1. In the Apple Developer portal (Certificates, Identifiers & Profiles →
   Identifiers → iCloud Containers), create a container, or let Xcode create
   it from the app target's **Signing & Capabilities** → iCloud → CloudKit
   section while signed in with your team.
2. Assign the container to the app's App ID (enable iCloud with CloudKit on
   the identifier and select the container).
3. Put the container identifier in your git-ignored
   `Configs/Operator.local.xcconfig` as
   `ROOMSCANSTUDIO_CLOUD_BACKUP_CONTAINER_IDENTIFIER`, and copy
   `Configs/RoomScanStudio.example-entitlements.plist` to the git-ignored
   `Configs/RoomScanStudio.local.entitlements`. The operator may choose an
   identifier such as `iCloud.org.roomscanstudio.app`; the repository never
   assigns one. See the Slice 7 operator signing channel in `Docs/setup.md`.

### (b) Backup deletion behavior

- Deletion targets the private custom zone `RoomScanStudioBackupsV1`. For a
  whole-project deletion the transport lists that zone's
  `RSSProjectBackupV1` records and keeps those whose `projectID` field matches,
  together with the record names already known to the request.
- Two entry points exist: per-record deletion from the backup list (after a
  confirmation) and whole-project deletion chosen in the Delete-now dialog.
- Records are deleted in batches of at most 400 with `atomically: false`. A
  `limitExceeded` error halves the batch size and retries. `unknownItem` and
  `zoneNotFound` count as already deleted.
- Whole-project requests are journaled at
  `Application Support/RoomScanStudio/CloudBackupDeletionJournal/`, with an
  ownership marker and one canonical JSON record per project. A record is
  removed only when an attempt reports zero remaining records; otherwise it
  keeps its attempt count and last error and stays pending.
- Deletion never runs at launch or from the Trash reaper. The reaper only
  journals a request; it stays pending until the user taps Retry or
  "Delete pending backups". Pending entries read "Backup still in iCloud".
- The app copy says Apple completes erasure on its servers later; this app
  cannot verify physical erasure.

### (c) Schema notes

- The `RSSProjectBackupV1` record type is auto-created in the CloudKit
  Development environment by the first backup from a Development-signed build.
- Deletion introduces no new Queryable index: the project listing reuses the
  existing backup-listing query shape and filters by `projectID` on the
  device.
- Deploy schema to Production in CloudKit Console before TestFlight. This is an
  operator manual step and has not been performed.

### (d) Manual proof items (operator manual, not executed)

These require a signed build with the real container on a physical device and
are tracked as unchecked items in `Docs/real-device-test-plan.md`:

- Enable Cloud Backup with the real container.
- Back up a room, then delete that backup.
- Observe the pending state, then the deleted state.
- Turn off networking, delete a backup, confirm it stays pending, then Retry
  online.
- Confirm the "still in iCloud" wording while a deletion is pending.
- Record that physical erasure is not verifiable by the app; a successful
  deletion only means CloudKit accepted it.
