import assert from "node:assert/strict";
import test from "node:test";

async function web() {
  await import(new URL("../.test-dist/roomscan-web.js", import.meta.url));
  return globalThis.RoomScanWeb;
}

const linkCanary = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

test("portal link exchange confines the bearer to one same-origin authorization header", async () => {
  const api = await web();
  const calls = [];
  const client = api.createServiceClient({
    fetch: async (path, init) => {
      calls.push({ path, init });
      return new Response(JSON.stringify(path === "/portal/link/exchange" ? { status: "active" } : {
        snapshotID: "snp_abcdefghijklmnop",
        kind: "room",
        presentation: { assetID: "ast_abcdefghijklmnop", contentType: "application/json", byteCount: 1 },
        rooms: [], feedbackEnabled: false, aiReadyPackageEnabled: false,
      }), { status: 200, headers: { "content-type": "application/json", "cache-control": "no-store" } });
    },
  });
  assert.deepEqual(await client.exchangePortalLink(linkCanary), { status: "active" });
  await client.portalSnapshot();
  assert.equal(calls.length, 2);
  assert.equal(calls[0].path, "/portal/link/exchange");
  assert.equal(calls[0].path.includes(linkCanary), false);
  assert.equal(calls[0].init.body, undefined);
  assert.equal(calls[0].init.headers.authorization, `RoomScan-Link ${linkCanary}`);
  assert.equal(calls[0].init.credentials, "include");
  assert.equal(calls[0].init.referrerPolicy, "no-referrer");
  assert.equal(calls[1].path, "/portal/snapshot");
  assert.equal("authorization" in calls[1].init.headers, false);
  assert.equal(JSON.stringify(calls[1]).includes(linkCanary), false);
});

test("protected portal asset is assembled only from exact no-store ranges", async () => {
  const api = await web();
  const requests = [];
  const ids = ["a".repeat(16)];
  const client = api.createServiceClient({
    requestID: () => ids.shift(),
    fetch: async (path, init) => {
      assert.equal(path, "/portal/asset");
      const request = JSON.parse(init.body);
      requests.push(request);
      assert.deepEqual(request, {
        assetID: "ast_abcdefghijklmnop",
        byteCount: 3,
        offset: 0,
        requestID: "a".repeat(16),
      });
      return new Response(Uint8Array.of(1, 2, 3), {
        status: 200,
        headers: {
          "content-type": "image/png",
          "cache-control": "no-store",
          "accept-ranges": "bytes",
          "content-range": "bytes 0-2/3",
        },
      });
    },
  });
  const delivered = await client.downloadPortalAsset({ assetID: "ast_abcdefghijklmnop", expectedByteCount: 3 });
  assert.equal(delivered.contentType, "image/png");
  assert.deepEqual([...new Uint8Array(await delivered.blob.arrayBuffer())], [1, 2, 3]);
  assert.deepEqual(requests, [
    { assetID: "ast_abcdefghijklmnop", byteCount: 3, offset: 0, requestID: "a".repeat(16) },
  ]);
});

test("unknown portal asset length uses one bounded discovery byte then exact remaining range", async () => {
  const api = await web();
  const requests = [];
  const ids = ["a".repeat(16), "b".repeat(16)];
  const client = api.createServiceClient({
    requestID: () => ids.shift(),
    fetch: async (_path, init) => {
      const request = JSON.parse(init.body);
      requests.push(request);
      const first = request.offset === 0;
      return new Response(first ? Uint8Array.of(7) : Uint8Array.of(8, 9), {
        status: 206,
        headers: {
          "content-type": "image/jpeg",
          "cache-control": "no-store",
          "accept-ranges": "bytes",
          "content-range": first ? "bytes 0-0/3" : "bytes 1-2/3",
        },
      });
    },
  });

  const delivered = await client.downloadPortalAsset({ assetID: "ast_abcdefghijklmnop" });
  assert.deepEqual([...new Uint8Array(await delivered.blob.arrayBuffer())], [7, 8, 9]);
  assert.deepEqual(requests, [
    { assetID: "ast_abcdefghijklmnop", byteCount: 1, offset: 0, requestID: "a".repeat(16) },
    { assetID: "ast_abcdefghijklmnop", byteCount: 2, offset: 1, requestID: "b".repeat(16) },
  ]);
});
