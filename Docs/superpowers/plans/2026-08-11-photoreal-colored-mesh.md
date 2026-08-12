# Photoreal Colored-Mesh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn an immutable RoomPlan capture bundle into a visibility-correct, color-correct, deterministically charted textured mesh, while retaining a corrected vertex-color fallback and capture-safe schema-v3 recording.

**Architecture:** Platform-independent camera math, visibility, color analysis, face assignment, charting, baking, seam expansion, and cache contracts live in focused `RoomScanCore` files. The app target owns ImageIO/ARKit payload decoding, bounded frame provision, PNG/cache publication, Metal resources, and the strictly best-effort capture additions. The viewer validates a fingerprinted v3 cache, rebuilds derived assets post-capture when needed, and falls back through corrected colors, neutral mesh, then the existing semantic viewer.

**Tech Stack:** Swift 5.9, Swift Package Manager/XCTest, iOS 17, ARKit/RoomPlan, ImageIO/CoreGraphics, Metal/MetalKit, Foundation SHA-256 and atomic file APIs.

## Global Constraints

- Capture-bundle recording is always optional and best-effort. It must not fail, delay-block, reset, or materially slow a RoomPlan scan.
- The device-proven two-phase sequence that enables scene reconstruction before scene depth remains unchanged.
- Expensive analysis, image decoding, sharpness scoring, photometric calibration, visibility, and atlas generation happen after capture.
- Dynamic PBR lighting is not added; no artificial lighting, ambient occlusion, sharpening filter, or tone-mapping curve is added.
- JPEG quality remains `0.8`, the JPEG codec remains unchanged, the one-encoder-at-a-time gate remains, and the `0.7` second minimum polling interval remains.
- Original scene mesh, frame JPEGs, depth payloads, confidence payloads, and bundle manifest are immutable evidence.
- Analysis decode maximum source dimension is `1,024`; atlas maximum dimension is `4,096`; atlas chart padding is `8` pixels.
- High-confidence LiDAR rear tolerance is `0.02 m + 1%`; medium is `0.04 m + 2%`; mesh fallback is `0.03 m + 2%`.
- Calibration uses at most `4,096` samples per frame and at least `128` mutually visible samples per graph edge.
- Frame selection retains the best five candidates; chart coherence runs exactly three deterministic neighborhood passes.
- Capture pose diversity skips poses within `5 cm` and `3 degrees`, while forcing a keyframe after `2` seconds.
- Do not commit, push, or open a pull request.

## Outcome, Scope, and Exclusions

The completed local change includes all platform-independent math and baking behavior, schema-compatible app decoding, v3 derived caches, mixed textured/fallback Metal rendering, schema-v3 metadata, capture pose diversity, and physical-device documentation. It excludes Gaussian splat replacement, geometry reconstruction beyond the captured LiDAR mesh, dynamic lighting, JPEG/codec changes, and claims that require a real LiDAR-device run.

## Affected Boundaries and File Map

- `RoomScanCore/Sources/RoomScanCore/RoomMeshColoredPreview.swift`: retain binary PLY compatibility and route the legacy colorizer through corrected analysis.
- `RoomScanCore/Sources/RoomScanCore/RoomMeshProjection.swift`: camera transform, pixel-center scaling, clipping, reciprocal-depth raster, depth sampling.
- `RoomScanCore/Sources/RoomScanCore/RoomMeshFrameAnalysis.swift`: linear sRGB, sharpness, calibration graph, visibility, scores, robust fallback selection, coverage fill.
- `RoomScanCore/Sources/RoomScanCore/RoomMeshTextureBaker.swift`: face assignment, chart split/packing, atlas bake/dilation, seam-expanded mesh.
- `RoomScanCore/Sources/RoomScanCore/RoomMeshPhotorealCache.swift`: v3 settings, fingerprints, manifest validation, cache filenames.
- Matching focused files under `RoomScanCore/Tests/RoomScanCoreTests/`: red/green unit oracles.
- `RoomScanStudio/Features/RoomViewer/RoomMeshViewer.swift`: bounded ImageIO provider, depth/confidence decode, v3 cache build/reuse/publication, renderer wiring.
- `RoomScanStudio/Infrastructure/Capture/RoomCaptureBundleRecorder.swift`: optional ISO/exposure-bias schema-v3 fields and bounded pose diversity only.
- `RoomScanStudio/RoomScanStudioTests/RoomMeshViewerAppTests.swift` and `RoomCaptureBundleDepthTests.swift`: real JPEG/depth/cache/fallback/schema integration.
- `RoomScanStudio.xcodeproj/project.pbxproj`: register any new app source or test files if app logic is split.
- `Docs/real-device-test-plan.md`, `Docs/release-checklist.md`, and `Docs/verification-log.md`: device gates and local evidence.

