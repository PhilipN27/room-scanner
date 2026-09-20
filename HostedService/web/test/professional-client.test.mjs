import assert from "node:assert/strict";
import test from "node:test";

async function web() {
  await import(new URL("../.test-dist/roomscan-web.js", import.meta.url));
  return globalThis.RoomScanWeb;
}

const appBearerCanary = "A".repeat(32);
const csrf = "B".repeat(43);

function responseFor(path) {
  const shared = {
    "/professional/session/exchange": {
      expiresAt: "2030-01-01T08:00:00.000Z",
      csrfToken: csrf,
      membership: { memberID: `mem_${"a".repeat(64)}`, displayName: `mem_${"a".repeat(64)}`, role: "owner", state: "active" },
      subscription: { plan: "studio", status: "active" },
      quota: { policyVersion: 1, portalPeriod: "2030-01", used: 1024, reserved: 128, limit: 4096 },
    },
    "/professional/properties/list": {
      items: [{ propertyID: `prop_${"p".repeat(16)}`, title: '<img src=x onerror="canary()">', version: 1, roomCount: 0, rooms: [] }],
      roomCandidates: [
        { projectID: `prj_${"w".repeat(16)}`, title: "West parlour" },
        { projectID: `prj_${"e".repeat(16)}`, title: "East study" },
      ],
    },
    "/professional/concepts/list": { items: [] },
    "/professional/members/list": { items: [{ memberID: `mem_${"b".repeat(64)}`, displayName: `mem_${"b".repeat(64)}`, role: "viewer", state: "active", current: false }] },
    "/publications/snapshots/list": { items: [] },
    "/publications/links/list": { items: [] },
    "/publications/feedback/list": { items: [] },
    "/publications/access-history/list": { items: [] },
    "/publications/downloads/list": { items: [] },
    "/professional/properties/upsert": { status: "created", propertyID: `prop_${"p".repeat(16)}`, version: 1, roomCount: 2 },
    "/publications/links/revoke": { status: "revoked", linkID: `lnk_${"l".repeat(16)}`, generation: 2 },
    "/professional/session/logout": { revoked: true },
  };
  return shared[path];
}

