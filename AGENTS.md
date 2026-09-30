# RoomScanStudio repository guide

## Project overview

RoomScanStudio is a native iPhone/iPad room-documentation app with authoritative
local file packages, a rebuildable SwiftData index, and optional private CloudKit
backup. `RoomScanCore` owns framework-independent domain/storage contracts.
`HostedService` is a separate TypeScript professional service, PostgreSQL schema,
offline CDK infrastructure, and lightweight publication/professional browser.
Professional sync and publication are explicit, default-off boundaries, not
prerequisites for guest/local use. Slice 6 is locally closed; that is not
deployment, physical-device, or production-release approval.

## Exact commands

Run these from the repository root. Sources: `Package.swift`, `Docs/setup.md`,
`.github/workflows/ci.yml`, and each `HostedService/**/package.json`.

| Purpose | Command |
| --- | --- |
| Structural verification | `python3 -B Scripts/verify_xcode_scaffold.py` |
| Python verifier tests | `python3 -B -m unittest discover -s Scripts -p 'test_*.py'` |
| Simulator selection self-test | `python3 -B Scripts/select_simulators.py --self-test` |
| Core tests | `swift test` |
| Resolve Xcode packages | `xcodebuild -resolvePackageDependencies -project RoomScanStudio.xcodeproj` |
| Unsigned iOS build | `xcodebuild -project RoomScanStudio.xcodeproj -scheme RoomScanStudio -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` |
| Service install | `npm --prefix HostedService ci` |
| Service tests | `npm --prefix HostedService test` |
| Service type check | `npm --prefix HostedService run typecheck` |
| Service build | `npm --prefix HostedService run build` |
| Database install / tests | `npm --prefix HostedService/db ci` / `npm --prefix HostedService/db test` |
| Infrastructure install / offline verification | `npm --prefix HostedService/infra ci` / `npm --prefix HostedService/infra run verify` |
| Web install / type check | `npm --prefix HostedService/web ci` / `npm --prefix HostedService/web run typecheck` |
| Web tests / build / browser tests | `npm --prefix HostedService/web test` / `npm --prefix HostedService/web run build` / `npm --prefix HostedService/web run test:e2e` |

Use Node **24.15.0** for the hosted verification lane and PostgreSQL **16** for
its disposable database harness. Native builds require macOS/Xcode with an iOS
18-or-later SDK; the app floor is iOS 18, Core is macOS 13/iOS 17 with Swift tools
5.9. The root package has no external dependencies; the Xcode app separately
pins MetalSplatter and its transitive packages in `Package.resolved`.

**Run the app:** use Xcode's shared `RoomScanStudio` scheme and Run action on an
available Simulator or authorized device. There is no repository `run` script.
The hosted packages expose build/test commands, not a deployed service or
`start`/`dev` command. No dedicated lint/format command is configured; do not
invent one.

## Repository map

| Path | Responsibility |
| --- | --- |
| `RoomScanCore/Sources/RoomScanCore/` | Models, reducers, immutable stores, archive/contract validation, mesh math |
| `RoomScanCore/Tests/RoomScanCoreTests/` | Package XCTest suite and checked-in contract/golden fixtures |
| `RoomScanStudio/App/`, `Features/` | Composition, SwiftUI screens, capture/viewer/editor and professional UI |
| `RoomScanStudio/Infrastructure/`, `Professional/` | Apple adapters, persistence/export, audited professional transport and journals |
| `RoomScanStudio/RoomScanStudioTests/`, `RoomScanStudioUITests/` | App XCTest and XCUITest suites |
| `RoomScanStudio/Fixtures/`, `Resources/` | Stable mock/rescan resources, asset catalog, Info/privacy manifests |
| `RoomScanStudio.xcodeproj/` | Classic PBX groups, explicit target membership, shared scheme, pinned resolution |
| `HostedService/service/` | Service contracts, authorization, composition, adapters, persistence, sync/publication workers and tests |
| `HostedService/db/`, `infra/`, `web/` | Separate npm packages with their own scoped instructions |
| `Scripts/` | Structural/evidence verifiers, compiled-app inspectors and simulator selector |
| `Docs/` | Architecture, contracts, decisions, plans, append-only evidence and operator runbooks |
| `.github/workflows/ci.yml` | Native, hosted, and Chromium CI lanes |
| `.factory/skills/` | On-demand procedures; not runtime application code |

## Conventions

