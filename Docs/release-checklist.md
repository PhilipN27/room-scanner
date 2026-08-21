# Release checklist

Status: **Verified on Windows** items below are static only. Checked **macOS
CI** and dated **local Xcode** items are runtime/build evidence; remaining
external and physical-device items stay unchecked until observed.

- [x] Windows static: `MARKETING_VERSION=1.0.0`, `CURRENT_PROJECT_VERSION=1`,
  app language mode Swift 5.0, package tools 5.9, 1024px opaque RGB AppIcon
  header, and required-reason privacy manifest contract parsed.
- [x] Windows static: CI workflow pins checkout/upload actions by full SHA,
  discovers iPhone/iPad simulators dynamically, and preserves xcresults.
- [x] Windows static: Dynamic Type source/test contracts, semantic contrast
  calculations, fixed-dark surface roles, and no fixed user-facing font sizes
  passed the structural oracle.
- [x] macOS CI: resolved the local package, passed 122/122 `RoomScanCore`
  tests, and built the unsigned generic iOS application with Xcode 16.4.
- [x] macOS CI: passed 62 app tests plus 25 UI tests on each dynamically
  selected iPhone and iPad Simulator in run 31359458769.
- [x] 2026-08-12 local Xcode baseline-only checkpoint: detached exact-baseline
  worktree plus baseline repairs passed 178 Core tests, 120 app + 25 UI tests
  on both iPhone and iPad Simulators, exact package resolution, and an unsigned
  generic-device build. It contains no AI redesign contract source or object.
- [x] 2026-08-12 local Xcode Slice 0 checkpoint: integrated worktree passed
  205 Core tests, 121 app + 25 UI tests on both iPhone and iPad Simulators,
  exact package resolution, and an unsigned generic-device build with the
  redesign contract object/symbols present.
- [x] 2026-08-12 Slice 0 boundary checkpoint: strict version/kind fixtures,
  raw-default and portal-archive guards, SDK declaration type-check, hosted
  ADR, threat model, and current executable guest capture/save/edit/legacy-
  export offline oracle passed. This does not close any physical or hosted
  gate below.
- [x] 2026-08-12 local Xcode Slice 1 checkpoint: 217 Core tests and isolated
  123 app + 27 UI tests on each iPhone and iPad Simulator passed; exact package
  resolution and unsigned generic-device build succeeded with Slice 1 source,
  schema strings, and readiness/store symbols present in the delivery output.
- [x] 2026-08-12 Slice 1 visual checkpoint: all eight iPhone/iPad
  light/dark/default/accessibility screenshots passed the nonblank oracle and
  visual critique. Nine semantic roles are distinguished by text, symbol,
  border/pattern, selection treatment, accessibility description, and color.
  This does not close the physical LiDAR gate below.
- [x] 2026-08-13 Slice 1 orientation-plan correction: viewer-aligned default,
  display-only Rotate/Mirror/Reset, persisted local presentation preference,
  220 Core tests, and complete 153/153 iPhone plus 153/153 iPad Simulator
  schemes passed. The readiness guard mutation failed red and passed restored.
  The owner accepted corrected physical-iPhone behavior. Physical iPad is
  waived for the present program and remains unverified.
- [x] 2026-08-13 Slice 2 local checkpoint: canonical four-dimension quality
  report, deterministic aggregation, bounded/deduplicated live coaching,
  accessible overlays, advisory Finish review, and exact explicit Save Anyway
  persistence passed focused Core/app/UI tests and both required mutation
  controls. The focused screenshot matrix retained 16 images per form factor
  across light/dark, default/accessibility Dynamic Type, live coaching, review,
  Finish/Save Anyway, and reopened persistence states.
- [x] 2026-08-13 Slice 2 final local matrix: 230/230 Core, 131/131 app unit,
  complete 160/160 iPhone Simulator, and complete 160/160 iPad Simulator
  schemes passed. Exact package resolution, unsigned device build, delivery
  inspection, selector test, golden digest, `git diff --check`, empty staged
  diff, and all non-signing static checks passed. The local `DEVELOPMENT_TEAM`
  remains intentionally uncommitted.
