import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { canonicalJson, derivePublicationAssets, validatePublicationArchive } from "../../dist/service/src/publication/index.js";
import { createSlice6PortalDocument } from "../../dist/service/src/publication/portal-document.js";

const webRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const hostedRoot = resolve(webRoot, "..");
const PORT = Number(process.env.ROOMSCAN_WEB_FIXTURE_PORT ?? "4173");
const LINK_SECRET = "A".repeat(43);
const PIN_LINK_SECRET = "Q".repeat(43);
const FEEDBACK_CODE = `${"C".repeat(43)}.${"D".repeat(43)}`;
const APP_ACCESS = "E".repeat(32);
const APP_REFRESH = "F".repeat(32);
const COMPLETION_ID = "G".repeat(43);
const SHARE_SECRET = "H".repeat(43);
const CSRF = "I".repeat(43);
const STORED_CANARY = '<img src=x onerror="window.__roomscanStoredCanary=1">';
const SNAPSHOT_ID = `snp_${"s".repeat(16)}`;
const SECOND_SNAPSHOT_ID = `snp_${"t".repeat(16)}`;
const PENDING_SNAPSHOT_ID = `snp_${"q".repeat(16)}`;
const REJECTED_SNAPSHOT_ID = `snp_${"r".repeat(16)}`;
const HISTORICAL_SNAPSHOT_ID = `snp_${"h".repeat(16)}`;
const PROJECT_ID = `prj_${"p".repeat(16)}`;
const SECOND_PROJECT_ID = `prj_${"u".repeat(16)}`;
const PENDING_PROJECT_ID = `prj_${"q".repeat(16)}`;
const REJECTED_PROJECT_ID = `prj_${"v".repeat(16)}`;
const UNPUBLISHED_PROJECT_ID = `prj_${"x".repeat(128)}`;
const RETIRED_PROJECT_ID = `prj_${"z".repeat(16)}`;
const PROPERTY_ID = `prop_${"q".repeat(16)}`;
const LINK_ID = `lnk_${"l".repeat(16)}`;

const fixture = await buildFixture();
const state = {
  revoked: false,
  killed: false,
  feedback: [],
  properties: [fixture.property, fixture.staleProperty],
  requests: [],
  publishedSnapshotRequests: { conceptProjectIDs: [], feedbackSnapshotIDs: [], downloadSnapshotIDs: [], linkSnapshotIDs: [] },
  propertyUpserts: [],
  propertyCreatesByIdempotencyKey: new Map(),
};

const server = createServer(async (request, response) => {
  try {
    await route(request, response);
  } catch (error) {
    response.writeHead(500, { "cache-control": "no-store", "content-type": "text/plain; charset=utf-8" });
    response.end(error instanceof Error ? error.message : "fixture_error");
  }
});
server.listen(PORT, "127.0.0.1", () => console.log(`roomscan-web-fixture-ready:${PORT}`));
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => server.close(() => process.exit(0)));

