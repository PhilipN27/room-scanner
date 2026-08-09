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
