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
- Do not add server, login, analytics, default cloud synchronization, or remote
  processing without a plan revision.
- Do not copy third-party code until its license and compatibility are reviewed.

## Verification

Run the host structural verifier before sharing a scaffold change:

    python Scripts/verify_xcode_scaffold.py

On macOS, run the Xcode scheme and the Swift package tests. On real LiDAR iPhone
and iPad hardware, record capture/permission/relocalization evidence separately.
A green static verifier is not Apple-platform runtime evidence.

## Release-facing changes

Preserve semantic Dynamic Type fonts, adaptive action layouts, stable
accessibility identifiers, and the fixed-dark versus paper palette roles. Run
the selector self-test after CI changes:

    python -B Scripts/select_simulators.py --self-test

Do not replace full-SHA GitHub Actions pins, hardcode a simulator model/runtime,
or add a team, entitlement, CloudKit container, policy URL, or privacy claim
without an explicit reviewed decision. Update the release checklist and
verification log with the actual evidence tier: Windows static, macOS CI, or
external/device evidence.

## Small changes

Keep changes narrow, include test coverage where behavior can be executed, and
update Docs/verification-log.md with the real command/result and evidence tier.
Do not alter historical fixture IDs or timestamps without intentionally updating
the fixture contract and its tests.
