---
name: roomscan-slice-acceptance
description: Collect and finalize fresh Slice 5 sync or Slice 6 publication acceptance evidence for RoomScanStudio. Use when asked for complete acceptance, closure, mutation evidence or evidence reconciliation; do not treat a component pass as release approval.
---

# Fresh slice acceptance

## Scope and inputs

Read root/Scripts/Docs instructions, the requested slice's plan and verifier,
and the latest dated evidence record. Current references:

- `Docs/superpowers/plans/2026-08-28-ai-redesign-platform-slice-5.md`
- `Docs/superpowers/plans/2026-08-30-ai-redesign-platform-slice-6.md`
- `Docs/evidence/2026-09-20-ai-redesign-slice-6-closure.md`
- `Scripts/verify_slice5_sync.py`
- `Scripts/verify_slice6_publication.py`
- `Scripts/verify_slice6_mutation_controls.py`

Confirm whether the user wants component proof or full acceptance. Use exact
Node 24.15.0, disposable PostgreSQL 16, macOS/Xcode and available iPhone/iPad
Simulators. Check resource contention/free space; allocate fresh owned paths.
Existing closure records are historical evidence, never freshly rerun results.

The native-validation and hosted-verification skills supply their long
build/test workflows. Preserve raw outputs and actual exit codes. If output is
captured through `tee`, enable `set -o pipefail`; an expected failing control
needs a separately checked failure reason, not a masked exit.

## Slice 5 workflow

1. Create the run marker **before** every component/native/artifact/review run:

   ```sh
   python3 -B Scripts/verify_slice5_sync.py --initialize-run \
     --run-marker .artifacts/slice5-new-run/run-marker.json
   ```

   Replace the example run root everywhere with a fresh one. Initialization
   refuses to overwrite a marker. Do not backdate files to pass freshness.

2. Run component and mutation oracles:

   ```sh
   python3 -B Scripts/verify_slice5_sync.py \
     --artifacts-dir .artifacts/slice5-new-run/components
   python3 -B Scripts/verify_slice5_mutation_controls.py \
     --artifacts-dir .artifacts/slice5-new-run/mutations
   python3 -B Scripts/verify_slice4_hosted.py \
     --artifacts-dir .artifacts/slice5-new-run/hosted
   ```

   Components cover full Core, service, real database sync/security/staged
   upgrade and infrastructure. They are not a whole native acceptance result.

3. Use native-validation to run both **full** schemes, the generic unsigned
   build and current compiled-app inspection after the marker. Bind those real
   paths to `iphone_xcresult`, `ipad_xcresult`, `artifact_report`.
   For current Slice 6-compatible app bytes use the Slice 6 inspector, which
   retains the required Slice 5 markers.

4. Review actual native captures at mobile-iPhone, tablet-iPad and desktop-width
   layouts for migration retry, stale-head conflict and raw-archive review.
   The desktop-width capture is the authored iPad landscape scenario, not a
   claim of a separate desktop app. Inspect exported attachments before passing
   `--review-status PASS`; the command does not perform visual review for you.

   ```sh
   python3 -B Scripts/verify_slice5_sync.py --record-screenshots \
     --mobile-xcresult "$iphone_xcresult" \
     --tablet-xcresult "$ipad_xcresult" \
     --desktop-xcresult "$ipad_xcresult" \
     --screenshots-dir .artifacts/slice5-new-run/screenshots \
     --review-status PASS \
     --output .artifacts/slice5-new-run/screenshot-review.json
   ```

   The destination must be fresh. If review fails, report it and fix/rerun;
   do not manufacture a review report or edit screenshots.

5. Finalize **last**, after the actual passing evidence exists:

   ```sh
   python3 -B Scripts/verify_slice5_sync.py --finalize \
     --run-marker .artifacts/slice5-new-run/run-marker.json \
     --component-report .artifacts/slice5-new-run/components/component-verification.json \
     --mutation-report .artifacts/slice5-new-run/mutations/mutation-verification.json \
     --slice4-report .artifacts/slice5-new-run/hosted/verification.json \
     --artifact-report "$artifact_report" \
     --screenshot-report .artifacts/slice5-new-run/screenshot-review.json \
     --iphone-xcresult "$iphone_xcresult" \
     --ipad-xcresult "$ipad_xcresult" \
     --output .artifacts/slice5-new-run/verification.json
   ```

   Read the report, not just exit zero. All eight clauses and freshness must
   pass; missing/pre-marker/count-regressed artifacts are not acceptance.