## Ordered Implementation

### Task 1: Projection, pixel centers, clipping, and reciprocal depth

**Files:**
- Create: `RoomScanCore/Sources/RoomScanCore/RoomMeshProjection.swift`
- Create: `RoomScanCore/Tests/RoomScanCoreTests/RoomMeshProjectionTests.swift`
- Modify: `RoomScanCore/Sources/RoomScanCore/RoomMeshColoredPreview.swift`

**Interfaces:**
- Produces: `RoomMeshProjection.Camera`, `sensorToRaster(_:sensorSize:rasterSize:)`, `project(world:)`, `clipTriangleToNearPlane(_:)`, `rasterizeDepth(...)`, and `sampleDepth(...)`.
- Consumes: ARKit camera-to-world column-major arrays, column-major intrinsics, mesh positions/faces, optional packed depth/confidence.

- [ ] **Step 1: Add focused failing projection tests.** Assert `(sensor + 0.5) * destinationSize / sensorSize - 0.5` at first/last centers; identity, translated, and 90-degree rotated cameras; vertical `v = cy - fy*y/forward`; a triangle with one vertex behind `0.05 m` still covers pixels after clipping; and a `1/4/4 m` slanted triangle produces reciprocal rather than affine depth.
- [ ] **Step 2: Run `swift test --filter RoomMeshProjectionTests` and record failures caused by missing corrected APIs.**
- [ ] **Step 3: Implement finite-value validation, rigid inverse `R^T/-R^Tt`, pixel-center conversion, Sutherland-Hodgman near clipping in camera space, projection, edge-function coverage at pixel centers, and `1 / Σ(lambda/z)` depth.** Keep the near plane explicit in settings.
- [ ] **Step 4: Run the focused tests, then temporarily replace reciprocal depth with affine depth and prove the slanted-triangle test fails; restore and rerun.**
- [ ] **Step 5: Run `swift test --filter RoomMeshColoredPreviewTests` to protect PLY and existing camera behavior.

### Task 2: Linear-light color, scoring, sharpness, and robust inliers

**Files:**
- Create: `RoomScanCore/Sources/RoomScanCore/RoomMeshFrameAnalysis.swift`
- Create: `RoomScanCore/Tests/RoomScanCoreTests/RoomMeshFrameAnalysisTests.swift`
- Modify: `RoomScanCore/Sources/RoomScanCore/RoomMeshColoredPreview.swift`

**Interfaces:**
- Produces: `RoomMeshColor.sRGBToLinear`, `linearToSRGB`, linear bilinear sampling, `RoomMeshFrameQuality.sharpness`, `sampleScore`, `bestInlier`, and photometric calibration transforms.
- Consumes: projection/visibility evidence from Task 1 and bounded RGBA analysis frames.

