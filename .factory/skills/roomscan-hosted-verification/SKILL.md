---
name: roomscan-hosted-verification
description: Verify RoomScanStudio professional service changes using locked Node packages, disposable PostgreSQL 16, offline CDK and synthetic browser tests. Use for service/database/infra/web changes or hosted verification requests; never deploy or configure real providers.
---

# Hosted verification

## Preconditions

Read root and applicable `HostedService/**/AGENTS.md`, current package scripts,
`Scripts/verify_slice4_hosted.py`, and `.github/workflows/ci.yml`. The command
sources are those files, not historical counts in README/runbooks.

Use exact Node 24.15.0, npm lockfiles and PostgreSQL 16. Check runtime/binary
availability and disk space first. PostgreSQL tests own fresh Unix-socket-only
clusters through `HostedService/db/test/pg-cluster.mjs`; never point them at
shared/production data. Use synthetic inputs only.

## Procedure

1. Run `node --version` and confirm `v24.15.0`. If absent, report the prerequisite;
   do not silently substitute another major/version for accepted evidence.

2. Choose the required scope:
   - A focused code change: run its actual package targets below, then the
     affected full suite.
   - Cross-boundary/schema/security/dependency change: run the hosted umbrella.
   - A whole-slice acceptance claim: use `roomscan-slice-acceptance` afterward.

3. For a clean integrated local run, choose a **nonexistent** directory under
   ignored `.artifacts/` (not a historical ledger directory):

   ```sh
   python3 -B Scripts/verify_slice4_hosted.py \
     --artifacts-dir .artifacts/hosted-verification-new-run
   ```

   Replace only the example output directory with a fresh one. The wrapper
   installs all four lockfiles, strips ambient provider configuration, checks
   the runtime, runs Python controls, service/web checks, real-role PostgreSQL,
   composed publication chain, infrastructure/mutations/synth inspection and
   guest/secret detector controls. Its name is historical; its current command
   plan includes Slice 5/6 compatibility.

   Inspect `verification.json`, raw logs, `sbom.cdx.json` and
   `artifact-manifest.json`. Stop on the first failed stage. `--skip-install`
   is supported only when the exact lockfile installs are already established.
   The umbrella does **not** run Playwright or native schemes.

4. When running packages individually, install and verify in dependency order:

   ```sh
   npm --prefix HostedService ci
   npm --prefix HostedService/db ci
   npm --prefix HostedService/infra ci
   npm --prefix HostedService/web ci

   npm --prefix HostedService run typecheck
   npm --prefix HostedService test
   npm --prefix HostedService run build

   npm --prefix HostedService/web run typecheck
   npm --prefix HostedService/web test
   npm --prefix HostedService/web run build
   npm --prefix HostedService/web run test:integration

   npm --prefix HostedService/db test
   npm --prefix HostedService/infra run verify
   python3 -B Scripts/verify_slice4_static_controls.py
   ```

   Prefer the sanitized umbrella for integrated acceptance. Direct
   infrastructure `verify` also sanitizes provider inputs; direct synth is not
   a credential-free substitute. Missing npm caches are installation blockers,
   not permission to loosen pins or invent output.

5. For publication changes, run the composed current-production-code oracle
   after service/web builds:

   ```sh
   node HostedService/db/test/integration-0009-system-chain.mjs
   node HostedService/db/test/integration-0009-system-chain.mjs --control-skip-revoke
   ```

   The first must pass. The second must **fail at the intended post-revocation
   denial assertion**, after real protected content was usable, not merely fail
   to start. Capture both exit codes/logs separately; do not chain them with
   `&&` and mistake the deliberate failure for a failed positive run.

6. For web changes, install the bounded Chromium runtime using CI's command
   from `HostedService/web`:

   ```sh
   cd HostedService/web
   npx playwright install --with-deps chromium
   npm run test:e2e
   ```

   Run this in a separate shell from root-relative commands. Installation may
   download dependencies and, on Linux, require system-package authorization;
   obtain approval if needed rather than elevating implicitly. The repository
   script builds/integrates, starts a loopback synthetic fixture, runs one
   Chromium worker without retries, and shuts down its own server.

   Review `HostedService/web/test-results/results.json` and actual captures in
   `HostedService/web/screenshots/`. Protect earlier evidence before rerunning
   because these output paths are reused. Do not overwrite reviewed baseline
   captures without a deliberate new evidence run.

## Completion and failure handling

Report exact commands, runtime, positive/negative results, cluster cleanup,
artifact digests and evidence tier. Preserve the failing oracle; fix source and
rerun the relevant positive, negative and restored controls. Update
`Docs/verification-log.md`, then check the diff for generated outputs.

No AWS/Apple/Cognito/SES/Stripe account, real credentials, email, DNS, pricing,
deployment or production migration is authorized here. Consult
`Docs/operations/professional-service-runbook.md` only as the source of
operator-gated requirements. Mobile Chromium is not physical Safari evidence.
