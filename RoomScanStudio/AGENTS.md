# Native app

Applies to this tree; inherit the root guide. Build from the repository root
with the shared `RoomScanStudio` scheme. The app uses iOS 18 and Swift language
mode 5; Core remains the root local Swift package product.

## Verification and run

- Run `python3 -B Scripts/verify_xcode_scaffold.py` and `swift test`.
- Use the root unsigned Xcode build command; run both complete iPhone/iPad
  schemes using `../.factory/skills/roomscan-native-validation/SKILL.md`.
- Run interactively through the shared Xcode scheme. Use supported physical
  LiDAR hardware for capture evidence; a simulated fixture is not a real scan.

## Ownership and platform rules

- `App/` composes dependencies; `Features/` presents state; `Infrastructure/`
  owns Apple adapters; `Professional/` owns lazy professional entry, unlock and
  audited transport. Keep UIKit/CloudKit/provider work out of Core and views.
- New sources/tests/resources need explicit groups, file references and correct
  build-phase membership in `../RoomScanStudio.xcodeproj/project.pbxproj`.
- Gate live capture with `RoomCaptureSession.isSupported`, not device models.
  Keep one capture camera/AR-session owner. Optional mesh capability is not a
  second RoomPlan gate. Scratch stays outside authoritative `Projects`.
- Keep the saved semantic viewer non-AR. Render boxes/entities are disposable,
  not measurements or captured mesh truth. Do not infer live rescan registration
  from a fixture or revive coordinate continuity after a privacy stop.
- Save is explicit and its committing phase non-cancelable; pre-Save Discard
  must not allocate a package. Stale attempt callbacks cannot mutate a new attempt.
- SwiftData stays an index with `groupContainer: .none`,
  `cloudKitDatabase: .none`. Private backup uses an operator-supplied container
  and explicit actions, not launch/toggle calls or `CKContainer.default()`.
- Construct professional clients only after explicit entry. Keep publication
  separate from sync, exact review/source bindings intact, and journal cleanup
  ownership-proven. Guest/default-off composition must remain zero-network.

## UI and fixtures

- Follow `../.impeccable.md` and `App/AppTheme.swift`: semantic adaptive paper/
  ink roles, fixed-dark instrument surfaces, existing typography and
  `AdaptiveActionRow`/`ViewThatFits`, not fixed-width action groups.
- Preserve stable accessibility identifiers, semantic Dynamic Type fonts,
  VoiceOver order, 44-point targets, dark/high-contrast and Reduce Motion behavior.
- Tests live in `RoomScanStudioTests/` and `RoomScanStudioUITests/`. Keep mock
  capture, fake backup and screenshot scenarios synthetic and isolated from
  real user roots. Professional visual fixtures remain DEBUG/Simulator-only.
- Keep MockRoom-v1/RescanFixture-v1 IDs/timestamps and resource membership stable.
  Never represent their PNG or unavailable evidence as physical capture.
- Do not add a team, entitlement, container, endpoint or privacy-policy URL as
  a build fix. Release/CloudKit/signing decisions require operator approval.