## Slice 6 workflow

1. Choose a fresh evidence root and current-source collection. The existing
   default collector is:

   ```sh
   python3 -B Scripts/verify_slice6_publication.py \
     --artifacts-dir .artifacts/slice6-new-run/collection
   ```

   It runs Node/Core/service/database/infra/web/browser/Python checks, preserving
   raw logs. Its terminal state is **COLLECTED**, not PASS. It uses the fixed
   `/private/tmp/roomscan-slice6-publication-core` scratch path; inspect ownership
   and concurrent use before running it. Do not launch concurrent collectors or
   change its sandbox policy as a casual workaround.

   You may collect the same real component commands individually when paths/
   environment require it; the aggregate validates their raw output and scoped
   freshness. Never reconstruct success logs from remembered counts.

2. Collect fresh hosted and Slice 5 compatibility with the preceding workflows.
   Collect the positive composed publication chain and deliberate skip-revoke
   failure separately using hosted-verification. Retain raw database/infra logs.

3. Produce the Slice 6 mutation report. Its CLI supports either executing the
   controls or validating existing **fresh raw** database/infra output:

   ```sh
   python3 -B Scripts/verify_slice6_mutation_controls.py \
     --artifacts-dir .artifacts/slice6-new-run/mutations
   ```

   Do not reuse historical mutation ledgers. Require detected and restored
   controls for all current guard entries.

4. Run full native iPhone/iPad schemes and generic artifact inspection through
   native-validation. Review six real native captures for room review, property
   warning and failure on both families; bind them to exact XCTest attachment
   bytes using the screenshot-manifest contract in
   `Scripts/verify_slice6_publication.py` and its test fixtures. Review the five
   browser captures required by that verifier. Keep all source/fixture bytes
   frozen while collecting evidence; changes require affected fresh reruns.

5. Assign variables below to the actual fresh artifacts, not the 2026-09-20
   paths. Source the aggregate interface from the closure record/verifier:

   ```sh
   python3 -B Scripts/verify_slice6_publication.py --aggregate \
     --artifacts-dir "$aggregate_output" \
     --core-log "$core_log" \
     --service-log "$service_log" \
     --database-log "$database_log" \
     --infrastructure-log "$infrastructure_log" \
     --web-log "$web_log" \
     --node-log "$node_log" \
     --chain-log "$chain_log" \
     --chain-red-log "$chain_red_log" \
     --browser-results "$browser_results" \
     --browser-screenshots-dir "$browser_screenshots_dir" \
     --iphone-xcresult "$iphone_xcresult" \
     --ipad-xcresult "$ipad_xcresult" \
     --generic-app "$generic_app" \
     --screenshot-manifest "$screenshot_manifest" \
     --python-log "$python_log" \
     --mutation-report "$mutation_report" \
     --slice4-report "$slice4_report" \
     --slice5-mutation-report "$slice5_mutation_report" \
     --slice5-sync-report "$slice5_sync_report"
   ```

   Collection emits separate service/web stage logs. Its `04-service-tests`
   and `08-web-tests` raw logs provide the aggregate's named-test/count evidence;
   retain the separate typecheck/build outputs as well. Check
   `_validate_service_log` / `_validate_web_log` for their exact requirements.
   The aggregate's test-log validation does not independently prove those builds.

6. Inspect `publication-verification.json`: all ten clauses, evidence records
   and scoped freshness must PASS, with no failures/incomplete entries.
   `INCOMPLETE` is a blocker. Do not lower floors, forge attachment bindings,
   change mtimes or exempt changed runtime sources to manufacture closure.

## Final evidence ledger

Append a dated record with exact commands/environment/counts, raw output paths,
SHA-256 bindings, observed red/green/restored controls, reviewed captures and
remaining gates. Explain that scoped timestamp/digest freshness is not
execution-time source attestation. A failed/interrupted run stays diagnostic.

No physical LiDAR/Face ID/passcode/Safari, live AWS/email/provider, signing,
deployment, production migration, legal/App Store or release approval follows
from local acceptance. Do not check off Slice 7, commit, publish or deploy
unless separately requested and authorized.
