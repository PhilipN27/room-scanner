# Setup

## Evidence status

- Verified on Windows: repository structure, JSON/plist/XML parsing, icon header, and source contracts only.
- Verified on macOS CI: package resolution, 122/122 `RoomScanCore` tests, the unsigned generic iOS build, and 62 app plus 25 UI tests on each selected iPhone/iPad Simulator in run 31359458769.
- Pending external evidence: physical-device capture, CloudKit development-container operations, share handoff, and archive inspection.
- Slice 4 local implementation is complete across Node 24 service, disposable
  PostgreSQL 16, offline CDK, iOS Simulator/build/artifact and scoped static
  checks. Non-production provider/infrastructure evidence,
  physical Face ID/passcode evidence, and all production provisioning/release
  gates remain pending.

## Optional professional-service local setup

The `HostedService/` workspace is for local implementation and deterministic
evidence only. Use Node 24 (the recorded lane used 24.15.0), npm lockfiles, and
PostgreSQL 16 for disposable database integration. Do not configure an AWS,
Apple, Cognito, SES, Stripe, DNS, email, or hosting account merely to run local
tests.

    npm --prefix HostedService ci --ignore-scripts --offline
    npm --prefix HostedService test
    npm --prefix HostedService run typecheck
    npm --prefix HostedService run build

Database tests create roles/schemas/functions and therefore must target only a
fresh disposable PostgreSQL 16 cluster owned by the test operator. Prefer the
repository harness's Unix-socket-only cluster. Validate the resolved data
directory/port before execution, never supply a shared/production connection,
and confirm the postmaster and temporary root are gone afterward:

    npm --prefix HostedService/db test

Infrastructure verification consumes checked-in dummy `.invalid` values,
performs offline CDK synthesis, and inspects the emitted assembly/assets. It
must run with Node 24 explicitly on `PATH`:

    npm --prefix HostedService/infra run verify

These commands do not authorize credential creation, secret rotation,
bootstrap, provider calls, deployment, DNS changes, or customer data. At the
2026-08-19 checkpoint, the intended SBOM and manifest paths were
`.artifacts/slice4-hosted/sbom.cdx.json` and
`.artifacts/slice4-hosted/artifact-manifest.json`. The dated reconciliation
below records the subsequently emitted `slice4-hosted-final` evidence instead.

The iOS professional environment is default-off and uses a non-networking
stub/local configuration unless an explicitly reviewed environment is supplied
after professional entry. Never put database/general AWS/service-role
credentials, Cognito tokens, webhook secrets, or provider secrets into Xcode
settings, `Info.plist`, source, fixtures, or the app bundle.

## macOS prerequisites

Use a Mac with a current Xcode installation that includes an iOS 18-or-later
SDK. This repository intentionally has no committed development team,
provisioning profile, CloudKit entitlement, or container identifier. Resolve the
local package and use the shared scheme:

    xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj
    swift test
    xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

For Simulator tests, select currently available iPhone and iPad destinations;
the CI helper does this without a model/runtime assumption:

    python3 Scripts/select_simulators.py --self-test
    xcrun simctl list devices available -j

Then run the Xcode test scheme separately on one discovered iPhone UUID and
one discovered iPad UUID. The hosted workflow runs this sequence dynamically;
physical-device checks still require the release operator's Mac and devices.

## UI test isolation and launch arguments

UI tests launch with `--ui-testing --reset-local-store --use-mock-fixture`.
The first two flags together select temporary roots instead of real
Application Support data. Without both, root-token and keep flags are ignored.

For a test that spans app launches, generate a unique token and use
`--isolated-root-token=<token>` on every launch. Tokens contain 1–64 ASCII
letters, digits, underscores or hyphens; invalid tokens fall back to the
process ID. Add `--keep-isolated-root` after the first launch to preserve the
saved room and its companion roots. Launching the token again without the keep
flag resets it. Keep without a valid token is ignored.

Packages live at `tmp/RoomScanStudio-UI-Testing-Projects-<token>/<projectID>/`.
Capture scratch, mesh job records, redesign state, properties, Concept Sets
and concept-import scratch use sibling roots with the same suffix.
`IsolatedTestRoots.Kind` centralizes names and cleanup for later siblings,
including the backup-deletion journal and persistent fake-backup records.
Export and cloud-backup scratch also share the suffix, but retain their
ownership-marker-only lease recovery rather than recursively clearing them.

