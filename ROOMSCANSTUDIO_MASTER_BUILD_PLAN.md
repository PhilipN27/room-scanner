# RoomScanStudio — Master Build Plan and GPT-5.6 Sol Ultra Kickstart

This document is the complete product brief, technical plan, implementation sequence, verification standard, assumptions list, and autonomous kickstart prompt for building RoomScanStudio in a fresh GitHub repository.

The intended first user is the Norwalk YMCA team, but the app should be designed as a reusable open-source room-scanning product.

---

Rules:

1. Use GPT-5.6 Sol Ultra-level reasoning and work carefully across the entire repository.
2. Follow the ordered phases in the Markdown plan.
3. Do not invent Apple APIs, RoomPlan APIs, RealityKit APIs, or export capabilities. Verify every API against the installed SDK and official Apple documentation.
4. Do not claim LiDAR behavior works without testing it on real LiDAR hardware. Use deterministic mock fixtures for Simulator development.
5. Do not save a room profile unless the user explicitly confirms Save.
6. Preserve original room scans whenever revisions are created.
7. Treat rescanning and geometry merging as a high-risk feature. Implement safe review, accept, undo, and revert behavior. Never silently overwrite geometry or duplicate recognized objects.
8. Keep the app local-first and offline-capable. Make iCloud optional.
9. Keep large meshes, textures, photos, and scan packages file-backed rather than putting them directly into database records.
10. Do not add a server, login, remote AI processing, analytics, multi-room support, public sharing links, or collaborative editing unless this plan is explicitly revised.
11. Inspect the license and build status of any existing RoomPlan sample or GitHub project before copying or adapting code. If a license is absent or incompatible, use the project only as a reference.
12. Prefer Apple frameworks and Swift Package Manager dependencies. Check dependency licenses before adding them.
13. After every meaningful phase, build the project, run the relevant tests, report what changed, and record what was verified.
14. If a feature is blocked by an API or hardware limitation, implement the safest supported fallback, document the limitation, and continue with the remaining work.
15. Ask the user only when a true blocker requires a decision that cannot be resolved from this document or repository. Otherwise make the documented recommendation and continue.
16. Do not stop after scaffolding. Continue until the implementation, tests, documentation, and release checklist are complete or a clearly documented external blocker remains.