test("professional client exchanges app bearer once, then uses cookie and in-memory CSRF only", async () => {
  const api = await web();
  const calls = [];
  const client = api.createProfessionalClient({
    fetch: async (path, init) => {
      calls.push({ path, init });
      const request = path === "/professional/properties/upsert" ? JSON.parse(init.body) : undefined;
      const value = request?.propertyID === undefined ? responseFor(path) : { status: "updated", propertyID: request.propertyID, version: request.expectedVersion + 1, roomCount: request.rooms.length };
      assert.notEqual(value, undefined, `unexpected path ${path}`);
      return new Response(JSON.stringify(value), { status: 200, headers: { "content-type": "application/json", "cache-control": "no-store" } });
    },
  });

  const session = await client.exchange(appBearerCanary);
  assert.equal(session.membership.role, "owner");
  const properties = await client.listProperties();
  assert.equal(properties.properties[0].title, '<img src=x onerror="canary()">', "stored canary remains inert data for the safe DOM layer");
  assert.deepEqual(properties.roomCandidates, [
    { projectID: `prj_${"w".repeat(16)}`, title: "West parlour" },
    { projectID: `prj_${"e".repeat(16)}`, title: "East study" },
  ], "the bounded properties response carries only safe room candidate metadata");
  await client.listFeedback({ snapshotID: `snp_${"s".repeat(16)}` });
  const rooms = [
    { roomKey: "west-parlour", roomOrder: 1, projectID: `prj_${"w".repeat(16)}` },
    { roomKey: "east-study", roomOrder: 2, projectID: `prj_${"e".repeat(16)}` },
  ];
  await assert.rejects(client.upsertProperty({
    title: "Too many rooms",
    rooms: Array.from({ length: 65 }, (_, index) => ({ roomKey: `room-${index}`, roomOrder: index + 1, projectID: `prj_${String(index).padStart(16, "0")}` })),
    createIdempotencyKey: "too-many-rooms-0001",
  }), /invalid_response/u, "the browser client rejects a curation beyond the 64-room contract before a network mutation");
  await assert.rejects(client.upsertProperty({
    title: "Full project identifier is not a room key",
    rooms: [{ roomKey: `prj_${"x".repeat(128)}`, roomOrder: 1, projectID: `prj_${"x".repeat(128)}` }],
    createIdempotencyKey: "long-room-key-0001",
  }), /invalid_response/u, "a full prefixed project identifier exceeds the public room-key bound and must be reduced by the curation UI");
  assert.deepEqual(await client.upsertProperty({
    title: "Aster House",
    rooms,
    createIdempotencyKey: "create-property-0001",
  }), { status: "created", propertyID: `prop_${"p".repeat(16)}`, version: 1, roomCount: 2 });
  assert.deepEqual(await client.upsertProperty({
    propertyID: `prop_${"p".repeat(16)}`,
    expectedVersion: 1,
    title: "Aster House revised",
    rooms: [rooms[1], rooms[0]],
  }), { status: "updated", propertyID: `prop_${"p".repeat(16)}`, version: 2, roomCount: 2 });
  await client.revokeLink(`lnk_${"l".repeat(16)}`, 1);
  await client.logout();

  assert.equal(calls[0].init.headers.authorization, `Bearer ${appBearerCanary}`);
  assert.equal(calls[0].init.body, undefined);
  for (const call of calls.slice(1)) {
    assert.equal("authorization" in call.init.headers, false, "app bearer is never reused after exchange");
    assert.equal(JSON.stringify(call).includes(appBearerCanary), false);
    assert.equal(call.init.credentials, "include");
  }
  const mutationCalls = calls.filter((call) => ["/professional/properties/upsert", "/publications/links/revoke", "/professional/session/logout"].includes(call.path));
  assert.ok(mutationCalls.every((call) => call.init.headers["x-roomscan-csrf"] === csrf));
  assert.equal(calls.find((call) => call.path === "/professional/properties/list").init.headers["x-roomscan-csrf"], undefined);
  assert.deepEqual(JSON.parse(calls.find((call) => call.path === "/professional/properties/list").init.body), {
    limit: 20,
  }, "properties stay on the server's bounded first page while room candidates have their own response cap");
  assert.deepEqual(JSON.parse(calls.find((call) => call.path === "/publications/feedback/list").init.body), {
    limit: 20,
    snapshotID: `snp_${"s".repeat(16)}`,
  }, "the browser always supplies the server-required link or snapshot scope");
  const propertyMutations = calls.filter((call) => call.path === "/professional/properties/upsert").map((call) => JSON.parse(call.init.body));
  assert.deepEqual(propertyMutations, [
    {
      createIdempotencyKey: "create-property-0001",
      rooms: [
        { projectID: `prj_${"w".repeat(16)}`, roomKey: "west-parlour", roomOrder: 1 },
        { projectID: `prj_${"e".repeat(16)}`, roomKey: "east-study", roomOrder: 2 },
      ],
      title: "Aster House",
    },
    {
      expectedVersion: 1,
      propertyID: `prop_${"p".repeat(16)}`,
      rooms: [
        { projectID: `prj_${"w".repeat(16)}`, roomKey: "west-parlour", roomOrder: 1 },
        { projectID: `prj_${"e".repeat(16)}`, roomKey: "east-study", roomOrder: 2 },
      ],
      title: "Aster House revised",
    },
  ], "property curation sends ordered rooms and the exact existing-property CAS tuple");
});