`launchIsolatedApp(rootToken:keepRoot:extraArguments:)` provides these flags
in `RoomScanStudioUITests`. Use the same token for all launches of a scenario;
do not reuse it between tests. Token directories can remain in Simulator tmp
until the device is erased. Non-kept isolated launches sweep known-prefix
directory siblings older than 60 minutes, excluding their current roots,
symlinks, regular files and unrelated names. This is test-only cleanup, not
production data retention.

Kept token roots (`RoomScanStudio-UI-Testing-*-<token>`) therefore accumulate
in the Simulator's tmp until a later non-kept launch sweeps them after 60
minutes or the Simulator is erased. That is acceptable because each root holds
only synthetic fixture data inside the Simulator sandbox, and keeping a root
alive across relaunches is the point of the relaunch proofs.

`--trash-clock=<epochSeconds>` replaces both the project store clock and the
Trash reaper clock with that fixed time. It is honored only in isolated
`--ui-testing --reset-local-store` runs; otherwise both use the system clock.
Relaunching a kept token with a clock at least 30 days after the trash time
proves automatic purge without waiting.

`--use-fake-cloud-backup` selects the deterministic in-process backup
transport only together with `--ui-testing`. With a valid token, its records
persist in the `RoomScanStudio-UI-Testing-FakeCloudBackup-<token>` sibling so
a kept relaunch sees earlier backups; without a token they stay in memory.
`--fake-cloud-delete-fails-once` makes the first fake backup deletion fail
with a network-unavailable error, under the same two gates. The deletion
journal of an isolated run lives in the
`RoomScanStudio-UI-Testing-CloudBackupDeletionJournal-<token>` sibling.

The composed Slice 7 test
(`RoomSlice7EndToEndUITests.testSlice7PersonalReleaseEndToEnd`) uses one
token for four launches. Its concept-import step relaunches the kept token
with `--slice3-ui-fixture`, because production concept import opens the
system file picker, which XCUITest cannot drive. That fixture screen has no
picker or network boundary and persists no project companions, so it proves
the import and Concept Set screens, not a stored Concept Set import. The
other launches use the normal Home flow.

## Optional private backup configuration

Cloud backup remains disabled by default. A build operator may supply an exact
resolved `ROOMSCANSTUDIO_CLOUD_BACKUP_CONTAINER_IDENTIFIER` value through their
build configuration only after configuring the matching Apple capability and
development container outside this repository. Blank or unresolved `$(...)`
values intentionally report **Not configured**; the app never guesses a
container or calls `CKContainer.default()`.

## Privacy Policy URL configuration

App Store metadata and the in-app policy route require an operator-owned
Privacy Policy URL. Supply it only through the app-target build setting
`ROOMSCANSTUDIO_PRIVACY_POLICY_URL`; `Info.plist` substitutes that value into
`RoomScanStudioPrivacyPolicyURL`. The committed Debug and Release values are
blank. The app accepts only an absolute HTTPS URL with a nonempty host and no
credentials, fragment, control characters, or unresolved build-setting token.
Otherwise Settings and privacy shows **Privacy Policy not configured for this
build** and does not render a link. Do not add a guessed URL to this repository.

## Slice 4 proof and provisioning boundary — 2026-08-21

Use Node 24.15.0 for the frozen hosted workspaces. The accepted local service
result is typecheck/build plus 277/277 tests. The database proof is a disposable
PostgreSQL 16 run only: 43 commands, 53/53 integration cases, 14/14 legacy
mutations and 46/46 `0007` mutations, followed by verified cluster cleanup.
The accepted offline infrastructure result is 104/104 tests, 17/17 mutations,
nine exact declared assets and 28 inspected files. These results do not create
or configure a shared environment.

Do not bootstrap a database password, provider secret, AWS account/resource,
Cognito domain, Apple key/service identifier, SES identity, Stripe object, DNS
record, endpoint or production setting from this document. Provider proof
requires the authorization packet in
[the runbook](operations/professional-service-runbook.md); physical local-auth
proof uses the fillable worksheet in
[the device plan](real-device-test-plan.md). Local implementation is complete:
the hosted umbrella, Core, complete iPhone/iPad schemes, focused 32/8 selectors,
artifact inspection, scoped static controls and bounded Terra reviews are
recorded. The controller retains only a final diff/docs/cleanup handoff audit.
No real data, Slice 5 implementation, Slice 7 resource, commit, push, PR or
deployment is part of the local setup, and it
is not production-ready or release-approved.

The fresh hosted closure command was:

```sh
python3 -B Scripts/verify_slice4_hosted.py \
  --artifacts-dir .artifacts/slice4-hosted-final
```

