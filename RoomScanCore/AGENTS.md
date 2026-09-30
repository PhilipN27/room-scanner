# RoomScanCore

Applies to this tree; inherit the root guide. The package manifest is at the
repository root, not here.

## Commands and tests

- Run `swift test` from the repository root.
- Run `python3 -B Scripts/verify_xcode_scaffold.py` after changing package
  boundaries, archive contracts, fixtures or source membership.
- Full native integration is in
  `../.factory/skills/roomscan-native-validation/SKILL.md`.

## Core boundaries

- Keep production sources Foundation/standard-math only; no SwiftUI, UIKit,
  RoomPlan, ARKit, RealityKit, SwiftData, CloudKit, networking/auth clients or
  provider/database dependencies. Some macOS tests use image frameworks to
  independently inspect generated fixture bytes; that is not a source-layer
  dependency exemption.
- Use value-type Codable/Equatable/Sendable contracts, pure reducers and injected
  clocks/IDs/faults. Preserve current actor/lock ownership; do not claim
  cross-process writer safety from the same-process store lock.
- Stores validate before promotion. Keep immutable lineage, expected-head CAS,
  manifest-last writes, bounded streaming digests and marker-owned recovery.
  Revert is a new revision; stale branches remain recoverable, not merged.
- Preserve explicit schema/version compatibility and closed discriminated
  contracts. An AI Concept Set is additive media, not captured spatial truth;
  property publications contain independent rooms, not a merged coordinate space.
- Native evidence must be declared and digest-checked. Raw captures/GPS/world
  maps are not default working-set or public-publication content.

## Fixtures and regression coverage

- Tests live in `Tests/RoomScanCoreTests/`; `Fixtures/` is excluded by
  `Package.swift`, and tests load checked-in fixtures explicitly.
- Use unique owned temporary directories, cleanup via `defer`, deterministic
  inputs and failure seams. Test unchanged parent bytes/head on failed writes,
  unsafe paths/symlinks, stale callbacks and interrupted recovery.
- `Fixtures/ProfessionalSync/` archives and `HostedService/fixtures/publication/`
  are cross-runtime golden contracts. Consumers and verifiers pin their bytes.
  Do not let tests overwrite them or replace digests merely to pass.
- `testPublicationGoldenFixturesMatchExactProductionArchivesAndRelationships`
  compares the production Swift builder with checked-in service fixtures and
  prints capture values on drift. Review the contract before accepting new bytes.
