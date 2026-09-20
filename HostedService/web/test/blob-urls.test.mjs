import assert from "node:assert/strict";
import test from "node:test";

async function web() {
  await import(new URL("../.test-dist/roomscan-web.js", import.meta.url));
  return globalThis.RoomScanWeb;
}

test("blob URL registry revokes approved image and fallback URLs on every state reset", async () => {
  const api = await web();
  const nativeRegistry = api.createBlobURLRegistry();
  const nativeURL = nativeRegistry.createImageURL({ blob: new Blob(["native"], { type: "image/png" }), contentType: "image/png", byteCount: 6 });
  assert.match(nativeURL, /^blob:/u, "the browser/Node callable URL host reaches the real object-URL path");
  nativeRegistry.dispose();
  const revoked = [];
  let next = 0;
  const registry = api.createBlobURLRegistry({
    createObjectURL: () => `blob:local-${++next}`,
    revokeObjectURL: (url) => revoked.push(url),
  });
  const image = registry.createImageURL({ blob: new Blob(["image"], { type: "image/png" }), contentType: "image/png", byteCount: 5 });
  const fallback = registry.createDownloadURL({ blob: new Blob(["pdf"], { type: "application/pdf" }), contentType: "application/pdf", byteCount: 3 });
  registry.resetForRoom();
  assert.deepEqual(revoked, [image, fallback]);
  const killed = registry.createImageURL({ blob: new Blob(["image"], { type: "image/jpeg" }), contentType: "image/jpeg", byteCount: 5 });
  registry.resetForDenial();
  assert.deepEqual(revoked, [image, fallback, killed]);
  assert.throws(
    () => registry.createImageURL({ blob: new Blob(["late"], { type: "image/png" }), contentType: "image/png", byteCount: 4 }),
    /invalid_blob/u,
    "a late asset completion cannot recreate a URL after terminal denial",
  );
  assert.throws(
    () => registry.createImageURL({ blob: new Blob(["zip"], { type: "application/zip" }), contentType: "application/zip", byteCount: 3 }),
    /invalid_blob/u,
  );
});
