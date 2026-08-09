# Known limitations

- Windows verification is host-static only; it does not compile Swift or run
  XCTest/XCUITest, Xcode, Simulator, RealityKit, RoomPlan, ARKit, UIKit PDF/PNG,
  CloudKit, native USDZ export, or a system share sheet.
- The custom scan canvas and production Apple adapter are compile-intended until
  an iOS 17+ Mac/device gate confirms the exact SDK APIs and behavior.
- Optional raw mesh and world-map evidence are honest omissions unless a
  physical device proves their availability and lifecycle.
- Production rescan acceptance is unavailable because neither continuous
  registration nor ARWorldMap relocalization is recorded in V1.
- Viewer geometry is semantic bounding-box visualization, not native mesh or
  survey geometry; first-person inspection is explicitly no-clip.
- GLB, OBJ, and PLY are skipped because no verified converter is shipped.
- V1 is scoped to one room/project package. Store writers are deliberately
  same-process only; app-extension or cross-process coordination is not proved.
- Scan estimates vary with lighting, occlusion, texture, room size, tracking,
  and device behavior. They are not survey evidence, and unfinished attempts
  are never auto-saved.
- A private CloudKit backup is one explicit record/one CKAsset snapshot, not
  synchronization. The local 512 MiB safety bound does not prove CloudKit asset
  acceptance; development-container recovery remains untested.
- There is no background sync, account system, collaboration, public link,
  public/shared database, analytics, or automatic upload path.
