# Colored-Mesh Large-Room Optimization Plan

## Outcome

Reduce uncached colored-mesh processing time for large rooms without changing
projection accuracy, visibility tolerances, frame eligibility, photometric
overlap requirements, atlas resolution, texture filtering, or derived visual
quality.

## Scope and boundaries

- Optimize `RoomMeshColor` byte-to-linear conversion with an immutable 256-entry
  lookup table representing the existing IEC sRGB formula.
- Optimize `RoomMeshFrameAnalysis.luminanceSharpness` by computing each source
  pixel's linear luminance once and reusing it for neighboring Laplacians.
- Build photometric frame-pair candidates from shared sample IDs rather than
  scanning every sample dictionary for every possible frame pair. All pairs
  meeting the existing 128-sample overlap threshold remain included.
- Add deterministic correctness and bounded large-room regression tests in
  `RoomMeshFrameAnalysisTests`.
- Record phase-level timing locally so a physical-device run identifies any
  remaining dominant phase without telemetry or capture-tick work.

## Exclusions

- No frame dropping, image downscaling below the approved 1,024-pixel analysis
  bound, atlas reduction, tolerance relaxation, lower-quality filtering, JPEG
  changes, capture-loop work, ARKit ordering changes, or original-evidence
  mutation.
- No unbounded parallel image decoding or memory growth.
- No claim about physical-device wall-clock improvement until measured there.

## Ordered changes and TDD oracles

1. Add an all-256-values oracle proving lookup conversion matches the existing
   sRGB equation, plus a 1,024-pixel sharpness workload oracle. Run red against
   the current repeated-conversion implementation.
2. Add the lookup table and single-pass luminance buffer. Run focused green,
   neutralize lookup reuse safely, confirm the performance oracle detects the
   regression, restore, and run surrounding frame-analysis tests.
3. Add a sparse large-room calibration fixture whose distant frames have no
   overlap and whose adjacent frames reproduce a smaller reference solution.
   Confirm the bounded oracle fails against the all-pairs scan.
4. Add an inverted sample-to-frame index to enumerate only frame pairs that can
   reach 128 shared samples. Preserve sorted sample IDs and deterministic edge
   order. Run focused green, neutralize candidate pruning, prove failure,
   restore, and run surrounding tests.
5. Add phase-duration diagnostics only to the post-capture worker, then run the
   complete RoomScanCore suite, relevant RoomScanStudio tests, Simulator tests,
   unsigned generic-device build, built-product inspection, and final
   diff/status checks.

## Rollback

Each optimization is internal to RoomScanCore and preserves public contracts.
Reverting the lookup/luminance changes or overlap index restores the previous
implementation without bundle migration. Derived files remain disposable and
the original capture bundle remains immutable.

## Risks

- Floating-point summation order must remain stable; sharpness correctness is
  checked against a direct formula fixture with a tight tolerance.
- Timing assertions can be noisy; thresholds are deliberately several times
  slower than the optimized baseline and correctness has independent oracles.
- A room where every frame sees every calibration sample remains intrinsically
  dense. The optimization targets the normal large-room case where views are
  spatially local without discarding any valid overlap edge.

## Completion oracles

- Every encoded byte maps to the same linear value as the explicit sRGB formula.
- Sharpness values match the direct reference calculation within the test's
  floating-point tolerance.
- Sparse-index calibration matches reference gains/connectivity and retains
  every pair with at least 128 shared samples.
- Both large-image sharpness and sparse large-room calibration finish within
  their bounded regression thresholds on the verification host.
- Complete core/app/Simulator/device-build verification remains green.
- Physical-device timing, memory, thermal behavior, and appearance remain
  explicitly documented gates.
