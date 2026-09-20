import assert from "node:assert/strict";
import test from "node:test";

async function web() {
  await import(new URL("../.test-dist/roomscan-web.js", import.meta.url));
  return globalThis.RoomScanWeb;
}

function room() {
  return {
    roomKey: "west-parlour",
    displayName: "West parlour",
    semanticLayout: {
      elements: [
        { kind: "floor", label: "Oak floor", x: 0.05, y: 0.08, width: 0.9, height: 0.84 },
        { kind: "wall", label: "North wall", x: 0.05, y: 0.08, width: 0.9, height: 0.02 },
        { kind: "door", label: "Entry door", x: 0.42, y: 0.9, width: 0.16, height: 0.02 },
        { kind: "window", label: "Bay window", x: 0.7, y: 0.08, width: 0.2, height: 0.02 },
      ],
    },
    orientation: { initialView: "entry" },
    dimensions: [{ label: "Long wall", meters: 4.2 }],
    qualityWarnings: [{ code: "lighting", severity: "advisory", message: "Review finish under natural light." }],
    comparisons: [{ originalAssetID: "ast_original_001", conceptAssetID: "ast_concept_001", label: "Daylight concept", disclaimer: "Illustrative concept only." }],
    assets: {
      webGeometryAssetID: "ast_geometry_001",
      floorPlanAssetID: "ast_floor_001",
      selectedImageAssetIDs: ["ast_original_001"],
      webTextureAssetIDs: [],
      approvedConceptAssetIDs: ["ast_concept_001"],
    },
  };
}

function recordingCanvas() {
  const calls = [];
  const context = {
    canvas: { width: 800, height: 560 },
    beginPath: () => calls.push(["beginPath"]),
    clearRect: (...values) => calls.push(["clearRect", ...values]),
    closePath: () => calls.push(["closePath"]),
    fill: () => calls.push(["fill"]),
    fillRect: (...values) => calls.push(["fillRect", ...values]),
    fillText: (...values) => calls.push(["fillText", ...values]),
    lineTo: (...values) => calls.push(["lineTo", ...values]),
    moveTo: (...values) => calls.push(["moveTo", ...values]),
    restore: () => calls.push(["restore"]),
    rotate: (...values) => calls.push(["rotate", ...values]),
    save: () => calls.push(["save"]),
    scale: (...values) => calls.push(["scale", ...values]),
    stroke: () => calls.push(["stroke"]),
    strokeRect: (...values) => calls.push(["strokeRect", ...values]),
    translate: (...values) => calls.push(["translate", ...values]),
    set fillStyle(value) { calls.push(["fillStyle", value]); },
    set font(value) { calls.push(["font", value]); },
    set lineWidth(value) { calls.push(["lineWidth", value]); },
    set strokeStyle(value) { calls.push(["strokeStyle", value]); },
  };
  return { calls, context };
}

test("portal view model resets room-local orientation and comparison state", async () => {
  const api = await web();
  const first = room();
  const second = { ...room(), roomKey: "east-study", displayName: "East study", orientation: { initialView: "topDown" } };
  const model = api.createPortalViewModel({
    kind: "property",
    title: "Aster House",
    rooms: [first, second],
    branding: { businessName: "Aster Survey", contact: { website: "https://aster.example" }, accent: "blueprint" },
    downloads: { floorPlanPDF: true, galleryZIP: true, aiReadyPackageAssetID: "ast_ai_package_001" },
    independentRoomNotice: api.INDEPENDENT_ROOM_NOTICE,
  }, { feedbackEnabled: true, aiReadyPackageEnabled: false });

  assert.equal(model.currentRoom().roomKey, "west-parlour");
  assert.equal(model.orientation().initialView, "entry");
  model.rotate(0.5, -0.25);
  model.setComparison(0.8);
  const before = model.orientation().epoch;
  model.selectRoom("east-study");
  assert.equal(model.currentRoom().roomKey, "east-study");
  assert.equal(model.orientation().initialView, "topDown");
  assert.equal(model.orientation().yaw, 0);
  assert.equal(model.orientation().pitch, 0);
  assert.equal(model.comparison(), 0.5);
  assert.ok(model.orientation().epoch > before, "room switch creates a new independent renderer epoch");
  assert.deepEqual(model.downloads(), ["floor_plan_pdf", "gallery_zip"], "live per-link AI policy overrides immutable availability");
});

test("real Canvas renderers draw semantic floor plan and bounded orientation geometry", async () => {
  const api = await web();
  const floor = recordingCanvas();
  api.drawFloorPlan(floor.context, room(), { width: 800, height: 560, highContrast: false });
  assert.ok(floor.calls.some((call) => call[0] === "fillRect"), "floor-plan elements reach the canvas context");
  assert.ok(floor.calls.some((call) => call[0] === "fillText" && call[1] === "Entry door"), "semantic labels reach the renderer");

  const orientation = recordingCanvas();
  api.drawOrientation(orientation.context, {
    vertices: [{ x: 0, y: 0, z: 0 }, { x: 1, y: 0, z: 0 }, { x: 0, y: 1, z: 0 }],
    triangles: [{ a: 0, b: 1, c: 2 }],
  }, { yaw: 0.25, pitch: -0.1, width: 800, height: 560, highContrast: true });
  assert.ok(orientation.calls.some((call) => call[0] === "lineTo"), "validated triangles reach the orientation renderer");
  assert.ok(orientation.calls.some((call) => call[0] === "stroke"));
});

test("comparison keyboard control is bounded and uses meaningful increments", async () => {
  const api = await web();
  assert.equal(api.comparisonKeyStep(0.5, "ArrowLeft"), 0.45);
  assert.equal(api.comparisonKeyStep(0.98, "ArrowRight"), 1);
  assert.equal(api.comparisonKeyStep(0.4, "Home"), 0);
  assert.equal(api.comparisonKeyStep(0.4, "End"), 1);
  assert.equal(api.comparisonKeyStep(0.4, "Escape"), 0.4);
});