- [ ] **Step 1: Add failing tests for black/white midpoint linear filtering (encoded result near 188, not 128), mid-gray round-trip, Euclidean-distance ranking for equal axial depth, normalized 3x3 Laplacian sharpness clamped to `[0.5, 2.0]`, saturation penalties, and a higher-weight color outlier losing to the best inlier among the best five.**
- [ ] **Step 2: Run `swift test --filter RoomMeshFrameAnalysisTests` and confirm formula-specific failures.**
- [ ] **Step 3: Implement the IEC sRGB transfer functions, linear-light filtering, squared facing divided by Euclidean distance squared, the exact multiplicative penalties, median-normalized sharpness, robust linear-color center/outlier rejection, and highest-score inlier selection.**
- [ ] **Step 4: Neutralize Euclidean distance and linear conversion one at a time, confirm their focused tests fail, restore, and rerun.**
- [ ] **Step 5: Add and pass bounded overlap-graph tests: minimum 128 overlaps, robust median log-RGB edges, anchor selection, weighted solve, ±1-stop luminance and ±0.25 log-chroma clamps, and identity/disconnected penalty.**
- [ ] **Step 6: Run all projection, analysis, and legacy colored-preview tests.

### Task 3: Confidence-aware LiDAR visibility and conservative fallback coverage

**Files:**
- Modify: `RoomScanCore/Sources/RoomScanCore/RoomMeshProjection.swift`
- Modify: `RoomScanCore/Sources/RoomScanCore/RoomMeshFrameAnalysis.swift`
- Create: `RoomScanCore/Tests/RoomScanCoreTests/RoomMeshVisibilityTests.swift`
- Create: `RoomScanCore/Tests/RoomScanCoreTests/RoomMeshCoverageFillTests.swift`

**Interfaces:**
- Produces: `RoomMeshDepthPayload`, conservative bilinear depth/confidence sampling, `RoomMeshVisibilityResult`, and `RoomMeshCoverageFiller.fill(...)`.
- Consumes: tightly packed float32 depth meters and optional uint8 AR confidence levels (`0/1/2`).

- [ ] **Step 1: Add failing fixtures for high `0.02+1%`, medium `0.04+2%`, low/missing fallback, mesh `0.03+2%`, finite-positive-only bilinear depth, minimum contributing confidence, malformed payload degradation, and mesh buffer width `min(max(depthWidth, requestedWidth), 512)`.**
- [ ] **Step 2: Run the visibility tests and confirm failures reflect the old broad `5% + 5 cm` mesh-only behavior.**
- [ ] **Step 3: Implement ordered checks and visibility factors `1.0/0.9/0.75`, using LiDAR for medium/high and corrected reciprocal mesh depth as fallback or secondary evidence.**
- [ ] **Step 4: Temporarily widen the high-confidence tolerance and confirm the boundary fixture fails; restore and rerun.**
- [ ] **Step 5: Add failing mesh-graph fill tests for same-surface short paths and rejection across sharp normals, long edges, depth discontinuities, and disconnected components.**
- [ ] **Step 6: Implement deterministic confidence-lowering propagation; exclude filled samples from calibration and retain neutral gray for unknowns. Run surrounding Core tests.

### Task 4: Coherent face assignment, deterministic charts, atlas, and seam expansion

**Files:**
- Create: `RoomScanCore/Sources/RoomScanCore/RoomMeshTextureBaker.swift`
- Create: `RoomScanCore/Tests/RoomScanCoreTests/RoomMeshTextureBakerTests.swift`

**Interfaces:**
- Produces: `RoomMeshFaceAssignment`, `RoomMeshChart`, `RoomMeshAtlas`, and `RoomMeshPhotorealMesh` containing positions, optional normals, sRGB fallback colors, UVs, normalized validity, and unchanged triangle order/winding.
- Consumes: mesh, analyzed frames, projection/visibility APIs, full-resolution RGBA chart sources supplied by the app.

