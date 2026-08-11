# Photoreal Colored-Mesh Pipeline Design

Date: 2026-08-11
Status: approved for implementation planning

## Outcome

RoomScanStudio will turn a RoomPlan capture bundle into a color-correct,
visibility-correct textured mesh whose appearance is as close as the captured
photographs permit. The implementation will also retain a corrected
per-vertex-color fallback for bundles or devices that cannot produce a usable
texture atlas.

The work covers projection and depth correctness, linear-light color
processing, robust frame selection, confidence-aware LiDAR occlusion,
photometric normalization, cache invalidation, higher-resolution streamed
decoding, atlas generation, mipmapped Metal rendering, MSAA, and conservative
coverage filling.

## Constraints and non-goals

- Capture-bundle recording is always optional and best-effort. It must not
  fail, delay-block, reset, or materially slow a RoomPlan scan.
- The device-proven two-phase sequence that enables scene reconstruction
  before scene depth remains unchanged.
- Expensive analysis, image decoding, sharpness scoring, photometric
  calibration, visibility, and atlas generation happen after capture.
- This change does not replace Gaussian splatting or claim that a coarse LiDAR
  mesh can reproduce geometry absent from the scan.
- Dynamic PBR lighting is not added. Camera images already contain lighting;
  applying another lighting model would double-light the room.
- JPEG quality and codec are not changed until a physical-device gate proves
  that encoding cost, keyframe yield, bundle size, mesh-anchor health, and scan
  completion remain acceptable.
- The original scene mesh and captured frames remain immutable evidence. Every
  derived file is disposable and reproducible.

## Approaches considered

### Selected: corrected fallback plus cached texture atlas

Correct the existing vertex colorizer, use it as a reliable fallback, and add
a charted texture atlas rendered per fragment. This removes the low-frequency
ceiling while keeping graceful degradation and a straightforward rollback.

### Rejected as the final design: subdivision only

Adaptive subdivision fits the current PLY and renderer with less code, but it
multiplies projection work and still lacks source-image detail, mipmaps,
anisotropic filtering, and stable material boundaries. It is not worth adding
as a second permanent representation once an atlas exists.

### Rejected for this change: splat-only rendering

Splats remain the long-term photoreal layer, but relying on them would leave
the capture-bundle fallback mathematically wrong and would require external
training. This design fixes the local viewer independently.

## Architecture

The pipeline has four bounded units:

1. `RoomMeshProjection` owns camera transforms, pixel-coordinate conventions,
   projection, near-plane clipping, reciprocal-depth rasterization, and image
   and depth-map coordinate conversion.
2. `RoomMeshFrameAnalysis` owns decoded frame metadata, sharpness,
   photometric calibration, visibility decisions, and sample scoring.
3. `RoomMeshTextureBaker` owns coherent face-to-frame assignment, chart
   construction, atlas packing, raster baking, dilation, mip-ready output, and
   fallback vertex colors.
4. `RoomMeshRenderCoordinator` owns the immutable GPU representation and
   chooses textured or vertex-color rendering from the derived cache.

Platform-independent math and baking data structures stay in RoomScanCore.
ImageIO, ARKit payload decoding, texture creation, and Metal stay in the app
target.

## Derived-cache contract

Derived output moves from the unversioned `scene-mesh-colored.ply` check to a
versioned cache set:

- `scene-mesh-photoreal-v3.json`: cache manifest.
- `scene-mesh-photoreal-v3.ply`: seam-expanded positions, normals, corrected
  sRGB fallback colors, `texture_u`/`texture_v`, and a normalized
  `texture_valid` vertex property. Vertices on textured/fallback boundaries
  are duplicated so all three vertices of a triangle have the same validity.
  Fallback vertices store zero UV and zero validity.
- `scene-mesh-photoreal-v3-atlas.png`: sRGB atlas when atlas coverage is usable.

The cache manifest records:

