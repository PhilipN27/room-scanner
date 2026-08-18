# Known limitations

- Windows verification is host-static only; it does not compile Swift or run
  XCTest/XCUITest, Xcode, Simulator, RealityKit, RoomPlan, ARKit, UIKit PDF/PNG,
  CloudKit, native USDZ export, or a system share sheet.
- The custom scan canvas and production Apple adapter are compile-intended until
  an iOS 18+ Mac/device gate confirms the exact SDK APIs and behavior.
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
- Slice 0 defines vendor-neutral AI-redesign, sync, hosted-resource, and portal
  contracts but does not build AI package archives, upload anything, create an
  account, provision AWS, publish a portal, charge a subscription, or establish
  production privacy/deletion behavior.
- Installed-SDK declarations and type-checking confirm the relevant RoomPlan,
  ARKit, LocalAuthentication, and UIKit API surfaces only. Physical-iPhone
  proof remains required for unobserved LiDAR, Face ID/passcode, and Share
  Sheet claims. Physical iPad is owner-waived and unverified.
- Slice 1 orientation suggestions are app-owned heuristics based on the first
  finite scan-start pose plus RoomPlan door/opening evidence. They are never
  treated as a RoomPlan canonical-entry API and remain ineligible for later AI
  export/publication until the user confirms or manually replaces them.
- Slice 1 top-down Rotate/Mirror/Reset controls are local presentation metadata
  only. They do not correct or transform captured coordinates and cannot alter
  canonical axes/cameras, geometry, measurements, evidence, or revision bytes.
  The owner accepted corrected semantic-viewer parity on the physical LiDAR
  iPhone. Physical-iPad parity remains waived and unverified.
- Slice 1 property containers are lightweight local groupings of independent
  room projects. They do not infer or claim cross-room transforms, alignment,
  doorway connectivity, shared coordinates, whole-property reconstruction,
  survey accuracy, or construction/model compliance.
- Simulator fixtures prove deterministic orientation, camera, semantic, and UI
  behavior, but not RoomPlan/ARKit/LiDAR category quality, pose conventions, or
  cleanup on hardware. Only specifically retained physical-iPhone evidence may
  support those claims; physical iPad remains waived and unverified.
- Slice 2 quality findings are advisory heuristics, not measurement accuracy.
  Deterministic fixtures and Simulator screenshots prove schema, persistence,
  independent warnings, throttling, overlays, and explicit Save Anyway flow;
  they do not independently prove real motion-blur localization, physical
  missed-region mapping, RoomPlan semantic confidence, or ARKit tracking
  behavior. The owner accepts Slice 2 on the physical LiDAR iPhone based on
  direct observation, but only three physical-run screenshots were retained,
  not a complete independent artifact/device-metadata matrix. The generic
  `regions` label and repeated tracking guidance remain known limitations.
- The owner waived physical-iPad acceptance for the present development
  program. The complete iPad Simulator scheme remains required and physical
  iPad quality/orientation behavior is recorded as unverified—not passed or
  failed. No physical-iPad claim is made.
- The canonical Slice 2 quality carrier is only a provider-neutral contract
  hook. No AI Room Package archive, hosted upload, publication route, portal,
  server SDK, account, authentication, billing, or raw-evidence upload was
  created. Those later-slice capabilities cannot be inferred from this record.
- The Norwalk YMCA Computer Lab example remains deferred until the entire app
  is complete. No room- or classification-specific claim is made from the
  generic Slice 2 owner acceptance.
- Slice 3 local/Simulator implementation and verification are complete: 266/266
  Core tests; complete 219/219 schemes (185 app + 34 UI) on each iPhone 16 Pro
  and iPad (10th generation) Simulator; and focused Slice 3 UI evidence of 5/5
  per form factor. The local matrix also proves deterministic AI-ready and
  Complete archive extraction/closure, authenticated finalized-package Concept
  automatic mapping, and local Share Sheet lease cleanup. Those results do not
  establish physical-system behavior.
- Slice 3's provider instruction files are offline, provider-neutral/package
  metadata with provider-tailored wording. The production `AIRedesign` path has
  no provider/model/authentication/direct-HTTP client. It does not verify a
  provider's current product behavior, privacy terms, account requirements,
  output quality, or compliance with instructions, and it does not make the
  entire target network-free because explicit private CloudKit backup remains
  separately scoped.
- Physical LiDAR iPhone proof remains required for actual outbound Share Sheet
  targets, security-scoped imports, system cancellation/error/dismissal paths,
  and lease cleanup. All physical-iPad checks remain waived and unverified, not
  passed or failed.
