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