- algorithm version;
- SHA-256 of the source scene mesh and bundle manifest;
- source frame filenames, byte sizes, and modification dates;
- atlas size, covered-face count, covered-area estimate, and color-space tag;
- projection, visibility, and selection settings that affect the result.

Any missing file, parse failure, unsupported version, source-fingerprint
mismatch, or settings mismatch causes safe recomputation. The old colored PLY
may still be exported as a splat seed, but it is never accepted as the viewer's
v3 cache. Cache writes remain atomic and best-effort.

## Projection and pixel coordinates

Transforms remain ARKit camera-to-world, column-major, with camera `x` right,
`y` up, and `-z` forward. Intrinsics remain column-major sensor-pixel values.
The rigid inverse is `R^T` and `-R^T t`.

Raw sensor projection is:

```
forward = -camera.z
u = cx + fx * camera.x / forward
v = cy - fy * camera.y / forward
```

Pixel coordinates are represented as pixel-center coordinates. Scaling from a
sensor raster to a destination raster uses centered-resize geometry:

```
destination = (sensor + 0.5) * destinationSize / sensorSize - 0.5
```

The implementation will isolate this transform and test it independently.
Because ARKit's exact subpixel convention must ultimately be compared with a
real `ARCamera`, the release gate includes an on-device comparison against
`ARCamera.projectPoint` in native sensor orientation.

Triangles that intersect the near plane are clipped before projection rather
than discarded. Screen-space triangle coverage continues to use edge
functions, but camera-axis depth is recovered from linearly interpolated
reciprocal depth:

```
forward = 1 / (lambda0 / z0 + lambda1 / z1 + lambda2 / z2)
```

## Visibility and recorded LiDAR depth

`RoomMeshKeyframeSample` gains optional tightly packed depth and confidence
arrays plus their dimensions. The app loader validates and decompresses schema
v2 payloads. A malformed or missing payload degrades to mesh-only visibility;
it never invalidates the RGB frame.

Each projected sample is checked in this order:

1. finite transform, positive clipped depth, and image bounds;
2. positive normal-facing cosine when a valid normal exists;
3. recorded LiDAR depth when confidence is medium or high;
4. corrected mesh self-depth as fallback or secondary consistency evidence.

Depth comparisons use camera-axis meters. High-confidence LiDAR uses a
`0.02 m + 1%` rear tolerance; medium confidence uses `0.04 m + 2%`. Low or
missing confidence does not hard-reject a color sample. Mesh fallback begins
at `0.03 m + 2%`; it may be widened only by an explicit tested setting.

Depth is bilinearly sampled only from finite positive neighbors. Confidence is
sampled conservatively as the minimum contributing level. Confidence affects
visibility trust, not RGB quality weight. The mesh buffer defaults to at least
the recorded depth-map width instead of 160 pixels and is capped at 512 pixels
wide to control CPU cost.

## Color and photometric contract

Decoded JPEG bytes are explicitly tagged sRGB. Every RGB sample is converted
to linear sRGB before bilinear interpolation, calibration, outlier rejection,
or averaging. Final fallback PLY bytes and atlas pixels are encoded to sRGB.

Metal treats fallback vertex bytes as sRGB data and decodes them to linear in
the shader. Atlas textures use an sRGB Metal pixel format, which performs the
decode during sampling. Fragment output is linear and the
`bgra8Unorm_srgb` render target performs exactly one encode for display.

Photometric normalization uses a bounded overlap solve:

- At most 4,096 stable, well-facing, unsaturated mesh samples are used per
  frame for calibration.
- Frame-pair edges require at least 128 mutually visible samples.
- Each edge estimates robust median log-RGB ratios after outlier rejection.
- A weighted least-squares frame graph is anchored to the sharp frame with the
  greatest reliable overlap.
- Luminance adjustment is clamped to plus or minus one stop and each
  log-chromatic adjustment is clamped to plus or minus 0.25 natural-log units.
- Disconnected or underconstrained frames retain identity calibration and a
  score penalty.