It exited 0/PASS under Node v24.15.0 across 13 steps. Its exact verification,
SBOM and artifact-manifest hashes are recorded in the Slice 4 evidence ledger.

## 2026-10-01 Slice 7 operator signing channel

The committed project still names no team, signing identity, entitlements,
container or privacy-policy URL. Each app and test target configuration uses
`Configs/Operator.xcconfig` as its base configuration. That committed file
assigns nothing and contains only:

```text
#include? "Operator.local.xcconfig"
```

The optional include is silent when the local file is absent, so CI and the
unsigned commands above keep building with `CODE_SIGNING_ALLOWED=NO`.

To sign on your own Mac:

1. Copy `Configs/Operator.example.xcconfig` to
   `Configs/Operator.local.xcconfig` and fill in `DEVELOPMENT_TEAM`. Keep
   `CODE_SIGN_STYLE = Automatic` and `CODE_SIGN_IDENTITY = Apple Development`.
2. Copy `Configs/RoomScanStudio.example-entitlements.plist` to
   `Configs/RoomScanStudio.local.entitlements`. It requests CloudKit for
   `$(ROOMSCANSTUDIO_CLOUD_BACKUP_CONTAINER_IDENTIFIER)` only. The local
   xcconfig names it through `ROOMSCANSTUDIO_ENTITLEMENTS_app` and sets
   `CODE_SIGN_ENTITLEMENTS = $(ROOMSCANSTUDIO_ENTITLEMENTS_$(WRAPPER_EXTENSION))`,
   so only the app target gets entitlements. The test bundles share this base
   configuration, and a signed device build fails if they request iCloud,
   because their provisioning profiles cannot include it.
3. Set `ROOMSCANSTUDIO_CLOUD_BACKUP_CONTAINER_IDENTIFIER` to the iCloud
   container assigned to the App ID (see [iCloud setup](icloud-setup.md)), or
   leave it blank to keep Cloud Backup unconfigured.
4. Leave `ROOMSCANSTUDIO_PRIVACY_POLICY_URL` blank until a published policy
   exists. The app targets now set this value to `"$(inherited)"` so the
   local xcconfig is its only source; with no local value it is still blank.

Both local files are git-ignored (`Configs/Operator.local.xcconfig` and
`Configs/*.local.entitlements`). The scaffold verifier spares only a
`*.local.entitlements` file directly inside `Configs/` and still rejects any
other entitlements file and any team, signing or capability setting in the
project file.

The local xcconfig also applies to the unsigned commands above. With a
container identifier set and `CODE_SIGNING_ALLOWED=NO`, the app has no iCloud
entitlement, and the Check account action traps inside
`CKContainer(identifier:)`. Move `Configs/Operator.local.xcconfig` out of
`Configs/` while running the unsigned build or the Simulator schemes, so they
build the same repository configuration as CI. Put it back afterwards
(2026-10-02 evidence:
[Slice 7 personal release](evidence/2026-10-01-ai-redesign-slice-7-personal-release.md)).

Other Slice 7 release settings:

- `RoomScanStudio/Resources/Info.plist` declares
  `ITSAppUsesNonExemptEncryption` as `false`: the app uses only Apple's
  operating-system encryption (HTTPS and CloudKit).
- Both app configurations declare
  `LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"`.
  Without it, a signed Debug build crashed at launch on a physical device
  with `dyld: Library not loaded: @rpath/RoomScanCore_…_PackageProduct.framework`,
  because the binary had no `@executable_path/Frameworks` rpath for the
  embedded package framework. Unsigned builds compile either way.

A signed device run uses only this channel; never pass `DEVELOPMENT_TEAM=` on
the command line. Replace `<device-udid>` with your device identifier:

```sh
xcodebuild build-for-testing -project RoomScanStudio.xcodeproj \
  -scheme RoomScanStudio -destination 'id=<device-udid>' \
  -allowProvisioningUpdates -derivedDataPath <fresh-derived-data>
xcodebuild test-without-building -project RoomScanStudio.xcodeproj \
  -scheme RoomScanStudio -destination 'id=<device-udid>' \
  -derivedDataPath <fresh-derived-data> \
  -only-testing:RoomScanStudioUITests/<Class>/<test> \
  -parallel-testing-enabled NO -collect-test-diagnostics never
```

Uninstall the test build from the device afterward. Device runs use the
isolated `--use-mock-fixture` and `--use-fake-cloud-backup` launch arguments;
they are not LiDAR, real-iCloud or TestFlight evidence.