- [ ] Release owner: inspect AppIcon rendering, privacy report, App Store
  Connect data-use answers, permission copy, backup-container setup, and any
  required signing/capability configuration outside this repository.
- [ ] macOS/Xcode: visually inspect the compiled icon, archive the Release
  configuration, and validate signing/capabilities supplied by the release
  operator. No team/profile is committed here.
- [ ] Release owner: supply an approved absolute HTTPS Privacy Policy URL via
  `ROOMSCANSTUDIO_PRIVACY_POLICY_URL`, verify its in-app Privacy Policy link and
  App Store metadata URL, then validate the generated privacy report and App
  Store Connect answers. Do not infer legal approval from the source manifest.
- [ ] Account Holder: before distribution, choose and record either the current
  private-only empty-list rationale or the four-category disclosure (Precise
  Location, Photos or Videos, Environment Scanning, and Other User Content),
  including the Linked determination for each disclosed category.
- [ ] Review dependencies and licenses against [dependencies.md](dependencies.md)
  before adding or shipping any new package, converter, or SDK.
- [ ] Simulator/device: exercise camera and GPS denial, offline operation, and
  iCloud-disabled behavior; capture default and accessibility Dynamic Type
  screenshots on separate iPhone and iPad runs.
- [ ] Physical iPhone: complete every still-applicable protocol in
  [real-device-test-plan.md](real-device-test-plan.md). Physical iPad is waived
  for the present program and remains unverified.
- [ ] Photoreal LiDAR gate: complete all six colored-mesh checks in the real-device
  plan—0.5-source-pixel ARKit projection agreement, checkerboard bias, solid-patch
  midtones, multi-view photo comparison, matched scan health/performance, and
  minimum-device memory/cancellation—and attach the recorded evidence.
- [ ] iOS 26 background-coloring gate: complete all eight continued-processing
  checks in the real-device plan, including app switching/locking, system
  progress and cancellation, exactly-once background notifications, denied
  permission, expiration, force-quit recovery, performance/thermal recording,
  and the iOS 18-through-25 foreground fallback.
- [ ] External consumers: inspect ZIP/PDF/PNG/USDZ/share outputs and perform
  CloudKit development-container backup/recovery tests.
- [ ] AI redesign device gate: on a supported physical LiDAR iPhone,
  prove RoomPlan category mapping, entry-orientation suggestion/confirmation,
  AR camera pose/intrinsic conventions, mesh/depth/confidence availability,
  two-phase configuration, poor-tracking handling, and cleanup. SDK
  type-checking and Simulator runs do not close this gate. Physical-iPad
  behavior is owner-waived and unverified.
- [x] Slice 2 physical-iPhone owner acceptance: the owner accepts the quality
  behavior based on direct observation. Only three physical-run screenshots
  were retained, not a complete independent artifact/device-metadata matrix;
  do not treat this as independently reproduced seven-case proof. The generic
  `regions` label and repeated tracking guidance remain known limitations.
- [ ] Slice 2 physical iPad quality behavior is owner-waived for the current
  program and remains unverified. Do not check this item or make a physical
  iPad claim without a future retained device evidence set.
- [ ] AI redesign security gate: on real Face ID/passcode states, prove success,
  cancellation, failure, lockout, passcode fallback, backgrounding, enrollment
  change, and actor handoff before sensitive-action gating ships.
- [ ] AI redesign Share Sheet gate: on physical iPhone, exercise Files,
  AirDrop, an external app, completion, cancellation, error, dismissal fallback,
  and exactly-once export-lease cleanup. Physical-iPad behavior remains waived
  and unverified.
- [x] 2026-08-17 Slice 3 local/Simulator completion: 266/266 Core tests;
  complete 219/219 schemes (185 app + 34 UI) on each iPhone 16 Pro and iPad
  (10th generation) Simulator; and final focused Slice 3 UI evidence of 5/5
  per form factor. The dated evidence records deterministic AI-ready/Complete
  archive extraction/closure, authenticated finalized-package Concept automatic
  mapping, local Share Sheet lease cleanup, and the scoped production
  AIRedesign no-provider/model/auth/direct-HTTP-client control. The only known
  pre-existing static-verifier exception remains local `DEVELOPMENT_TEAM`; this
  check does not close provider, physical-device, or release-owner gates.