`exposureDuration` is retained as diagnostic metadata, not treated as a full
exposure value. Capture-bundle schema v3 adds optional numeric ISO and
exposure-bias fields read from `ARFrame.exifData`; reading those small values
must remain nonthrowing and must not add image work to the capture actor.

## Frame quality and robust selection

Each decoded frame receives a luminance sharpness score computed as normalized
variance of a 3x3 Laplacian over the analysis image. Scores are divided by the
median nonzero frame score and clamped to `[0.5, 2.0]`. Color sample quality is:

- squared positive facing cosine;
- inverse Euclidean distance squared, not camera-axis depth squared;
- normalized sharpness;
- a visibility factor of `1.0` for high-confidence LiDAR, `0.9` for
  medium-confidence LiDAR, and `0.75` for mesh-only visibility;
- a `0.25` penalty for a channel in the bottom or top two encoded values;
- a `0.75` penalty for a frame disconnected from photometric calibration.

The base score is `facing^2 * sharpness / euclideanDistance^2`; the remaining
factors multiply that base score.

The vertex fallback keeps the best five samples, rejects color outliers in
linear light around a robust center, and selects the highest-quality inlier.
It does not average every accepted frame.

Atlas frame assignment is performed per face. Candidate frames must see all
three vertices and pass visibility at the face centroid. Initial assignment
uses the best aggregate score. Exactly three deterministic neighborhood passes
maximize `candidateScore - 0.15 * medianPositiveScore * changedNeighborCount`,
producing coherent connected charts without an unbounded optimizer. Ties are
resolved by frame order so the cache is deterministic.

## Streaming and source resolution

The loader no longer retains every RGBA keyframe simultaneously. It decodes
and analyzes frames through a bounded provider that releases image storage
after each pass.

- Vertex fallback and calibration use a maximum source dimension of 1,024.
- Atlas baking may request full-resolution source regions from the selected
  frame; only the frames needed by the current chart batch remain decoded.
- Decode failures remove that frame from assignment and trigger reassignment
  or vertex-color fallback.
- Memory and cancellation checks occur between frames and chart batches.

This is post-capture work and cannot affect RoomPlan scan performance.

## Atlas generation

Faces assigned to the same frame are grouped into connected components. Each
component becomes a chart whose initial coordinates are the source-frame
projection. A component is split at an edge when adjacent projected triangles
have opposite nonzero screen-space winding or their interiors overlap beyond
the shared edge.

Charts are sorted by descending bounding-box area with a stable frame/face
tie-break and packed by a deterministic skyline packer into one atlas with
eight atlas-pixel padding texels. The first implementation targets a
4,096-pixel maximum dimension and uses binary search for the greatest global
chart scale that fits. Faces too oblique, unresolved, or too small for safe
packing remain vertex-colored.

The baker rasterizes each chart, performs projectively correct source lookup,
stores linear working colors, and encodes the final atlas to sRGB. Padding is
filled by chart-aware dilation so generated mip levels cannot bleed across
charts. Vertices are duplicated only at UV or material seams. Triangle order
and winding remain unchanged.

Atlas rendering is enabled when cache validation succeeds and at least one
face is textured. Otherwise the corrected vertex-color path renders the entire
mesh.

## Coverage fallback

Uncolored fallback vertices are filled only through short mesh-graph paths
whose normals and positions indicate the same local surface. Propagation stops
across sharp normal changes, disconnected components, long edges, and depth
discontinuities. Filled colors carry lower confidence and are never used as
photometric calibration evidence. Remaining unknowns retain neutral gray.

Textured faces and fallback faces can coexist. The renderer uses an atlas
coverage/material flag so unresolved faces use corrected vertex colors rather
than sampling an empty atlas region.

## Metal rendering

The seam-expanded vertex layout contains position, normal when present, sRGB
fallback color, UV, and an atlas-coverage flag. The fragment shader samples the
sRGB atlas for covered faces and otherwise decodes the fallback vertex color.
Both branches return linear color to the sRGB attachment.