test("portal client supports PIN and one-time verified immutable feedback without retaining secrets", async () => {
  const api = await web();
  const calls = [];
  const client = api.createServiceClient({
    requestID: () => "request_identifier_0001",
    fetch: async (path, init) => {
      calls.push({ path, init });
      const value = path === "/portal/pin/verify" ? { status: "active" }
        : path === "/portal/feedback/verification/request" ? { status: "accepted" }
          : path === "/portal/feedback/verification/consume" ? { status: "verified" }
            : { status: "recorded", feedbackID: "00000000-0000-4000-8000-000000000001", displayName: "Verified client" };
      return new Response(JSON.stringify(value), { status: 200, headers: { "content-type": "application/json", "cache-control": "no-store" } });
    },
  });

  assert.deepEqual(await client.verifyPIN("123456"), { status: "active" });
  assert.deepEqual(await client.requestFeedbackVerification("client@example.test"), { status: "accepted" });
  const code = `${"C".repeat(43)}.${"D".repeat(43)}`;
  assert.deepEqual(await client.consumeFeedbackVerification(code), { status: "verified" });
  assert.deepEqual(await client.createFeedback("request_changes", "Please revisit the daylight concept."), {
    status: "recorded", feedbackID: "00000000-0000-4000-8000-000000000001", displayName: "Verified client",
  });
  assert.deepEqual(calls.map((call) => call.path), [
    "/portal/pin/verify",
    "/portal/feedback/verification/request",
    "/portal/feedback/verification/consume",
    "/portal/feedback",
  ]);
  assert.equal(calls.every((call) => !("authorization" in call.init.headers)), true);
  assert.equal(calls.every((call) => call.init.credentials === "include"), true);
});

test("professional verified-email flow keeps verifier in memory and exchanges the returned access token immediately", async () => {
  const api = await web();
  const calls = [];
  const access = "E".repeat(32);
  const refresh = "F".repeat(32);
  const completion = "G".repeat(43);
  const client = api.createProfessionalClient({
    fetch: async (path, init) => {
      calls.push({ path, init });
      const body = init.body === undefined ? undefined : JSON.parse(init.body);
      const value = path === "/auth/magic-link/request"
        ? { accepted: true, completionId: completion, expiresAt: "2030-01-01T00:10:00.000Z" }
        : path === "/auth/magic-link/completion/redeem"
          ? { principalCanonicalId: "principal-01", familyPublicId: "family-session-0001", accessToken: access, refreshToken: refresh, accessExpiresAt: "2030-01-01T00:05:00.000Z" }
          : responseFor(path);
      if (path === "/auth/magic-link/request") {
        assert.equal(body.purpose, "sign-in");
        assert.match(body.codeChallenge, /^[A-Za-z0-9_-]{43}$/u);
        assert.equal(JSON.stringify(body).includes("codeVerifier"), false);
      }
      return new Response(JSON.stringify(value), { status: path === "/auth/magic-link/request" ? 202 : 200, headers: { "content-type": "application/json", "cache-control": "no-store" } });
    },
  });

  assert.deepEqual(await client.requestEmailSignIn("pro@example.test"), { status: "accepted", expiresAt: "2030-01-01T00:10:00.000Z" });
  const session = await client.redeemEmailSignIn("ABCD-1234");
  assert.equal(session.membership.role, "owner");
  assert.deepEqual(calls.map((call) => call.path), [
    "/auth/magic-link/request",
    "/auth/magic-link/completion/redeem",
    "/professional/session/exchange",
  ]);
  assert.equal(calls[1].init.body.includes(completion), true);
  assert.equal(calls[2].init.headers.authorization, `Bearer ${access}`);
  assert.equal(JSON.stringify(calls[2]).includes(refresh), false, "refresh token is never forwarded or retained as browser authority");
});

test("professional navigation is bounded to the eight approved lightweight flows", async () => {
  const api = await web();
  assert.deepEqual(api.PROFESSIONAL_SECTIONS, [
    "properties", "concepts", "feedback", "links", "roles", "billing", "access-history", "downloads",
  ]);
  assert.equal(api.PROFESSIONAL_SECTIONS.includes("capture"), false);
  assert.equal(api.PROFESSIONAL_SECTIONS.includes("spatial-editor"), false);
});