- Follow the nearest scoped `AGENTS.md`; reuse existing utilities and injected
  clocks, IDs, transports and fault seams before adding dependencies.
- Read `Docs/feasibility.md` and `Docs/architecture.md` before capture/storage
  changes. Use current contracts and dated reconciliations, not an older slice's
  statement that later functionality is absent.
- Local packages are truth; SwiftData and render entities are projections.
  Preserve append-only history, staged promotion, expected-head checks and
  manifest-last updates. Never mutate a committed revision to resolve conflict.
- Keep Apple UI/capture/cloud/persistence and provider/database SDKs outside Core.
  Keep vendor types out of public contracts. Match Swift concurrency and strict
  TypeScript conventions in the affected layer.
- Add app/test sources and resources to the explicit PBX target/build phases;
  placing a file in a directory does not add it to Xcode.

## Testing rules

- Add executable regression coverage for changed behavior. New correctness or
  security guards need a failing control, passing fix and restored mutation
  evidence where applicable; do not weaken an oracle to obtain green output.
- Run the affected area's checks, then its full gate for broad changes. Native
  changes need Core tests, scaffold checks, unsigned build and full schemes on
  dynamically discovered iPhone **and** iPad Simulators.
- Static checks are not compilation; Simulator is not LiDAR/Face ID/CloudKit/
  physical share evidence; synthetic browser/offline CDK/local PostgreSQL is not
  live-provider evidence. Report failures, skips and unavailable checks plainly.
- Use `-B` for Python: the scaffold rejects `__pycache__`, `.pyc` and `.pyo`.
  Preserve fixture IDs, timestamps, byte closure and digests unless changing the
  contract deliberately with matching tests.

## Generated files

- Do not hand-edit `.build/`, `.swiftpm/`, `DerivedData/`, Xcode user state,
  `.artifacts/`, `node_modules/`, `dist/`, `.test-dist/`, `cdk.out/` or generated
  verification reports. Rebuild through the commands above and scoped guides.
- `HostedService/infra/assets/migration-manifest.json` is generated from SQL and
  the migration runner; use `npm --prefix HostedService/infra run generate:migration-manifest`.
- Lockfiles and Xcode `Package.resolved` are reviewed inputs, not disposable
  output. Golden archives, resource PNGs and retained evidence screenshots are
  checked-in contracts/evidence, not files to regenerate silently.
- Do not clean existing artifacts or user data indiscriminately. Build/test npm
  scripts replace their own output directories; keep valuable files out of them.

## Security

- Preserve zero hosted/auth initialization on guest launch, local offline use,
  separate backup/sync/publication consent, and default-off professional entry.
- Tenant authority comes from server-owned sessions and current membership,
  never caller workspace IDs, paths, object keys or advisory leases. Preserve
  forced RLS, role-specific capabilities and live portal authorization.
- Reject unsafe paths, symlinks, undeclared archive entries and source/approval
  rebinding. Cleanup requires exact ownership markers, not a filename prefix.
- Keep real room/photo/GPS data, bodies, emails, biometrics, tokens, signed URLs
  and secrets out of source, logs and evidence. Retain synthetic detector canaries.
- Database tests use only the disposable local harness. Provider calls,
  deployments, signing/capabilities, accounts, credentials, DNS/email and
  production migrations require explicit authorization. See `SECURITY.md`.

## PR expectations

- Keep the diff scoped; summarize behavior, compatibility and privacy changes,
  exact commands/results and evidence tier. Update `Docs/verification-log.md`;
  add dated reconciliations rather than rewriting historical pass counts.
- UI changes require reviewed applicable iPhone/iPad or desktop/mobile evidence,
  Dynamic Type/accessibility checks, and real screenshot/attachment bindings.
- Contract/migration/dependency changes need matching consumer tests, reviewed
  pins/licenses and fresh relevant compatibility/mutation evidence.
- Keep GitHub Actions pinned to full SHAs and simulator discovery dynamic.
  Documentation completion never implies a commit, push, PR or deployment.

## On-demand procedures

- [Native build/test/artifact validation](.factory/skills/roomscan-native-validation/SKILL.md)
- [Hosted/database/offline-infrastructure/browser verification](.factory/skills/roomscan-hosted-verification/SKILL.md)
- [Fresh Slice 5/6 acceptance and evidence finalization](.factory/skills/roomscan-slice-acceptance/SKILL.md)

These skills hold the long sequences. Keep always-on instructions here concise.