The MTKView and render pipeline use 4x MSAA when supported and fall back to 2x
or 1x based on `supportsTextureSampleCount`. Textures receive a complete mip
chain and use trilinear minification plus anisotropic filtering. Depth remains
32-bit float and culling remains disabled because the room is viewed from
inside.

No artificial lighting, ambient occlusion, sharpening filter, or tone-mapping
curve is added in this change.

## Capture-safe changes

The capture loop adds two bounded operations:

- copy optional numeric ISO/exposure-bias metadata from the current frame;
- skip a redundant keyframe when the previous accepted pose differs by less
  than 5 cm and 3 degrees, while forcing a keyframe after two seconds.

The existing one-encoder-at-a-time gate and 0.7-second minimum interval remain.
No additional encoding, image analysis, depth processing, synchronization, or
await is added to the capture tick. Metadata failure is ignored. Pose-based
selection and any metadata schema change require the same physical-device
scan-health gate as other capture changes.

## Failure handling and rollback

- Every derived-stage failure falls back in order: textured mesh, corrected
  vertex colors, neutral mesh, existing semantic viewer.
- Cancellation leaves no partially accepted cache because manifest publication
  occurs last after atomic asset writes.
- Original bundle contents are never mutated.
- The old renderer remains available behind the fallback branch until the v3
  cache is proven on-device.
- Reverting the feature requires deleting v3 derived files; no bundle migration
  or evidence rollback is necessary.

## Verification strategy

### Red-green unit oracles

- A slanted triangle with depths 1, 4, and 4 m proves reciprocal-depth
  occlusion by rejecting a 2.5 m hidden vertex.
- High- and medium-confidence LiDAR fixtures prove their distinct tolerances;
  low confidence proves fallback rather than false rejection.
- Rotated and translated camera fixtures prove the rigid inverse and vertical
  projection convention.
- Pixel-center resize fixtures prove sensor-to-image and sensor-to-depth
  coordinates at centers and borders.
- Black/white and mid-gray fixtures prove linear-light bilinear filtering,
  robust blending, sRGB encoding, and renderer-side decode math.
- Equal-range axial and off-axis frames prove Euclidean distance weighting.
- An outlier frame with a stronger raw weight proves robust inlier selection.
- Cache fixtures prove algorithm/source/settings invalidation.
- A checkerboard inside one large triangle proves atlas detail exists where
  vertex interpolation cannot reproduce it.
- Atlas padding and mip fixtures prove charts do not bleed into each other.
- Mesh-graph filling fixtures prove colors do not cross a sharp edge.

For newly introduced guards, each focused test will be demonstrated to fail
when the live guard or corrected formula is temporarily neutralized, then pass
after restoration.

### Integration oracles

- Existing RoomScanCore tests pass.
- App tests exercise real JPEG decode, depth-payload decode, v3 cache creation,
  cache reuse, cache invalidation, and vertex-only fallback.
- The iOS simulator target builds and tests.
- A generic iOS device build proves Metal shader and resource wiring compile.
- The built product is inspected for the textured shader entry points and v3
  cache symbols.

### Required physical-device gates

Local tests cannot prove sensor registration or scan performance. Before
release, a LiDAR device must prove:

1. Manual projection agrees with `ARCamera.projectPoint` within 0.5 source
   pixel across center, edges, camera rotation, and portrait-held scanning.
2. A captured checkerboard or other high-contrast target shows no consistent
   horizontal or vertical color bias.
3. Solid color patches render without the prior midtone brightening.
4. Atlas output is compared with source photographs from multiple viewpoints,
   including furniture/wall boundaries and thin occluders.
5. Capture still completes normally with healthy, growing mesh anchors and
   depth-bearing keyframes; frame yield, bundle size, CPU pressure, thermals,
   and scan duration are recorded against the existing implementation.
6. First-open atlas generation has acceptable peak memory and cancellation
   behavior on the minimum supported device.

No claim of photo-level device quality is made until these gates pass.
