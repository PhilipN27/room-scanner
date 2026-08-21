# Contributing

Thank you for improving RoomScanStudio.

## Before changing capture, persistence, or export

Read Docs/feasibility.md and Docs/architecture.md. Preserve the local-first,
one-room scope and do not claim Apple framework behavior without the appropriate
SDK, Simulator, or physical-device evidence.

- Keep the project package append-only and retain original revisions.
- Treat rescans as reviewed semantic proposals. Reject ambiguous or unregistered
  candidates instead of guessing.
- Do not use device-model checks for RoomPlan/ARKit capability.
- Keep guest/local workflows independent of login, remote configuration,
  hosted initialization, analytics, default cloud synchronization, and remote
  processing. The only approved server/account surface is the optional,
  default-off professional boundary documented in ADR 0001/0002 and the Slice
  4 service contract; expanding it requires a plan/contract revision.
- Keep vendor SDK/database types outside `RoomScanCore` and public contracts.
  Tenant scope is always server-derived from an app-owned session and current
  membership; never add a caller workspace path or object-key authority.
- Do not copy third-party code until its license and compatibility are reviewed.

## Verification

Run the host structural verifier before sharing a scaffold change:

    python Scripts/verify_xcode_scaffold.py

On macOS, run the Xcode scheme and the Swift package tests. On real LiDAR iPhone
and iPad hardware, record capture/permission/relocalization evidence separately.
A green static verifier is not Apple-platform runtime evidence.

For professional-service changes, use Node 24 and run the affected focused
tests plus the clean service/database/infrastructure matrices. At minimum:

    npm --prefix HostedService test
    npm --prefix HostedService run typecheck
    npm --prefix HostedService run build

Database tests require an explicitly disposable local PostgreSQL 16 target;
do not point them at shared or production data. Infrastructure verification is
offline synthesis/artifact inspection and is not deployment authorization.
Record red→green and restored mutation evidence for new correctness/security
guards, and preserve exact provider/body/secret log canaries.

## Release-facing changes

Preserve semantic Dynamic Type fonts, adaptive action layouts, stable
accessibility identifiers, and the fixed-dark versus paper palette roles. Run
the selector self-test after CI changes:

    python -B Scripts/select_simulators.py --self-test

Do not replace full-SHA GitHub Actions pins, hardcode a simulator model/runtime,
or add a team, entitlement, CloudKit container, provider account, credential,
endpoint, policy URL, price/quota value, or privacy claim without an explicit
reviewed decision and any required external-action authorization. Update the release checklist and
verification log with the actual evidence tier: Windows static, macOS CI, or
external/device evidence.

## Small changes

Keep changes narrow, include test coverage where behavior can be executed, and
update Docs/verification-log.md with the real command/result and evidence tier.
Do not alter historical fixture IDs or timestamps without intentionally updating
the fixture contract and its tests.

## Slice 4 evidence records

Treat dated Slice 4 reports as an append-only evidence ledger. Do not replace an
older count with a newer result in a way that makes the earlier checkpoint look
as though it never occurred. Add a dated reconciliation that names the exact
command, environment, count, artifact path/digest and limitation. A local test,
Simulator run, disposable database run or offline synth never checks an
external-provider, physical-device or release checkbox.

As of 2026-08-21, local implementation and disposable PostgreSQL are complete:
the hosted umbrella, Core, complete iPhone/iPad schemes, focused 32/8 selectors,
artifact inspection and scoped static controls are recorded. The controller
retains a final diff/docs/cleanup handoff audit. Provider evidence requires separate
authorization; physical Face ID/passcode requires the owner worksheet;
production provisioning and release approval remain pending by design. Do not describe the repository
as production-ready, add Slice 5 or Slice 7 implementation under this record,
or infer any commit, push, PR or deployment from documentation evidence.