- [ ] **Step 1: Add failing tests requiring all three face vertices plus centroid visibility, deterministic score ties, and exactly three neighborhood passes using `candidateScore - 0.15 * medianPositiveScore * changedNeighborCount`.**
- [ ] **Step 2: Implement candidate construction and deterministic neighborhood assignment; run tests and neutralize the coherence penalty to prove its fixture fails.**
- [ ] **Step 3: Add failing chart tests for connected components per frame, split on opposite nonzero projected winding or interior overlap beyond shared edges, stable descending bounds/frame/face ordering, deterministic skyline packing, `8`-pixel padding, `4,096` cap, and binary search for greatest fitting global scale.**
- [ ] **Step 4: Implement chart construction and packing; unresolved/oblique/too-small faces remain fallback. Run deterministic repeated-build equality tests.**
- [ ] **Step 5: Add a failing checkerboard-large-triangle test plus padding/mip tests using two adversarial chart colors.**
- [ ] **Step 6: Implement projectively correct source lookup, linear working pixels, final sRGB encoding, chart-aware dilation, and mip-safe padding; prove disabling dilation fails the mip test, restore, and rerun.**
- [ ] **Step 7: Add and pass seam expansion tests: duplicate only UV/material seams, zero UV/validity for fallback, uniform validity per triangle, and original triangle order/winding.

### Task 5: Versioned fingerprinted derived-cache contract and photoreal PLY

**Files:**
- Create: `RoomScanCore/Sources/RoomScanCore/RoomMeshPhotorealCache.swift`
- Create: `RoomScanCore/Tests/RoomScanCoreTests/RoomMeshPhotorealCacheTests.swift`
- Modify: `RoomScanCore/Sources/RoomScanCore/RoomMeshColoredPreview.swift`

**Interfaces:**
- Produces: `RoomMeshPhotorealCacheManifest`, `RoomMeshPhotorealSettings`, validation reasons, filenames `scene-mesh-photoreal-v3.{json,ply}` and `scene-mesh-photoreal-v3-atlas.png`, plus PLY `texture_u`, `texture_v`, `texture_valid` properties.
- Consumes: SHA-256 source mesh/manifest, ordered frame filename/size/modification-date records, atlas metrics, and all result-affecting settings.

- [ ] **Step 1: Add failing round-trip tests for seam-expanded PLY and cache fixtures for version, source hash, frame metadata, settings, missing asset, malformed manifest, and atlas optionality.**
- [ ] **Step 2: Run `swift test --filter RoomMeshPhotorealCacheTests` and confirm missing v3 behavior.**
- [ ] **Step 3: Implement Codable canonical settings/manifest, exact validation, and backward-compatible PLY scalar parsing/writing. Never accept `scene-mesh-colored.ply` as v3.**
- [ ] **Step 4: Change a fingerprint/settings input and prove the cached result is rejected; restore expected input and prove acceptance.**
- [ ] **Step 5: Run the complete `swift test` RoomScanCore suite.

### Task 6: Bounded app decoding, depth compatibility, baking, and atomic publication

**Files:**
- Modify: `RoomScanStudio/Features/RoomViewer/RoomMeshViewer.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/RoomMeshViewerAppTests.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/RoomCaptureBundleDepthTests.swift`
- Modify: `RoomScanStudio.xcodeproj/project.pbxproj` only if viewer code is split.

**Interfaces:**
- Produces: a bounded frame provider that decodes 1024px sRGB analysis images one at a time, releases them between passes, loads full-resolution selected-chart sources by batch, validates/decompresses schema-v2 depth/confidence, writes PNG/PLY assets atomically, and publishes the manifest last.
- Consumes: v1/v2/v3 bundle manifests and Core Tasks 1–5.