async function route(request, response) {
  const url = new URL(request.url ?? "/", `http://127.0.0.1:${PORT}`);
  const bodyBytes = await requestBody(request);
  recordRequest(request, url, bodyBytes);
  if (request.method === "GET" && url.pathname === "/health") return text(response, 200, "ok");
  if (request.method === "GET" && url.pathname === "/p") return documentResponse(response);
  if (url.pathname === "/__control/reset") {
    state.revoked = false; state.killed = false; state.feedback = []; state.properties = [fixture.property, fixture.staleProperty]; state.requests = []; state.publishedSnapshotRequests = { conceptProjectIDs: [], feedbackSnapshotIDs: [], downloadSnapshotIDs: [], linkSnapshotIDs: [] }; state.propertyUpserts = []; state.propertyCreatesByIdempotencyKey = new Map();
    return json(response, 200, { status: "reset" });
  }
  if (url.pathname === "/__control/revoke") { state.revoked = true; return json(response, 200, { status: "revoked" }); }
  if (url.pathname === "/__control/kill") { state.killed = true; return json(response, 200, { status: "killed" }); }
  if (url.pathname === "/__control/report") return json(response, 200, report());
  if (request.method !== "POST") return json(response, 404, { error: { code: "not_found" } });

  const body = bodyBytes.byteLength === 0 ? undefined : JSON.parse(bodyBytes.toString("utf8"));
  const cookies = cookieMap(request.headers.cookie);
  if (url.pathname === "/portal/link/exchange") {
    const authorization = request.headers.authorization;
    if (state.killed || state.revoked) return json(response, 200, { status: "unavailable" });
    if (authorization === `RoomScan-Link ${PIN_LINK_SECRET}`) return json(response, 200, { status: "pin_required" }, [cookie("roomscan_portal_pending", "pending", "/portal")]);
    if (authorization !== `RoomScan-Link ${LINK_SECRET}`) return json(response, 200, { status: "unavailable" });
    return json(response, 200, { status: "active" }, [cookie("roomscan_portal", "active", "/portal")]);
  }
  if (url.pathname === "/portal/pin/verify") {
    if (state.killed || state.revoked || cookies.roomscan_portal_pending !== "pending" || body?.pin !== "123456") return json(response, 200, { status: "unavailable" });
    return json(response, 200, { status: "active" }, [cookie("roomscan_portal", "active", "/portal"), expiredCookie("roomscan_portal_pending", "/portal")]);
  }
  if (url.pathname === "/portal/snapshot") {
    if (!portalAllowed(cookies)) return json(response, 403, { error: { code: "forbidden" } });
    return json(response, 200, fixture.portalSnapshot);
  }
  if (url.pathname === "/portal/asset") {
    if (!portalAllowed(cookies)) return json(response, 403, { error: { code: "forbidden" } });
    return assetResponse(response, assetForRequest(body), body);
  }
  if (url.pathname === "/portal/feedback/verification/request") {
    if (!portalAllowed(cookies)) return json(response, 403, { error: { code: "forbidden" } });
    return json(response, 200, { status: "accepted" });
  }
  if (url.pathname === "/portal/feedback/verification/consume") {
    if (!portalAllowed(cookies) || body?.verificationCode !== FEEDBACK_CODE) return json(response, 200, { status: "unavailable" });
    return json(response, 200, { status: "verified" }, [cookie("roomscan_feedback", "verified", "/portal/feedback")]);
  }
  if (url.pathname === "/portal/feedback") {
    if (!portalAllowed(cookies) || cookies.roomscan_feedback !== "verified") return json(response, 403, { error: { code: "forbidden" } });
    state.feedback.push(body);
    return json(response, 200, { status: "recorded", feedbackID: "00000000-0000-4000-8000-000000000001", displayName: "Verified client" });
  }

  if (url.pathname === "/auth/magic-link/request") return json(response, 202, { accepted: true, completionId: COMPLETION_ID, expiresAt: "2030-01-01T00:10:00.000Z" });
  if (url.pathname === "/auth/magic-link/completion/redeem") return json(response, 200, { principalCanonicalId: "principal-fixture", familyPublicId: "family-fixture-0001", accessToken: APP_ACCESS, refreshToken: APP_REFRESH, accessExpiresAt: "2030-01-01T00:05:00.000Z" });
  if (url.pathname === "/professional/session/exchange") {
    if (request.headers.authorization !== `Bearer ${APP_ACCESS}`) return json(response, 401, { error: { code: "unauthenticated" } });
    return json(response, 200, fixture.professionalSession, [cookie("roomscan_professional", "active", "/professional"), cookie("roomscan_professional", "active", "/publications")]);
  }
  if (url.pathname === "/professional/session/logout") {
    if (!professionalAllowed(cookies) || request.headers["x-roomscan-csrf"] !== CSRF) return json(response, 403, { error: { code: "forbidden" } });
    return json(response, 200, { revoked: true }, [expiredCookie("roomscan_professional", "/professional"), expiredCookie("roomscan_professional", "/publications")]);
  }
  if (!professionalAllowed(cookies)) return json(response, 401, { error: { code: "unauthenticated" } });
  if (url.pathname === "/professional/properties/list") {
    if (body?.limit !== 20) return json(response, 400, { error: { code: "invalid_request" } });
    return json(response, 200, { items: state.properties, roomCandidates: fixture.roomCandidates });
  }
  if (url.pathname === "/professional/properties/upsert") {
    if (request.headers["x-roomscan-csrf"] !== CSRF) return json(response, 403, { error: { code: "forbidden" } });
    if (!Array.isArray(body?.rooms) || body.rooms.length > 64 || body.rooms.some((room) => !fixture.roomCandidates.some((candidate) => candidate.projectID === room?.projectID))) return json(response, 409, { error: { code: "room_unavailable" } });
    if (body.propertyID === undefined) {
      if (typeof body.createIdempotencyKey !== "string") return json(response, 400, { error: { code: "invalid_request" } });
      const existing = state.propertyCreatesByIdempotencyKey.get(body.createIdempotencyKey);
      if (existing !== undefined) {
        state.propertyUpserts.push({ operation: "create", responseStatus: "existing", propertyID: null, expectedVersion: null, title: body.title, createIdempotencyKey: body.createIdempotencyKey, rooms: body.rooms });
        return json(response, 200, { status: "existing", propertyID: existing.propertyID, version: existing.version, roomCount: existing.roomCount });
      }
      const property = { propertyID: `prop_${String(state.propertyCreatesByIdempotencyKey.size + 1).padStart(16, "0")}`, title: body.title, version: 1, roomCount: body.rooms.length, rooms: body.rooms };
      state.properties.push(property);
      state.propertyCreatesByIdempotencyKey.set(body.createIdempotencyKey, property);
      state.propertyUpserts.push({ operation: "create", responseStatus: "created", propertyID: null, expectedVersion: null, title: body.title, createIdempotencyKey: body.createIdempotencyKey, rooms: body.rooms });
      if (body.title === "Retry-safe draft" || body.title === "Rotate key draft") return json(response, 503, { error: { code: "unavailable" } });
      return json(response, 200, { status: "created", propertyID: property.propertyID, version: property.version, roomCount: property.roomCount });
    }
    const index = state.properties.findIndex((property) => property.propertyID === body.propertyID);
    const current = state.properties[index];
    if (current === undefined || current.version !== body.expectedVersion) return json(response, 409, { error: { code: "stale" } });
    const property = { ...current, title: body.title, version: current.version + 1, roomCount: body.rooms.length, rooms: body.rooms };
    state.properties[index] = property;
    state.propertyUpserts.push({ operation: "update", responseStatus: "updated", propertyID: body.propertyID, expectedVersion: body.expectedVersion, title: body.title, rooms: body.rooms });
    return json(response, 200, { status: "updated", propertyID: property.propertyID, version: property.version, roomCount: property.roomCount });
  }
  if (url.pathname === "/professional/concepts/list") {
    state.publishedSnapshotRequests.conceptProjectIDs.push(body?.projectID ?? null);
    if (body?.projectID === PROJECT_ID) await delay(350);
    return json(response, 200, { items: fixture.professionalConcepts[body?.projectID] ?? [] });
  }
  if (url.pathname === "/professional/members/list") return json(response, 200, { items: fixture.members });
  if (url.pathname === "/publications/snapshots/list") return state.killed ? json(response, 503, { error: { code: "unavailable" } }) : json(response, 200, { items: fixture.professionalSnapshots });
  if (url.pathname === "/publications/links/list") return state.killed ? json(response, 503, { error: { code: "unavailable" } }) : json(response, 200, { items: [fixture.professionalLink] });
  if (url.pathname === "/publications/feedback/list") {
    state.publishedSnapshotRequests.feedbackSnapshotIDs.push(body?.snapshotID ?? null);
    return state.killed ? json(response, 503, { error: { code: "unavailable" } }) : json(response, 200, { items: fixture.professionalFeedbackBySnapshot[body?.snapshotID] ?? [] });
  }
  if (url.pathname === "/publications/access-history/list") return state.killed ? json(response, 503, { error: { code: "unavailable" } }) : json(response, 200, { items: [fixture.professionalAccess] });
  if (url.pathname === "/publications/downloads/list") {
    state.publishedSnapshotRequests.downloadSnapshotIDs.push(body?.snapshotID ?? null);
    return state.killed ? json(response, 503, { error: { code: "unavailable" } }) : json(response, 200, { items: fixture.professionalDownloadsBySnapshot[body?.snapshotID] ?? [] });
  }
  if (url.pathname === "/publications/links/create") {
    if (state.killed || request.headers["x-roomscan-csrf"] !== CSRF) return json(response, 403, { error: { code: "forbidden" } });
    state.publishedSnapshotRequests.linkSnapshotIDs.push(body?.snapshotID ?? null);
    return json(response, 200, { status: "created", linkID: `lnk_${"c".repeat(16)}`, generation: 1, expiresAt: "2030-01-31T00:00:00.000Z", pinRequired: body.pin !== undefined, shareURL: `https://portal.roomscanstudio.test/p#${SHARE_SECRET}` });
  }
  if (url.pathname === "/publications/links/revoke") {
    if (state.killed || request.headers["x-roomscan-csrf"] !== CSRF) return json(response, 403, { error: { code: "forbidden" } });
    state.revoked = true; return json(response, 200, { status: "revoked", linkID: body.linkID, generation: body.expectedGeneration + 1 });
  }
  if (url.pathname === "/publications/assets/read") {
    if (state.killed) return json(response, 403, { error: { code: "forbidden" } });
    return assetResponse(response, fixture.assets.get(body.assetID), body);
  }
  return json(response, 404, { error: { code: "not_found" } });
}

