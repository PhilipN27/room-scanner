# Real-device test plan

## Purpose

These tests are pending physical evidence on one supported LiDAR iPhone and
one supported LiDAR iPad. They are not satisfied by the deterministic fixture
or Simulator driver.

1. Verify `RoomCaptureSession.isSupported` gates live capture. Verify optional
   scene reconstruction only controls the raw-mesh omission status, never the
   RoomPlan capture gate.
2. Confirm **Prepare capture** is the first camera-permission trigger and
   **Request GPS** is the first location-permission trigger. Denial must leave
   manual location usable and create no package until explicit Save.
3. Inspect the black semantic canvas, one injected app-owned ARSession, Stop
   privacy behavior, processing/retry/discard cleanup, reference-photo quality,
   and the RoomPlan raw/processed/USDZ evidence byte closure.
4. Exercise viewer and editor on saved data at default and accessibility Dynamic
   Type sizes, including no-clip disclosure, save/cancel, and stale-head error.
5. Test a CloudKit development container only after explicit opt-in and a
   deliberate Back up action. Confirm local use remains functional when iCloud
   is unavailable or disabled.

Production V1 rescan remains unavailable: no continuous registration survives
the privacy stop and no ARWorldMap is requested. Fixture-only rescan is not
device evidence.

## Pending named field test: Norwalk YMCA Computer Lab

Run this separately on the chosen LiDAR iPhone and LiDAR iPad. Record device
model, OS build, app build, room lighting, scan path, and any permission or
tracking interruption. Review whether the semantic result interprets two
six-station desk groups, the podium, and the centered back/right entry in a
useful way. Check table/chair treatment as movable-object classifications
without encoding those expectations in app logic. Compare displayed estimates
with independently recorded reference measurements and retain the two device
evidence sets separately. This is a pending field-test plan, not a claim that
the room or classifications have been validated.