- [ ] **Step 1: Extend app integration tests with real JPEG and compressed depth/confidence fixtures, malformed-depth RGB survival, v3 cache create/reuse/invalidation, atlas presence, and vertex-only fallback. Run selected tests and record red failures.**
- [ ] **Step 2: Implement a callback/provider pass model so no array retains all RGBA frames; tag CoreGraphics contexts with `CGColorSpace(name: CGColorSpace.sRGB)`, cap analysis at `1,024`, and decode selected atlas sources only for the current chart batch. Add cancellation checks between frames/batches.**
- [ ] **Step 3: Validate compression/pixel-format/dimensions/byte counts with overflow-safe arithmetic, decode little-endian float32 depth and optional uint8 confidence, and degrade malformed/missing payloads to mesh visibility without discarding JPEGs.**
- [ ] **Step 4: Integrate analysis, corrected fallback, calibration, face assignment, atlas baking, and reassignment/fallback after decode failure. Run selected app tests.**
- [ ] **Step 5: Write assets to same-directory temporary names, move/replace complete assets, and publish the v3 manifest last; cancellation or failure must leave no accepted partial cache. Preserve all source evidence.**
- [ ] **Step 6: Run selected app tests twice to prove first-build and reuse behavior; mutate a copied source JPEG/manifest setting and prove invalidation.

### Task 7: sRGB Metal textured/fallback renderer, mipmaps, filtering, and MSAA

**Files:**
- Modify: `RoomScanStudio/Features/RoomViewer/RoomMeshViewer.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/RoomMeshViewerAppTests.swift`

**Interfaces:**
- Produces: seam-expanded GPU vertices (position, normal if present, sRGB fallback bytes, UV, coverage), sRGB atlas texture, complete mip chain, sampler, and selected sample count.
- Consumes: v3 mesh and optional atlas from Task 6.

- [ ] **Step 1: Add source/contract tests for vertex attributes, `room_mesh_textured_fragment`, fallback sRGB decode, `.rgba8Unorm_srgb` atlas, `.bgra8Unorm_srgb` target, mip generation, trilinear filters, anisotropy, and 4×/2×/1× selection. Run selected tests red.**
- [ ] **Step 2: Implement shader linear output: covered fragments sample the sRGB texture; fallback bytes are decoded with the explicit sRGB transfer function. Do not apply lighting.**
- [ ] **Step 3: Load atlas with an sRGB Metal format, allocate mip levels, generate mipmaps, use linear mag/min plus linear mip filtering and supported anisotropy.**
- [ ] **Step 4: Select `4`, else `2`, else `1` using `supportsTextureSampleCount`; set both MTKView and pipeline sample count consistently. Keep depth32 float and culling disabled.**
- [ ] **Step 5: Run app tests and a generic device compile to catch Metal/resource wiring.

### Task 8: Capture schema v3 metadata and pose diversity without tick work

**Files:**
- Modify: `RoomScanStudio/Infrastructure/Capture/RoomCaptureBundleRecorder.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/RoomCaptureBundleDepthTests.swift`
- Modify: `RoomScanStudio/RoomScanStudioTests/AppleCaptureDependencyTests.swift` if needed for source-level ordering assertions.

**Interfaces:**
- Produces: schema version `3`, optional numeric `iso` and `exposureBias`, and pure pose-selection helper state.
- Consumes: existing `ARFrame.exifData`, camera transform, timestamp, one-encoder gate, and proven reconstruction/depth sequence.

- [ ] **Step 1: Add failing compatibility tests: v1/v2 decode with nil metadata, v3 round-trip, nonnumeric metadata ignored, and pose cases inside/outside `5 cm`/`3°` with forced acceptance after `2 s`.**
- [ ] **Step 2: Implement optional Codable fields and a pure bounded pose predicate. Copy only numeric metadata and pose scalars on the capture actor; perform no image analysis, added encoding, blocking synchronization, or await in `captureTickIfReady`.**
- [ ] **Step 3: Preserve JPEG `0.8`, codec, one-encoder gate, `0.7 s` interval, and update the last accepted pose only after the record succeeds. Run focused tests.**
- [ ] **Step 4: Inspect the diff around `beginSceneReconstructionEnablement` and prove its mesh-first, wait-for-anchor, sceneDepth-second ordering is byte-for-byte unchanged.

### Task 9: Graceful fallbacks and physical-device documentation