async function buildFixture() {
  const [stylesheet, script, fixtureSource, expectationSource] = await Promise.all([
    readFile(resolve(webRoot, "dist/portal.css")),
    readFile(resolve(webRoot, "dist/portal.js")),
    readFile(resolve(hostedRoot, "fixtures/publication/property-v1.zip.base64"), "utf8"),
    readFile(resolve(hostedRoot, "fixtures/publication/expectations.json"), "utf8"),
  ]);
  const document = createSlice6PortalDocument({ stylesheet, script });
  const archiveBytes = Uint8Array.from(Buffer.from(fixtureSource.trim(), "base64"));
  const expected = JSON.parse(expectationSource).fixtures.find((candidate) => candidate.name === "property-v1");
  const reader = Object.freeze({ byteLength: archiveBytes.byteLength, read: async (offset, length) => Uint8Array.from(archiveBytes.subarray(offset, offset + length)) });
  const archive = await validatePublicationArchive({ reader, expected });
  const derived = await derivePublicationAssets({ reader, archive, allocationPublicID: `pua_${"e".repeat(16)}` });
  const assets = new Map(derived.map((asset) => [asset.assetPublicID, asset]));
  const presentationAsset = derived.find((asset) => asset.kind === "presentation");
  if (presentationAsset === undefined) throw new Error("missing_presentation");
  const presentation = JSON.parse(Buffer.from(presentationAsset.bytes).toString("utf8"));
  presentation.propertyTitle = `Aster House ${STORED_CANARY}`;
  presentation.branding.businessName = `Aster Survey ${STORED_CANARY}`;
  presentation.rooms[0].displayName = `West parlour ${STORED_CANARY}`;
  presentation.rooms[0].qualityWarnings[0].message = `Review finish under natural light. ${STORED_CANARY}`;
  const presentationBytes = Uint8Array.from(Buffer.from(canonicalJson(presentation), "utf8"));
  assets.set(presentationAsset.assetPublicID, { ...presentationAsset, bytes: presentationBytes, sha256: "fixture", contentType: "application/json" });
  const concept = derived.find((asset) => asset.kind === "approved_concept");
  if (concept === undefined) throw new Error("missing_concept");
  const fallbackDownloads = derived.filter((asset) => asset.downloadKind !== undefined);
  return {
    document,
    assets,
    downloadsByKind: new Map(fallbackDownloads.map((asset) => [asset.downloadKind, asset])),
    portalSnapshot: {
      snapshotID: SNAPSHOT_ID,
      kind: "property",
      presentation: { assetID: presentationAsset.assetPublicID, contentType: "application/json", byteCount: presentationBytes.byteLength },
      rooms: archive.independentRoomKeys.map((roomKey, index) => ({ roomKey, roomOrder: index + 1 })),
      feedbackEnabled: true,
      aiReadyPackageEnabled: false,
    },
    property: { propertyID: PROPERTY_ID, title: `Aster Portfolio ${STORED_CANARY}`, version: 3, roomCount: 2, rooms: archive.independentRoomKeys.map((roomKey, index) => ({ roomKey, roomOrder: index + 1, projectID: index === 0 ? PROJECT_ID : SECOND_PROJECT_ID })) },
    staleProperty: { propertyID: `prop_${"d".repeat(16)}`, title: "Retired room curation", version: 2, roomCount: 1, rooms: [{ roomKey: "room-retired", roomOrder: 1, projectID: RETIRED_PROJECT_ID }] },
    roomCandidates: [
      { projectID: PROJECT_ID, title: "Living room" },
      { projectID: SECOND_PROJECT_ID, title: "Kitchen" },
      { projectID: UNPUBLISHED_PROJECT_ID, title: "Unpublished long draft room" },
      ...boundedRoomCandidates(),
    ],
    professionalSession: { csrfToken: CSRF, expiresAt: "2030-01-01T08:00:00.000Z", membership: { memberID: `mem_${"a".repeat(64)}`, displayName: "Aster Owner", role: "owner", state: "active" }, subscription: { plan: "studio", status: "active", currentPeriodEnd: "2030-02-01T00:00:00.000Z" }, quota: { policyVersion: 1, portalPeriod: "2030-01", used: 1024, reserved: 128, limit: 4096 } },
    members: [{ memberID: `mem_${"b".repeat(64)}`, displayName: `Aster Owner ${STORED_CANARY}`, role: "owner", state: "active", current: true }],
    professionalConcepts: {
      [PROJECT_ID]: [],
      [SECOND_PROJECT_ID]: [
        { snapshotID: SECOND_SNAPSHOT_ID, assetID: concept.assetPublicID, contentType: concept.contentType, byteCount: concept.bytes.byteLength, publishedAt: "2030-02-01T00:00:00.000Z" },
        { snapshotID: HISTORICAL_SNAPSHOT_ID, assetID: concept.assetPublicID, contentType: concept.contentType, byteCount: concept.bytes.byteLength, publishedAt: "2030-01-15T00:00:00.000Z" },
      ],
    },
    professionalSnapshots: [
      { allocationID: `pua_${"c".repeat(16)}`, status: "validation_pending", kind: "room", projectID: PENDING_PROJECT_ID, sourceRevisionID: `rev_${"c".repeat(16)}`, snapshotID: PENDING_SNAPSHOT_ID, createdAt: "2030-01-01T00:00:00.000Z", updatedAt: "2030-01-01T00:00:30.000Z", expiresAt: "2030-02-01T00:00:00.000Z" },
      { allocationID: `pua_${"d".repeat(16)}`, status: "rejected", kind: "room", projectID: REJECTED_PROJECT_ID, sourceRevisionID: `rev_${"d".repeat(16)}`, snapshotID: REJECTED_SNAPSHOT_ID, rejectionCode: "source_stale", createdAt: "2030-01-01T00:00:00.000Z", updatedAt: "2030-01-01T00:01:00.000Z", expiresAt: "2030-02-01T00:00:00.000Z" },
      { allocationID: `pua_${"e".repeat(16)}`, status: "published", kind: "property", projectID: PROJECT_ID, sourceRevisionID: `rev_${"r".repeat(16)}`, propertyID: PROPERTY_ID, snapshotID: SNAPSHOT_ID, createdAt: "2030-01-01T00:00:00.000Z", updatedAt: "2030-01-01T00:01:00.000Z", expiresAt: "2030-02-01T00:00:00.000Z" },
      { allocationID: `pua_${"f".repeat(16)}`, status: "published", kind: "room", projectID: SECOND_PROJECT_ID, sourceRevisionID: `rev_${"f".repeat(16)}`, snapshotID: SECOND_SNAPSHOT_ID, createdAt: "2030-02-01T00:00:00.000Z", updatedAt: "2030-02-01T00:01:00.000Z", expiresAt: "2030-03-01T00:00:00.000Z" },
    ],
    professionalLink: { linkID: LINK_ID, snapshotID: SNAPSHOT_ID, generation: 1, state: "active", expiresAt: "2030-01-31T00:00:00.000Z", pinRequired: true, aiEnabled: false, feedbackEnabled: true, feedbackCount: 1, feedbackCountCapped: false, latestFeedbackAction: "request_changes", latestFeedbackAt: "2030-01-02T00:00:00.000Z" },
    professionalFeedbackBySnapshot: {
      [SNAPSHOT_ID]: [{ feedbackID: "feedback-fixture-0001", linkID: LINK_ID, snapshotID: SNAPSHOT_ID, action: "request_changes", comment: `Please revise the concept. ${STORED_CANARY}`, displayName: `Verified client ${STORED_CANARY}`, occurredAt: "2030-01-02T00:00:00.000Z" }],
      [SECOND_SNAPSHOT_ID]: [{ feedbackID: "feedback-fixture-0002", linkID: LINK_ID, snapshotID: SECOND_SNAPSHOT_ID, action: "approve", comment: `Second published snapshot feedback. ${STORED_CANARY}`, displayName: "Verified second client", occurredAt: "2030-02-02T00:00:00.000Z" }],
    },
    professionalAccess: { eventID: "access-fixture-0001", linkID: LINK_ID, snapshotID: SNAPSHOT_ID, action: "asset", outcome: "allowed", occurredHour: "2030-01-02T10:00:00.000Z", clientFamily: "desktop" },
    professionalDownloadsBySnapshot: {
      [SNAPSHOT_ID]: fallbackDownloads.map((asset) => ({ snapshotID: SNAPSHOT_ID, assetID: asset.assetPublicID, kind: asset.downloadKind, contentType: asset.contentType, byteCount: asset.bytes.byteLength })),
      [SECOND_SNAPSHOT_ID]: fallbackDownloads.map((asset) => ({ snapshotID: SECOND_SNAPSHOT_ID, assetID: asset.assetPublicID, kind: asset.downloadKind, contentType: asset.contentType, byteCount: asset.bytes.byteLength })),
    },
  };
}