Start now with Phase 0: repository inspection, SDK/API feasibility, architecture checkpoint, and project scaffold.
```

---

## 2. Product objective

Build a native iPhone/iPad app that lets users create, save, inspect, revise, annotate, and export one-room LiDAR scans.

The launch screen has two primary actions:

- Existing Rooms
- New Room Scan

The product should feel like a clean, reliable room-documentation tool rather than a one-time scanning demo.

The app must support all capable LiDAR-equipped iPhones and iPads through runtime capability checks. It must not assume that a particular device model is the only supported device.

---

## 3. Locked user requirements

### Existing Rooms

Each saved room profile includes:

- Custom room name
- Capture date
- Last revised date
- Manual location text
- Optional GPS location
- Notes
- Tags
- Thumbnail
- Revision information
- Optional archive state
- Export action

Users can:

- Open a room
- Rename it
- Edit metadata
- Duplicate it
- Archive it
- Permanently delete it after confirmation
- Create revisions
- Export it
- Restore or inspect prior revisions

### New Room Scan

The scan flow must:

1. Check device capability and permissions.
2. Allow manual location entry.
3. Offer optional GPS location after permission is granted.
4. Present a dark/black scanning canvas.
5. Show the digital room gradually appearing as the user moves.
6. Provide a Start Scan action.
7. Provide a Stop Scan action.
8. Recognize structural elements and movable objects.
9. Estimate object and room dimensions.
10. Display accuracy/confidence warnings.
11. Warn about poor lighting, tracking loss, insufficient coverage, and areas needing another pass.
12. Allow the user to manually capture reference photos during scanning.
13. Allow the user to rescan previously captured areas.
14. Merge improved rescanned geometry safely.
15. Show a review state after stopping.
16. Save only after explicit user confirmation.
17. Discard the scan without creating an Existing Rooms profile if the user chooses Discard.

### Rescanning

When a user passes over an already scanned area again:

- The new capture must be registered against the existing room coordinate system.
- The app should prefer newer, higher-confidence geometry.
- It must avoid duplicating walls, doors, desks, chairs, and other objects.
- It must show a merge preview or clear merge status.
- The user must be able to Accept, Undo, or Revert.
- The original saved revision must remain available.
- Accepted changes create a new revision.

### Viewer

The saved room must support both:

- Free 3D orbit/zoom/pan viewing
- First-person walk-through navigation

Viewer controls should include:

- Pinch zoom
- Orbit
- Pan
- Reset view
- Top/front/side camera presets
- Structural-element visibility toggle
- Movable-object visibility toggle
- Measurement visibility toggle
- Annotation visibility toggle
- Reference-photo visibility toggle

### Editing

Users can edit:

- Walls
- Floors
- Ceilings
- Doors
- Windows
- Openings
- Desks
- Chairs
- Tables
- Other recognized objects

Users can:

- Rename an object
- Change its category
- Adjust dimensions
- Move it
- Rotate it
- Delete it
- Add a manual object
- Add notes
- Add pinned annotations

Structural elements and movable objects must be visually and semantically distinct.

All dimensions must include an accuracy disclaimer. The app should never imply survey-grade accuracy.

### Storage and synchronization

- Local-first storage is required.
- The app must work offline.
- Users explicitly control whether iCloud is enabled.
- iCloud should support backup and synchronization of room metadata, revisions, and assets where practical.
- V1 does not need simultaneous multi-device editing or collaboration.
- GPS is optional and requires permission.
- If GPS permission is denied, manual location entry must continue to work.

### Export

Every saved room has an Export button using the iOS Share Sheet.

Provide a one-click Complete Project Package containing all successfully generated outputs:

- USDZ
- GLB, if supported by the chosen exporter
- OBJ plus materials/textures, if supported
- PLY or point-cloud output, if supported
- Semantic JSON
- Room metadata JSON
- Annotations
- Measurements
- PNG/JPEG floor plan
- PDF summary
- Reference photos
- Export manifest

Native formats and structured metadata have priority. Optional converters must be legally compatible, maintained, and covered by tests.

---

## 4. Recommended Apple technology stack

- SwiftUI — application interface
- RoomPlan — semantic room and object capture
- ARKit — LiDAR scene reconstruction, tracking, mesh anchors, camera pose
- RealityKit — 3D rendering, model interaction, walk-through viewer
- SwiftData — lightweight metadata, room profiles, revisions, tags, settings
- CloudKit/iCloud — optional synchronization and backup
- Core Location — optional GPS location
- Photos or app-managed image storage — reference photos
- Swift Testing and/or XCTest — unit and integration tests
- XCUITest — UI flow tests

Apple documents RoomPlan as using device sensors, trained ML models, and RealityKit to identify room structures and objects. ARKit scene reconstruction supplies a polygonal mesh estimate of the physical environment. The app should preserve both the semantic layer and the richer reconstructed mesh layer.

References:

- [Apple RoomPlan](https://developer.apple.com/documentation/roomplan)
- [Apple RoomPlan overview](https://developer.apple.com/augmented-reality/roomplan/)
- [ARKit scene reconstruction](https://developer.apple.com/documentation/ARKit/ARWorldTrackingConfiguration/sceneReconstruction)
- [RoomPlan captured-room export](https://developer.apple.com/documentation/roomplan/capturedroom/export%28to%3Ametadataurl%3Amodelprovider%3Aexportoptions%3A%29)
- [RealityKit Entity export](https://developer.apple.com/documentation/realitykit/entity)
- [SwiftData model container](https://developer.apple.com/documentation/swiftdata/modelcontainer)
- [SwiftData and iCloud synchronization](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)

The implementation must inspect the current Xcode SDK and verify exact API availability rather than relying on this document for version assumptions.

---

## 5. Data and file architecture

Use SwiftData for small structured records and a file-backed asset store for large scan data.

Suggested model types:

```text
RoomProject
RoomRevision
RoomLocation
RoomObject
RoomStructure
RoomAnnotation
RoomPhoto
RoomExportRecord
AppSettings
```

Suggested project package:

```text
RoomProject/
├── manifest.json
├── metadata.json
├── revisions/
│   ├── revision-001/
│   │   ├── revision.json
│   │   ├── semantic-model.json
│   │   ├── mesh/
│   │   ├── textures/
│   │   ├── photos/
│   │   ├── annotations.json
│   │   └── measurements.json
│   └── revision-002/
├── thumbnails/
└── exports/
```

Keep the exact raw scan representation dependent on verified Apple APIs. If an opaque RoomPlan capture object cannot be safely persisted, store the supported serialized capture result plus the app’s own normalized semantic and mesh representations.

The original revision must be immutable. Edits and accepted rescan merges must create a new revision with a parent revision ID.

---

## 6. Repository structure

Use a modular but understandable structure:

```text
RoomScanStudio/
├── App/
├── Features/
│   ├── Home/
│   ├── RoomLibrary/
│   ├── RoomCapture/
│   ├── RoomRescan/
│   ├── RoomViewer/
│   ├── RoomEditor/
│   ├── RoomExport/
│   └── Settings/
├── Domain/
│   ├── Models/
│   ├── Protocols/
│   └── UseCases/
├── Infrastructure/
│   ├── Persistence/
│   ├── FileStorage/
│   ├── CloudSync/
│   ├── Permissions/
│   └── Logging/
├── Fixtures/
├── RoomScanStudioTests/
├── RoomScanStudioUITests/
├── Docs/
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
└── .github/
```

Use protocols such as:

```text
ScanSessionProviding
SemanticRoomCapturing
SceneMeshProviding
RescanMerging
RoomProjectStoring
RoomAssetStoring
RoomExporting
LocationProviding
PhotoCapturing
CloudBackupProviding
```

This allows simulator tests to use mock implementations.

---

## 7. Ordered implementation phases

### Phase 0 — Feasibility and scaffold

1. Inspect Xcode, SDK, deployment target options, and repository state.
2. Verify RoomPlan and ARKit APIs against the installed SDK.
3. Inspect existing RoomPlan sample repositories for reference only.
4. Check licenses before copying any code.
5. Create the Xcode project and target structure.
6. Add capability checks and a basic device-support screen.
7. Write `Docs/feasibility.md` and `Docs/architecture.md`.
8. Create a mock room fixture.

Exit criteria: clean project build and documented risks.

### Phase 1 — Local library and revisions

Implement room metadata, project packages, thumbnails, Existing Rooms, save/discard, duplication, archive, deletion, and immutable revisions.

Exit criteria: library flows work entirely with mock projects and pass tests.

### Phase 2 — Scanning

Implement permissions, dark scanning canvas, start/stop state, live reconstruction, semantic detections, structural/movable separation, quality guidance, manual photo capture, review, Save, and Discard.

Exit criteria: scan works on a real LiDAR device and discard does not create a saved profile.

### Phase 3 — Rescan merging

Implement coordinate registration, duplicate prevention, confidence comparison, merge preview, Accept, Undo, Revert, and revision creation.

Exit criteria: fixture-based merge tests pass and real-device rescan behavior is documented.

### Phase 4 — Viewer and editor

Implement orbit view, first-person view, camera controls, toggles, object editing, structural editing, measurements, annotations, and photo markers.

Exit criteria: viewer works with mock data in Simulator and with a saved real scan on device.

### Phase 5 — Export

Implement native exports first, then optional conversion formats, floor-plan images, PDF summary, semantic JSON, project ZIP, manifest generation, and Share Sheet integration.

Exit criteria: exported packages are inspectable, reproducible, and never alter the source project.

### Phase 6 — Optional iCloud

Implement opt-in CloudKit/iCloud backup/synchronization, asset handling, error states, and conflict policy.

Exit criteria: local-only mode remains fully functional and iCloud behavior is tested with a development container.

### Phase 7 — Release hardening

Run builds, tests, device tests, performance checks, permissions tests, storage checks, accessibility review, iPhone/iPad layout review, documentation, license review, and known-limitations review.

Exit criteria: README setup is complete, tests are green, real-device evidence is recorded, and unsupported behavior is clearly documented.

---

## 8. Acceptance criteria

The build is complete only when all applicable criteria are met:

- Fresh launch shows Existing Rooms and New Room Scan.
- Existing Rooms supports saved profiles and all required profile actions.
- New Room Scan presents a dark scanning canvas.
- Live digital geometry appears during movement.
- Scan can be manually started and stopped.
- Semantic objects and structural elements are represented separately.
- Dimensions and accuracy warnings are visible.
- Poor lighting and tracking problems produce actionable guidance.
- Manual reference photos attach to the room project.
- Rescans do not silently duplicate or destroy geometry.
- Rescan changes support review, accept, undo, revert, and revision history.
- Save is explicit; discard does not create a saved room.
- Original revisions remain preserved.
- Viewer supports orbit, zoom, pan, standard views, and first-person navigation.
- Structural, movable, measurement, annotation, and photo visibility toggles work.
- Objects and structural elements are editable.
- Annotations and notes can be added.
- Local-only use works without network access.
- GPS denial does not prevent manual location entry.
- Optional iCloud can be enabled without making local use mandatory.
- Export works through the iOS Share Sheet.
- Complete Project Package includes all successfully generated outputs and a manifest.
- Simulator tests use fixtures; real LiDAR behavior is tested on physical devices.
- README, license, privacy notes, and known limitations are present.

---

## 9. Testing and evidence standard

The agent must distinguish clearly between:

- Compiled but untested
- Unit-tested
- Simulator-tested
- Real-device tested
- LiDAR-tested on iPhone
- LiDAR-tested on iPad

Required tests include:

- Metadata creation and editing
- Save versus Discard
- Duplicate, archive, delete, and restore behavior
- Revision immutability
- Rescan merge fixtures
- Duplicate object prevention
- Undo/revert behavior
- Export manifest generation
- Permission denial
- GPS fallback to manual location
- Offline mode
- iCloud-disabled mode
- Mock viewer loading
- iPhone and iPad UI flows

Do not mark the project complete based only on a successful compile.

---

## 10. Explicit exclusions for V1

Do not add these unless the plan is later revised:

- Multi-room building scans
- Real-time collaboration
- Public sharing links
- User accounts
- Server-side processing
- Remote AI processing
- Automatic cloud upload without consent
- Photogrammetry-grade visual reconstruction guarantees
- Survey-grade measurement guarantees
- Automatic save of unfinished scans
- Norwalk-specific hardcoded room geometry
- Full simultaneous multi-device editing

The app should be reusable for any room, with the Norwalk YMCA Computer Lab as the first field-test scenario.

---

## 11. Known assumptions and risks requiring documentation

1. The exact minimum iOS/iPadOS version must be chosen after inspecting the installed SDK.
2. The black canvas may require a custom rendering layer rather than the default RoomPlan camera presentation.
3. Rescan merging is the highest technical risk and may require a supported fallback if arbitrary geometry replacement cannot be made reliable.
4. Texture quality, file size, and memory use may vary substantially by room and lighting.
5. Objects hidden behind furniture may not be captured.
6. Good lighting is required.
7. Dimensions may be inaccurate and must be labeled accordingly.
8. GLB, OBJ, and PLY export may require external conversion libraries.
9. iCloud backup of large scan assets may require a separate asset-transfer strategy from SwiftData metadata synchronization.
10. Any reused open-source code must pass license review.
11. The first-person viewer may need a documented collision or no-clip policy.
12. The app should not depend on a remote AI model for core capture, recognition, or viewing.

---

## 12. Norwalk YMCA first validation scenario

The first real-world validation room is the Norwalk YMCA Computer Lab.

Known room context:

- Twelve student computer stations in two six-computer desk groups.
- One podium/instructor position.
- Existing furniture should be retained.
- Wired Ethernet is intended for all computers.
- Two wall-mounted TVs are planned.
- Esports is the highest-priority use.
- Classes are the secondary use.
- Visual direction is a cool gaming room with subtle YMCA accents.

Photo/layout interpretation already confirmed:

- `IMG_9544` shows the single entry door.
- The camera is immediately to the left of the first six-computer desk, looking toward the entry door.
- A person entering sees the first computer desk on their left.
- The second six-computer desk is farther behind it along the left side of the room.
- The small light-oak table and green chair are movable furniture.
- The podium stand can be used by teachers or speakers.
- The door is not near a corner; it is approximately centered on the back/right wall.

This room is a validation scenario, not a hardcoded special case in the app.

---

## 13. Existing projects and reference guidance

Apple provides the RoomPlan framework and sample guidance, not a complete customized app for this workflow.

Potential reference projects include:

- [RoomPlanDemo on GitHub](https://github.com/BaidetskyiYurii/RoomPlanDemo)
- [OpenPlan3D Capture](https://openplan3d.com/capture)

Before reusing code:

- Inspect the repository license.
- Confirm the license permits the intended open-source project.
- Confirm compatibility with the current Xcode SDK.
- Confirm whether the project includes actual rescan merging, editable persistence, or only demonstration behavior.
- Use the project as reference only if license or build status is unclear.

---

## 14. Final delivery requirements

The completed repository must contain:

- Working Xcode project
- Source code
- Unit tests
- UI tests
- Mock room fixtures
- Architecture documentation
- Feasibility notes
- Setup instructions
- Real-device testing instructions
- Export-format documentation
- iCloud setup documentation
- Privacy documentation
- Known limitations
- License
- Contribution guidance
- Release checklist

The final agent report must state:

- What was implemented
- What was tested
- Which checks ran successfully
- Which checks require physical LiDAR hardware
- Which features remain limited or unverified
- How to run the app
- How to configure iCloud
- How to reproduce exports
- Any remaining external blockers