**Files:**
- Modify: `RoomScanStudio/Features/RoomViewer/RoomMeshViewer.swift`
- Modify: `Docs/real-device-test-plan.md`
- Modify: `Docs/release-checklist.md`
- Modify: `Docs/verification-log.md`

- [ ] **Step 1: Add/extend tests for fallback order: valid textured cache; corrected vertex-only v3; neutral mesh after derived failure; existing semantic viewer when bundle/mesh is absent.**
- [ ] **Step 2: Implement the narrow fallback branches and user-facing status without accepting partial/mismatched caches.**
- [ ] **Step 3: Document the six required physical-device gates verbatim in operational form, including 0.5-source-pixel projection comparison, color bias/midtones, photo comparison, scan health/yield/size/CPU/thermals/duration, and minimum-device memory/cancellation.**
- [ ] **Step 4: Mark ARKit registration, scan-health performance, thermal behavior, and photo-level quality as unproven until a real LiDAR-device run.

### Task 10: Fresh verification and delivery inspection

**Files:**
- Modify: `Docs/verification-log.md` with dated command evidence and limitations.

- [ ] **Step 1: Invoke `superpowers:verification-before-completion` and reread its complete instructions.**
- [ ] **Step 2: Run every focused regression filter used above and retain red/green evidence, including restored-guard reruns.**
- [ ] **Step 3: Run `swift test` for the complete RoomScanCore suite.**
- [ ] **Step 4: Run relevant RoomScanStudio tests on an available iOS Simulator, then the full simulator test target.**
- [ ] **Step 5: Run `xcodebuild ... -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.**
- [ ] **Step 6: Inspect the built product/library strings for `room_mesh_textured_fragment`, `scene-mesh-photoreal-v3`, `texture_valid`, and schema version 3 metadata keys.**
- [ ] **Step 7: Run `git diff --check`, inspect the full `git diff`, and run `git status --short`; preserve unrelated changes and report all changed files.**
- [ ] **Step 8: Record simulator/service or device-only limitations exactly; do not convert an unavailable oracle into a passing claim.

## Rollback Strategy

The source rollback is confined to the new Core units and the viewer/capture integrations. At runtime, deleting `scene-mesh-photoreal-v3.json`, `.ply`, and `-atlas.png` forces safe recomputation; no bundle migration or original-evidence rollback is needed. Until physical-device gates pass, the renderer retains corrected vertex-color, neutral mesh, and semantic viewer branches, while the old `scene-mesh-colored.ply` may remain only as an export/splat seed and is never trusted as v3.

## Risks and Mitigations

- **Memory pressure:** provider-scoped 1024px analysis and chart-batch full-resolution decoding; cancellation checks between bounded units.
- **Projection/occlusion regression:** isolated math APIs, rotated-camera fixtures, reciprocal-depth negative control, and device comparison gate.
- **Color double conversion:** explicit sRGB tags and linear working values, one shader/texture decode, one sRGB render-target encode.
- **Nondeterministic caches:** stable sorting/ties, fixed three passes, canonical settings, deterministic skyline packing, and repeat-build byte equality tests.
- **Partial caches:** assets written atomically and manifest published last; strict manifest/fingerprint/settings validation.
- **Capture regression:** only scalar metadata/pose copying in tick; no changed codec/quality/order; physical scan-health gate remains mandatory.
- **Atlas seams/mips:** eight-pixel chart-aware dilation, complete mip chain, and adversarial bleed fixtures.
- **Simulator limitations:** Core tests remain host-runnable; app/build gates use Xcode with sandbox escalation if required; physical claims remain explicitly gated.

## Exact Completion Oracles

Completion requires: every focused formula/guard regression observed red before implementation and green after restoration; complete `swift test` green; relevant and full RoomScanStudio simulator tests green; generic unsigned iOS build green; built product contains textured-shader and v3-cache symbols; `git diff --check` green; final diff/status reviewed; documentation lists all device-only gates. A real LiDAR-device run is not locally actionable and is reported as pending, never as passed.