function portalAllowed(cookies) { return !state.killed && !state.revoked && cookies.roomscan_portal === "active"; }
function professionalAllowed(cookies) { return cookies.roomscan_professional === "active"; }
function assetForRequest(body) { return body.assetID === undefined ? fixture.downloadsByKind.get(body.downloadKind) : fixture.assets.get(body.assetID); }
function assetResponse(response, asset, supplied) {
  if (asset === undefined) return json(response, 404, { error: { code: "not_found" } });
  const body = supplied;
  const offset = body.offset; const byteCount = body.byteCount; const bytes = Buffer.from(asset.bytes);
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(byteCount) || offset < 0 || byteCount < 1 || offset + byteCount > bytes.byteLength) return json(response, 400, { error: { code: "invalid_request" } });
  const end = offset + byteCount - 1;
  response.writeHead(offset === 0 && byteCount === bytes.byteLength ? 200 : 206, { "accept-ranges": "bytes", "cache-control": "no-store", "content-range": `bytes ${offset}-${end}/${bytes.byteLength}`, "content-type": asset.contentType });
  response.end(bytes.subarray(offset, end + 1));
}
function boundedRoomCandidates() {
  return Array.from({ length: 65 }, (_, index) => ({
    projectID: `prj_${"b".repeat(14)}${String(index + 1).padStart(2, "0")}`,
    title: `Bounded candidate ${String(index + 1).padStart(2, "0")}`,
  }));
}
function delay(milliseconds) { return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds)); }
function documentResponse(response) { response.writeHead(200, fixture.document.headers); response.end(fixture.document.html); }
function requestBody(request) { return new Promise((resolveBody, reject) => { const chunks = []; let total = 0; request.on("data", (chunk) => { total += chunk.byteLength; if (total > 1_048_576) { reject(new Error("body_too_large")); request.destroy(); } else chunks.push(chunk); }); request.on("end", () => resolveBody(Buffer.concat(chunks))); request.on("error", reject); }); }
function cookieMap(value) { const result = {}; for (const item of (value ?? "").split(";")) { const [name, ...rest] = item.trim().split("="); if (name) result[name] = rest.join("="); } return result; }
function cookie(name, value, path) { return `${name}=${value}; Path=${path}; HttpOnly; SameSite=Strict`; }
function expiredCookie(name, path) { return `${name}=; Path=${path}; Max-Age=0; HttpOnly; SameSite=Strict`; }
function json(response, status, value, cookies = []) { response.writeHead(status, { "cache-control": "no-store", "content-type": "application/json", ...(cookies.length === 0 ? {} : { "set-cookie": cookies }) }); response.end(JSON.stringify(value)); }
function text(response, status, value) { response.writeHead(status, { "cache-control": "no-store", "content-type": "text/plain; charset=utf-8" }); response.end(value); }
function recordRequest(request, url, body) { const source = body.toString("utf8"); const authorization = request.headers.authorization ?? ""; state.requests.push({ path: url.pathname, queryHasCanary: containsBearer(url.search), refererHasCanary: containsBearer(request.headers.referer ?? ""), bodyHasCanary: containsBearer(source), feedbackCodeExpected: url.pathname === "/portal/feedback/verification/consume" && source.includes(FEEDBACK_CODE), feedbackCodeOutsideConsume: url.pathname !== "/portal/feedback/verification/consume" && source.includes(FEEDBACK_CODE), authorizationKind: authorization.startsWith("RoomScan-Link ") ? "portal_link" : authorization.startsWith("Bearer ") ? "app_bearer" : "none", authorizationExpected: authorization === `RoomScan-Link ${LINK_SECRET}` || authorization === `RoomScan-Link ${PIN_LINK_SECRET}` || authorization === `Bearer ${APP_ACCESS}` }); }
function containsBearer(value) { return [LINK_SECRET, PIN_LINK_SECRET, APP_ACCESS, APP_REFRESH, SHARE_SECRET].some((secret) => value.includes(secret)); }
function report() { return { requests: state.requests, publishedSnapshotRequests: state.publishedSnapshotRequests, propertyUpserts: state.propertyUpserts, feedbackCount: state.feedback.length, rawTokenFields: JSON.stringify(state.requests).includes(LINK_SECRET) || JSON.stringify(state.requests).includes(PIN_LINK_SECRET) || JSON.stringify(state.requests).includes(APP_ACCESS), revoked: state.revoked, killed: state.killed }; }
