# Photoreal room capture roadmap (Gaussian splatting)

Goal: scan a room once and later re-enter it photorealistically — orbit or
first-person walkthrough — like stepping back into a childhood bedroom.
Decision (2026-08-10): aim straight at Gaussian splatting; the semantic
RoomPlan model remains the measurement/metadata layer, splats become the
visual layer.

## Ecosystem facts (researched 2026-08-10)

- **Apple native rendering**: WWDC 2026 (June) added 3D Gaussian splat
  rendering to RealityKit (announced with visionOS 27; API takes splat
  buffers, no fixed file format). Ships with the iOS/visionOS 27 SDK cycle
  (~Sept 2026). Until adopted: **MetalSplatter** (MIT, Swift/Metal) renders
  PLY / SPZ / .splat on iOS today.
- **Training**: open-source trainers (gsplat/nerfstudio, OpenSplat) want a
  GPU; CUDA cloud or Apple-Silicon Mac (OpenSplat has Metal support).
  nerfstudio ingests ARKit-posed captures (Record3D/Polycam style) without
  COLMAP — our capture can emit that shape directly. On-device training
  exists commercially (Scaniverse, 60–90 s, proprietary); open research
  (PocketGS, Mobile-GS @ ICLR 2026) not yet production-ready.
- **ARKit poses** are good enough at room scale with LiDAR phones
  (Polycam/Luma pattern); include LiDAR depth + confidence per keyframe to
  help initialization and scale.

## Architecture

Three decoupled stages; the capture bundle is the contract between them.

### Phase A — Capture bundle (on-device, build first)
During the existing RoomPlan scan session, additionally record:
- Keyframes: camera image (JPEG, ~1–2/s + on significant pose delta),
  ARKit pose (4x4), intrinsics, exposure metadata.
- LiDAR depth map + confidence map per keyframe (compressed).
- Sparse seed geometry: ARKit scene-mesh vertices (ARMeshAnchors) harvested
  at stop; doubles as the collision proxy for first-person mode and as a
  colored-mesh preview until a splat is trained.
- Manifest JSON: nerfstudio-compatible transforms (camera model, per-frame
  pose, intrinsics, depth file references).
Stored in the room package as evidence assets under a new
`evidence/capture-bundle/` namespace (raw-mesh evidence kind already exists
and is currently declared unavailable — flip it to present).
Battery/size budget: target < 500 MB per room; cap keyframe count, JPEG q≈0.8.

### Phase B — Splat training (pluggable backends)
Backend protocol: bundle in → `.ply`/`.spz` out, with progress reporting.
1. **B1 Export path (day one)**: "Export capture bundle" share-sheet action;
   train on a Mac (OpenSplat/nerfstudio) or any cloud GPU; "Import splat"
   pulls the result into the room package as a new revision asset.
2. **B2 In-app cloud backend**: upload bundle to a GPU service, poll, store
   returned splat. Requires infra + billing decisions — separate track.
3. **B3 On-device**: revisit when open research matures.

### Phase C — Photoreal viewer
- Integrate MetalSplatter (SPM) into RoomViewer: render the room's splat
  asset with the existing Orbit / Pan / First-person camera modes; use the
  Phase-A scene mesh for floor/collision in first-person.
- When the iOS 27 SDK ships, adopt RealityKit's native splat API behind an
  availability check; keep MetalSplatter as fallback for older iOS.
- Until a splat exists for a room, the viewer shows the colored scene mesh
  (Phase A byproduct) instead of bounding boxes.

## Immediate proof-of-experience shortcut
MetalSplatter renders any PLY splat. Before our own training pipeline
exists, an "Import splat file" button + Phase C viewer lets us validate the
whole walkthrough experience using a splat produced by any external tool
(e.g. Scaniverse) — de-risks the UX before Phase B is built.

## Sequencing
1. ✅ Phase C0 (2026-08-10): splat import + MetalSplatter viewer with orbit +
   first-person modes (`RoomSplatViewer.swift`; sidecar splat store; app min
   iOS raised 17 → 18 for MetalSplatter).
2. ✅ Phase A slice 1 (2026-08-10): `RoomCaptureBundleRecorder` records posed
   JPEG keyframes (~1.4/s, tracking-gated) during every RoomPlan scan and
   harvests the ARMeshAnchor scene mesh into a binary PLY at stop; the
   coordinator adopts the bundle into a per-project sidecar library on save
   (package-evidence formalization deferred). LiDAR depth maps per keyframe:
   still TODO. Device gate PASSED 2026-08-10: RoomPlan's own config exposes no
   ARMeshAnchors, but re-running the shared session with RoomPlan's config +
   sceneReconstruction=.mesh works (real scan: 37 keyframes, 23 anchors,
   82k vertices, 148k faces) without disturbing the scan.
3. Phase A slice 2: per-keyframe LiDAR depth + confidence; colored-mesh
   preview from keyframe projection; show bundle status in room profile.
4. Phase B1: export bundle + train on Mac/cloud GPU + import splat round-trip.
5. Phase C1: colored-mesh fallback viewer + first-person collision from mesh.
6. Phase B2: in-app cloud training (product decision: cost/hosting).
7. Adopt RealityKit native splat rendering on iOS 27 SDK.

## Sources
- https://developer.apple.com/videos/play/wwdc2026/279/ (RealityKit advances)
- https://developer.apple.com/documentation/visionos/gaussian-splats-on-visionos
- https://github.com/scier/MetalSplatter
- https://docs.nerf.studio/quickstart/custom_dataset.html
- https://github.com/xiaobiaodu/mobile-gs, https://arxiv.org/pdf/2601.17354 (on-device research)