- [ ] Slice 3 external-provider/current-terms gate: if any provider-specific
  workflow is presented beyond offline instruction files, verify its current
  behavior, privacy/account terms, and output handling from official provider
  sources and test it separately. No provider SDK, model call, account, upload,
  or direct-chat insertion is part of this slice.
- [ ] Slice 3 physical import/share gate: on a supported LiDAR iPhone, retain
  the device/app metadata and prove sanitization/rejection, disclosure
  invalidation, Files/AirDrop/external-app share outcomes, dismissal fallback,
  exactly-once lease cleanup, loose/packaged Concept import, mapping, archive,
  delete, and source immutability. Physical iPad remains waived and unverified.
- [x] 2026-08-19 historical Slice 4 service-lane checkpoint: Node 24.15.0 clean service 205/205, focused
  provider/handler 35/35, strict typecheck/build, 14/14 route/OpenAPI parity,
  built scanner GET→POST success, Stripe media-type denial, emitted-artifact
  scan/digest, and restored Cognito challenge-issuance mutation are recorded.
  This is local evidence only.
- [x] 2026-08-19 historical accepted local-lane checkpoints: Task 1 auth domain 97/97; accepted
  PostgreSQL `0001`–`0006` real-role/RLS/pool evidence; offline infrastructure
  56/56 plus 16/16 mutations and inspected synth; iOS professional/default-off
  26/26 Simulator tests plus clean build/artifact inspection; CI tool tests
  12/12. These lane checkpoints do not declare the integrated slice complete.
- [x] Slice 4 whole local implementation: hosted umbrella, Core, complete
  iPhone/iPad schemes, focused 32/8 selectors, Simulator/generic-device
  artifact inspection and scoped static controls are recorded. The controller
  retains a final diff/docs/cleanup handoff audit.
- [x] Slice 4 whole local PostgreSQL/integration: the final `0007` catalog,
  forced-RLS/ACL, same-tenant and cross-tenant, reused-connection, reducer/race,
  failure/quarantine, staged-upgrade and restored-mutation matrix are accepted
  for the disposable local scope; this is not Data API/Aurora/provider proof.
- [ ] Slice 4 authorized non-production providers/infrastructure: prove API
  Gateway v2 byte/header/scanner behavior, Data API transactions, Aurora
  credential bootstrap/rotation, IAM/KMS/S3 constraints, Cognito custom auth,
  Apple exchange/JWT/JWKS/relay behavior, SES delivery/bounce/complaint, Stripe
  signatures/retries/order, audit export, CloudTrail, alarms and rollback
  aliases. Offline mocks/synth are not live evidence.
- [ ] Slice 4 physical iPhone security: complete Face ID/passcode success,
  cancellation, failure, lockout/fallback, no-passcode state, background/
  foreground, 299s/301s timing, Keychain prompt/cleanup, enrollment/domain-state
  change, actor handoff and MainActor callback publication. Simulator/build
  evidence cannot check this item.
- [ ] Slice 4 production/operator decisions: approve account/environment
  topology, domains, owners/on-call/escalation, credential and secret-rotation
  cadence/drill, two-person 60-minute break glass, privacy disclosures,
  backup/RPO/RTO, measured quota values, prices, signing, provisioning,
  deployment and release configuration.
- [ ] Later live gates: Slice 6 must prove immediate portal-link/protected-asset
  revocation. Slice 7 must prove production deletion/restore/backup lifecycle,
  load/pricing and release operations. Do not close them from Slice 4 evidence.
- [ ] Device/storage: complete the disk-cleanup and performance protocol in
  [storage-performance.md](storage-performance.md) with representative small
  and large room assets.

The Norwalk YMCA Computer Lab example remains deferred until the entire app is
complete. It is not a Slice 2 acceptance requirement.

