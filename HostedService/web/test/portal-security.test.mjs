import assert from "node:assert/strict";
import test from "node:test";

async function web() {
  await import(new URL("../.test-dist/roomscan-web.js", import.meta.url));
  return globalThis.RoomScanWeb;
}

function safeRoomPresentation() {
  return {
    schemaVersion: "roomscan-published-room-snapshot-v2",
    contractKind: "publishedRoomSnapshot",
    title: "West parlour",
    room: {
      roomKey: "west-parlour",
      displayName: "West parlour",
      semanticLayout: { elements: [{ kind: "floor", label: "Floor", x: 0, y: 0, width: 1, height: 1 }] },
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
    },
    branding: { businessName: "Aster Survey", contact: { website: "https://aster.example" }, accent: "blueprint" },
    downloads: { floorPlanPDF: true, galleryZIP: true },
  };
}

test("portal fragment is captured once, scrubbed before exchange, and never retained", async () => {
  const api = await web();
  const historyCalls = [];
  const result = api.capturePortalLink({
    href: "https://portal.example/p#AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    replace: (path) => historyCalls.push(path),
  });
  assert.deepEqual(historyCalls, ["/p"]);
  assert.equal(result.consume(), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
  assert.equal(result.consume(), undefined);
  assert.equal(api.portalContinuationPath(false, false), "/p");
  assert.equal(api.portalContinuationPath(true, false), "/p?fallback=1");
  assert.equal(api.portalContinuationPath(false, true), "/p?pin=1");
  assert.equal(api.portalContinuationPath(true, true), "/p?fallback=1&pin=1");
});

test("closed room presentation rejects injected private fields before rendering", async () => {
  const api = await web();
  const safe = safeRoomPresentation();
  assert.equal(api.parsePresentation(safe).kind, "room");
  assert.throws(
    () => api.parsePresentation({ ...safe, rawFrames: ["canary"] }),
    /invalid_presentation/u,
  );
});

test("portal snapshot response is closed and preserves only live capability flags", async () => {
  const api = await web();
  const result = api.parsePortalSnapshot({
    snapshotID: "snp_abcdefghijklmnop",
    kind: "room",
    presentation: { assetID: "ast_abcdefghijklmnop", contentType: "application/json", byteCount: 2048 },
    rooms: [],
    feedbackEnabled: true,
    aiReadyPackageEnabled: false,
  });
  assert.deepEqual(result, {
    snapshotID: "snp_abcdefghijklmnop",
    kind: "room",
    presentation: { assetID: "ast_abcdefghijklmnop", contentType: "application/json", byteCount: 2048 },
    rooms: [],
    feedbackEnabled: true,
    aiReadyPackageEnabled: false,
  });
  assert.throws(
    () => api.parsePortalSnapshot({ ...result, preciseGPS: "canary" }),
    /invalid_response/u,
  );
});

test("canonical JSON sorts keys, retains valid Unicode scalars, and rejects noncanonical wire text", async () => {
  const api = await web();
  assert.equal(api.canonicalJSON({ zebra: 1, alpha: "Room \ud83c\udfe0" }), "{\"alpha\":\"Room 🏠\",\"zebra\":1}");
  assert.deepEqual(api.parseCanonicalJSON("{\"alpha\":\"Room 🏠\",\"zebra\":1}"), { alpha: "Room 🏠", zebra: 1 });
  assert.throws(() => api.parseCanonicalJSON('{"zebra":1,"alpha":"Room 🏠"}'), /invalid_canonical_json/u);
  assert.throws(() => api.canonicalJSON({ label: "\ud800" }), /invalid_canonical_json/u);
});

test("browser DTO limits exactly match the validated publication contract", async () => {
  const api = await web();
  const safe = safeRoomPresentation();
  const room = safe.room;

  assert.equal(api.parsePresentation({
    ...safe,
    room: {
      ...room,
      semanticLayout: { elements: Array.from({ length: 256 }, () => room.semanticLayout.elements[0]) },
      dimensions: Array.from({ length: 32 }, (_, index) => ({ label: `Dimension ${index}`, meters: 1 })),
      qualityWarnings: Array.from({ length: 32 }, (_, index) => ({ code: `warning_${index}`, severity: "advisory", message: "Review." })),
      comparisons: Array.from({ length: 32 }, (_, index) => ({ originalAssetID: `original_${index}`, conceptAssetID: `concept_${index}`, label: "Concept", disclaimer: "Illustrative." })),
      assets: {
        ...room.assets,
        selectedImageAssetIDs: Array.from({ length: 64 }, (_, index) => `image_${index}`),
      },
    },
  }).kind, "room");

  for (const changedRoom of [
    { ...room, semanticLayout: { elements: Array.from({ length: 257 }, () => room.semanticLayout.elements[0]) } },
    { ...room, dimensions: Array.from({ length: 33 }, (_, index) => ({ label: `Dimension ${index}`, meters: 1 })) },
    { ...room, qualityWarnings: Array.from({ length: 33 }, (_, index) => ({ code: `warning_${index}`, severity: "advisory", message: "Review." })) },
    { ...room, comparisons: Array.from({ length: 33 }, (_, index) => ({ originalAssetID: `original_${index}`, conceptAssetID: `concept_${index}`, label: "Concept", disclaimer: "Illustrative." })) },
    { ...room, assets: { ...room.assets, selectedImageAssetIDs: Array.from({ length: 65 }, (_, index) => `image_${index}`) } },
  ]) {
    assert.throws(() => api.parsePresentation({ ...safe, room: changedRoom }), /invalid_presentation/u);
  }

  const vertices = Array.from({ length: 25_001 }, (_, index) => ({ x: index % 2, y: 0, z: 0 }));
  const triangles = Array.from({ length: 50_001 }, () => ({ a: 0, b: 1, c: 2 }));
  assert.equal(api.parseWebGeometry({ vertices, triangles }).vertices.length, 25_001);
});

test("property portal navigation requires independent contiguous room ordering", async () => {
  const api = await web();
  const base = {
    snapshotID: "snp_abcdefghijklmnop",
    kind: "property",
    presentation: { assetID: "ast_abcdefghijklmnop", contentType: "application/json", byteCount: 2048 },
    rooms: [
      { roomKey: "room-a", roomOrder: 1 },
      { roomKey: "room-b", roomOrder: 2 },
    ],
    feedbackEnabled: true,
    aiReadyPackageEnabled: false,
  };
  assert.equal(api.parsePortalSnapshot(base).rooms.length, 2);
  assert.throws(() => api.parsePortalSnapshot({ ...base, rooms: [{ roomKey: "room-a", roomOrder: 1 }] }), /invalid_response/u);
  assert.throws(() => api.parsePortalSnapshot({ ...base, rooms: [{ roomKey: "room-a", roomOrder: 1 }, { roomKey: "room-b", roomOrder: 3 }] }), /invalid_response/u);
});