Unchecked items are release gates, not implied completed work.

## 2026-08-21 Slice 4 reconciliation

- [x] Local PostgreSQL 16: Node 24.15.0, 43 commands, 53/53 integration
  cases, 14/14 legacy mutations, 46/46 `0007` mutations, seven runtime roles,
  clean disposable-cluster teardown, and `0007` SHA-256
  `c2a3af7db980d3d32933f008c17da6b68e8bdf94408e10c8bc694c5968841030`.
- [x] Local service/offline-infrastructure lanes: service typecheck/build and
  277/277 tests; route v3 with 19 routes; pre-resolution context clearing;
  infrastructure 104/104 plus 17/17 mutations; nine exact manifest assets over
  28 files; complete migration/VPC/IAM roots; no orphan/stub markers; and no
  Slice 7 resources.
- [x] Final IAM hardening: unconditional Lambda-role `kms:Decrypt` on the
  SecretsKey is absent; exact Secrets Manager `ViaService` + `SecretARN` synth
  oracle and mutation passed after an observed focused RED→GREEN repair. Live
  IAM/KMS evaluation remains in the authorized external gate.
- [x] Hosted umbrella: exact 13-step verifier exited 0/PASS under Node
  v24.15.0; CycloneDX 1.6 contains 148 components (145 libraries + three
  lockfiles); the 128-file artifact manifest passed its secret scan; exact
  verification/SBOM/manifest hashes are in the evidence ledger.
- [x] Fresh Core and full iPhone Simulator: Core passed 266/266. iPhone
  `B8FBE9EA-81AD-4134-BC1D-A67A7747271E`, iOS 26.3.1 build 23D8133, passed
  259/259 with zero failed/skipped/expected tests (225 app unit + 34 UI); its
  xcresult-manifest and exported-test hashes are in the evidence ledger.
- [x] Bounded Terra service/infrastructure and iOS/documentation reviews ended
  with no Critical or Important finding after the worksheet RVI/tcpdump fix
  and re-review. This is not certification or an independent security audit.
- [x] Full iPad: iPad (10th generation), iOS 26.3.1 build 23D8133, passed
  259/259 with zero failed/skipped/expected tests (225 app unit + 34 UI);
  xcresult-manifest and exported-tests hashes are in the evidence ledger.
- [x] Focused current-source boundaries: professional passed 32/32 and magic
  completion passed 8/8 on iPhone 16 Pro / iOS 26.3.1; exact commands, paths and
  hashes are in the evidence ledger.
- [x] Artifact/static closure: fresh Simulator build and inspector passed with
  9/9 professional and 2/2 magic symbols, the DEBUG-only physical-harness
  symbol and Face ID copy; forbidden package/vendor/domain/credential counts
  are zero. Unsigned generic arm64 Debug/Release builds passed and proved the
  harness marker/flag/type present only in Debug. Scoped static controls and
  both positive controls passed; Python passed 30/30. The full scaffold verifier
  retains exactly the documented pre-existing `DEVELOPMENT_TEAM` exception.
- [ ] Authorized provider/infrastructure evidence: complete the exact packet
  contract in
  [the professional-service runbook](operations/professional-service-runbook.md).
  Offline synthesis is not live AWS/Apple/Cognito/SES/Stripe evidence.
- [ ] Physical Face ID/passcode: complete and sign the 2026-08-21 owner
  worksheet in [the device plan](real-device-test-plan.md). Source, Simulator,
  build and DEBUG-harness presence do not check this item.
- [ ] Production provisioning/release: approve owners, accounts, cost ceiling,
  domains, credentials/rotation, alarms, privacy, measured quotas/prices,
  signing, backup/RPO/RTO, deployment and rollback. Pending by design.

Formal status: local implementation complete; local PostgreSQL
complete; provider/infrastructure external evidence pending authorization;
physical Face ID/passcode pending owner worksheet; production provisioning and
release pending by design. The repository is **not production-ready or
release-approved**. This reconciliation performed no external action, used no
real data, added no Slice 5 implementation or Slice 7 resource, and made no
commit, push, PR or deployment.
