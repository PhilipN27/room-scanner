import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  SLICE5_ROUTE_MANIFEST,
  SLICE5_ROUTE_SET_VERSION,
  SLICE6_ROUTE_MANIFEST,
  SLICE6_ROUTE_SET_VERSION,
} from "../src/contracts/route-manifest.js";
import { SLICE6_OPENAPI } from "../src/contracts/openapi.js";
import { canonicalJson } from "../src/publication/contracts.js";
import { PublicationSecretHasher, type PublicationCapabilityService } from "../src/publication/capabilities.js";
import {
  assertSlice6RouteRootClosure,
  createSlice6PortalDeliveryPublicationHandler,
  createSlice6PrivateApiPublicationHandler,
  createSlice6PublicationHandler,
  SLICE6_ROUTE_ROOT_COUNTS,
} from "../src/publication/route-application.js";
import type { ApiGatewayV2Request } from "../src/handlers/factory.js";

const SAFE_PORTAL_DOCUMENT = Object.freeze({
  stylesheet: Uint8Array.from(Buffer.from(":root{color-scheme:light}#roomscan-portal{min-height:100vh}", "utf8")),
  script: Uint8Array.from(Buffer.from("\"use strict\";(()=>{const fragment=location.hash;history.replaceState(null,\"\",\"/p\");void fragment;})();", "utf8")),
});

test("professional property inventory includes bounded safe synced-room candidates without a new route", async () => {
  const calls: string[] = [];
  const publication = new Proxy({}, { get: (_target, method) => async () => {
    calls.push(String(method));
    if (method === "listProperties") return [];
    if (method === "listRoomCandidates") return [{ projectID: `prj_${"r".repeat(16)}`, title: "Unpublished synced room" }];
    throw new Error("unexpected capability");
  } }) as PublicationCapabilityService;
  const handler = createSlice6PrivateApiPublicationHandler({ publication, secretHasher: new PublicationSecretHasher(Buffer.alloc(32, 0x32)), legacy: async () => response(404, {}) });
  const result = await handler(request("POST", "/professional/properties/list", canonicalJson({}), { "content-type": "application/json", authorization: `Bearer ${"a".repeat(43)}` }));
  assert.equal(result.statusCode, 200);
  assert.deepEqual(JSON.parse(result.body), { items: [], roomCandidates: [{ projectID: `prj_${"r".repeat(16)}`, title: "Unpublished synced room" }] });
  assert.deepEqual(calls, ["listProperties", "listRoomCandidates"]);
});

test("Slice 6 appends the approved 26 publication routes without changing Slice 5 object identity", () => {
  assert.equal(SLICE5_ROUTE_SET_VERSION, "roomscan-slice5-routes-v1");
  assert.equal(SLICE6_ROUTE_SET_VERSION, "roomscan-slice6-routes-v1");
  assert.equal(SLICE6_ROUTE_MANIFEST.length, 55);
  for (let index = 0; index < SLICE5_ROUTE_MANIFEST.length; index += 1) {
    assert.equal(SLICE6_ROUTE_MANIFEST[index], SLICE5_ROUTE_MANIFEST[index], `SLICE6[${index}] === SLICE5[${index}]`);
  }
  assert.deepEqual(
    SLICE6_ROUTE_MANIFEST.slice(29).map((route) => `${route.method} ${route.pathTemplate} ${route.id}`),
    [
      "POST /professional/session/exchange professional.session.exchange",
      "POST /professional/session/logout professional.session.logout",
      "POST /professional/properties/list professional.properties.list",
      "POST /professional/properties/upsert professional.properties.upsert",
      "POST /professional/concepts/list professional.concepts.list",
      "POST /professional/members/list professional.members.list",
      "POST /publications/snapshots/allocate publication.snapshot.allocate",
      "POST /publications/snapshots/complete publication.snapshot.complete",
      "POST /publications/snapshots/status publication.snapshot.status",
      "POST /publications/snapshots/list publication.snapshot.list",
      "POST /publications/links/create publication.link.create",
      "POST /publications/links/update publication.link.update",
      "POST /publications/links/revoke publication.link.revoke",
      "POST /publications/links/list publication.link.list",
      "POST /publications/feedback/list publication.feedback.list",
      "POST /publications/access-history/list publication.access-history.list",
      "POST /publications/downloads/list publication.downloads.list",
      "POST /publications/assets/read publication.asset.read",
      "GET /p portal.shell.get",
      "POST /portal/link/exchange portal.link.exchange",
      "POST /portal/pin/verify portal.pin.verify",
      "POST /portal/snapshot portal.snapshot.get",
      "POST /portal/asset portal.asset.read",
      "POST /portal/feedback/verification/request portal.feedback.verification.request",
      "POST /portal/feedback/verification/consume portal.feedback.verification.consume",
      "POST /portal/feedback portal.feedback.create",
    ],
  );
  const operations = Object.values(SLICE6_OPENAPI.paths as Record<string, Record<string, unknown>>).reduce((count, item) => count + ["get", "post"].filter((method) => method in item).length, 0);
  assert.equal(operations, 55, "OpenAPI documents exactly the additive service surface");
  assert.ok((SLICE6_OPENAPI.paths as Record<string, Record<string, unknown>>)["/p"]?.get);
  const specification = JSON.stringify(SLICE6_OPENAPI);
  assert.equal(/tokenHash|objectKey|objectVersion|pinVerifier|rawFrame|worldMap|privateNote/iu.test(specification), false, "the public contract does not document a private capability or working-material field");
});

test("Slice 6 OpenAPI documents the real additive statuses, bounded public responses, and browser mutation guards", () => {
  const paths = SLICE6_OPENAPI.paths as Record<string, Record<string, Record<string, unknown>>>;
  const exchange = paths["/professional/session/exchange"]?.post;
  const exchangeSchema = (((exchange?.responses as Record<string, { readonly content?: Record<string, { readonly schema?: Record<string, unknown> }> }>)["200"]?.content?.["application/json"]?.schema ?? {}) as Record<string, unknown>);
  assert.deepEqual(exchangeSchema.required, ["csrfToken", "expiresAt", "membership", "quota", "subscription"], "the browser bootstrap is not falsely documented as only {status}");
  assert.equal((exchangeSchema.properties as Record<string, unknown>)?.membership !== undefined, true);

  const snapshot = paths["/portal/snapshot"]?.post;
  const snapshotSchema = (((snapshot?.responses as Record<string, { readonly content?: Record<string, { readonly schema?: Record<string, unknown> }> }>)["200"]?.content?.["application/json"]?.schema ?? {}) as Record<string, unknown>);
  assert.deepEqual(snapshotSchema.required, ["aiReadyPackageEnabled", "feedbackEnabled", "kind", "presentation", "rooms", "snapshotID"], "portal snapshot projects only live link-scoped feedback/AI capabilities alongside its immutable presentation");
  assert.equal(JSON.stringify(snapshotSchema).includes("objectKey"), false);
  const rooms = ((snapshotSchema.properties as Record<string, Record<string, unknown>>)?.rooms ?? {});
  assert.equal(rooms.minItems, 0, "room snapshots explicitly carry an empty room list rather than a fabricated property member");

  const linkList = paths["/publications/links/list"]?.post;
  const linkListSchema = (((linkList?.responses as Record<string, { readonly content?: Record<string, { readonly schema?: Record<string, unknown> }> }>)?.["200"]?.content?.["application/json"]?.schema ?? {}) as Record<string, unknown>);
  assert.match(JSON.stringify(linkListSchema), /feedbackCount/u);
  const linkItem = (((linkListSchema.properties as Record<string, Record<string, unknown>> | undefined)?.items?.items ?? {}) as Record<string, unknown>);
  const linkItemProperties = (linkItem.properties ?? {}) as Record<string, unknown>;
  assert.equal("comment" in linkItemProperties || "displayName" in linkItemProperties || "email" in linkItemProperties, false, "link summaries expose only bounded aggregates, never feedback content or identity");

  const propertyUpsert = paths["/professional/properties/upsert"]?.post;
  const propertySchema = (((propertyUpsert?.responses as Record<string, { readonly content?: Record<string, { readonly schema?: Record<string, unknown> }> }>)?.["200"]?.content?.["application/json"]?.schema ?? {}) as Record<string, unknown>);
  assert.match(JSON.stringify(propertySchema), /existing/u, "a lost property-create response is accurately documented as idempotent existing");

  const feedbackRequest = paths["/portal/feedback/verification/request"]?.post;
  const feedbackRequestSchema = (((feedbackRequest?.requestBody as { readonly content?: Record<string, { readonly schema?: Record<string, unknown> }> })?.content?.["application/json"]?.schema ?? {}) as Record<string, unknown>);
  assert.deepEqual(feedbackRequestSchema.required, ["email", "requestID"], "feedback verification carries a stable non-secret retry identity");

  const portalLink = ((SLICE6_OPENAPI.components as Record<string, Record<string, Record<string, unknown>>>)?.securitySchemes?.portalLink ?? {});
  assert.deepEqual(portalLink, {
    type: "apiKey",
    in: "header",
    name: "Authorization",
    description: "Exact credential syntax: RoomScan-Link <43-character base64url secret>.",
  }, "OpenAPI must describe the literal RoomScan-Link Authorization header, never a generic HTTP bearer");

  const allocate = paths["/publications/snapshots/allocate"]?.post;
  assert.equal((allocate?.responses as Record<string, unknown>)["202"] !== undefined, true, "the asynchronous validation allocation is accurately 202");
  const mutationSecurity = (paths["/publications/links/revoke"]?.post?.security ?? []) as readonly Record<string, readonly unknown[]>[];
  assert.equal(mutationSecurity.some((requirement) => "professionalCookie" in requirement && "csrfHeader" in requirement), true, "professional cookie mutations publish their CSRF requirement without falsely requiring it for the native bearer alternative");
  const pinParameters = (paths["/portal/pin/verify"]?.post?.parameters ?? []) as readonly Record<string, unknown>[];
  assert.equal(pinParameters.some((parameter) => parameter.in === "header" && parameter.name === "origin" && parameter.required === true), true, "PIN mutation publishes its same-origin constraint");

  const professionalAsset = paths["/publications/assets/read"]?.post as Readonly<Record<string, unknown>> | undefined;
  assert.notEqual(professionalAsset, undefined, "the owner/member asset stream has one explicit additive route");
  const professionalAssetSecurity = (professionalAsset?.security ?? []) as readonly Record<string, readonly unknown[]>[];
  assert.equal(professionalAssetSecurity.some((requirement) => "professionalCookie" in requirement && "csrfHeader" in requirement), false, "a protected read remains CSRF-free");
  assert.equal((professionalAsset?.responses as Record<string, unknown>)?.["206"] !== undefined, true, "the route documents bounded binary range delivery");
});

test("the Slice 6 entrypoint preserves parameterized Slice 4 routes while refusing publication cookies before legacy dispatch", async () => {
  let legacyCalls = 0;
  const handler = createSlice6PublicationHandler(withPortalDocument({
    legacy: async () => {
      legacyCalls += 1;
      return response(200, { legacy: true });
    },
    publication: emptyPublicationService(),
    secretHasher: new PublicationSecretHasher(Buffer.alloc(32, 0x71)),
  }));

  assert.equal((await handler(request("GET", "/auth/magic-link/selector-12345678"))).statusCode, 200, "the inherited selector route remains owned by Slice 4");
  assert.equal(legacyCalls, 1);
  const portalSecret = Buffer.alloc(32, 0x72).toString("base64url");
  assert.equal((await handler({ ...request("GET", "/health"), cookies: [`roomscan_portal=${portalSecret}`] })).statusCode, 400, "portal state must never cross the frozen legacy normalizer");
  assert.equal(legacyCalls, 1, "the legacy handler cannot observe a publication cookie");
});

test("PrivateApi and PortalDelivery root allowlists cannot dispatch across their sealed delivery boundary", async () => {
  assertSlice6RouteRootClosure();
  assert.deepEqual(SLICE6_ROUTE_ROOT_COUNTS, { privateApi: 45, portalDelivery: 9, stripe: 1 }, "the three integrations partition exactly the sealed 55-route manifest");
  const hasher = new PublicationSecretHasher(Buffer.alloc(32, 0x8a));
  const recording = recordingPublicationService();
  const dependencies = withPortalDocument({
    legacy: async () => response(200, { legacy: true }),
    publication: recording.service,
    secretHasher: hasher,
  });
  const privateApi = createSlice6PrivateApiPublicationHandler(dependencies);
  const portalDelivery = createSlice6PortalDeliveryPublicationHandler(dependencies);
  const portal = Buffer.alloc(32, 0x8b).toString("base64url");

  assert.equal((await privateApi({ ...request("POST", "/portal/snapshot"), cookies: [`roomscan_portal=${portal}`] })).statusCode, 404, "PrivateApi cannot dispatch an active portal session read");
  assert.equal((await privateApi({ ...request("POST", "/publications/assets/read", canonicalJson({ assetID: `ast_${"z".repeat(16)}`, byteCount: 1, offset: 0, requestID: "private-root-asset-001" }), { "content-type": "application/json" }), cookies: [`roomscan_professional=${portal}`] })).statusCode, 404, "PrivateApi cannot stream professional publication bytes");
  assert.equal((await privateApi(request("POST", "/billing/stripe/webhook", "{}", { "content-type": "application/json" }))).statusCode, 404, "PrivateApi cannot dispatch the separately integrated Stripe ingress route");
  assert.equal((await portalDelivery(request("GET", "/health"))).statusCode, 404, "PortalDelivery cannot call the inherited private API root");
  assert.equal((await portalDelivery({ ...request("POST", "/publications/links/list", canonicalJson({}), { "content-type": "application/json" }), cookies: [`roomscan_professional=${portal}`] })).statusCode, 404, "PortalDelivery cannot dispatch professional metadata/list paths");
  assert.equal((await portalDelivery(request("GET", "/p"))).statusCode, 200, "the static public shell remains inside PortalDelivery");
  assert.equal((await portalDelivery({ ...request("POST", "/portal/snapshot"), cookies: [`roomscan_portal=${portal}`] })).statusCode, 200, "PortalDelivery can reach its exact active portal route");
  assert.equal(recording.calls.at(-1)?.method, "portalSnapshot");
});

test("the injected portal document is static, asset-hashed, and rejects a malformed encoded body", async () => {
  const handler = createSlice6PublicationHandler(withPortalDocument({
    legacy: async () => response(200, { legacy: true }),
    publication: emptyPublicationService(),
    secretHasher: new PublicationSecretHasher(Buffer.alloc(32, 0x73)),
  }));

  const clean = await handler(request("GET", "/p"));
  assert.equal(clean.statusCode, 200);
  assert.equal(clean.headers["referrer-policy"], "no-referrer");
  assert.equal(clean.headers["x-content-type-options"], "nosniff");
  assert.match(clean.headers["content-security-policy"] ?? "", /require-trusted-types-for 'script'/u);
  assert.match(clean.headers["content-security-policy"] ?? "", new RegExp(`style-src 'sha256-${createHash("sha256").update(SAFE_PORTAL_DOCUMENT.stylesheet).digest("base64")}'`, "u"));
  assert.match(clean.headers["content-security-policy"] ?? "", new RegExp(`script-src 'sha256-${createHash("sha256").update(SAFE_PORTAL_DOCUMENT.script).digest("base64")}'`, "u"));
  assert.equal(clean.body.includes(Buffer.from(SAFE_PORTAL_DOCUMENT.stylesheet).toString("utf8")), true);
  assert.equal(clean.body.includes(Buffer.from(SAFE_PORTAL_DOCUMENT.script).toString("utf8")), true);
  assert.equal(clean.body.includes("CustomEvent"), false, "the route no longer owns a fragment-event shell");
  assert.equal(/(?:sourceMappingURL|@import|https?:\/\/|<script[^>]+src=|\son[a-z]+\s*=)/iu.test(clean.body), false, "the injected static document has no import, source map, or inline handler escape hatch");
  assert.equal(clean.body.includes(Buffer.alloc(32, 0x74).toString("base64url")), false, "the shell contains no bearer canary before a fragment is scrubbed locally");
  const second = await handler({ ...request("GET", "/p"), headers: { "x-request-token": "portal-fragment-canary" } });
  assert.equal(second.body.includes("portal-fragment-canary"), false, "the document is request-independent and cannot reflect a fragment/token canary");

  const malformed = await handler({ ...request("GET", "/p"), body: "%", isBase64Encoded: true });
  assert.equal(malformed.statusCode, 400, "an invalid base64 envelope is still a supplied body and must not bypass a no-body route");
});

test("professional exchange mirrors one session secret only into its two narrow browser paths and logout revokes once", async () => {
  const hasher = new PublicationSecretHasher(Buffer.alloc(32, 0x81));
  const recording = recordingPublicationService();
  const handler = createSlice6PublicationHandler(withPortalDocument({
    legacy: async () => response(200, { legacy: true }),
    publication: recording.service,
    secretHasher: hasher,
  }));
  const exchanged = await handler(request("POST", "/professional/session/exchange", undefined, { authorization: `Bearer ${"a".repeat(32)}` }));
  assert.equal(exchanged.statusCode, 200);
  assert.equal(exchanged.cookies?.length, 2);
  assert.deepEqual(exchanged.cookies?.map((cookie) => cookie.replace(/=[A-Za-z0-9_-]{43};/u, "=<secret>;")), [
    "roomscan_professional=<secret>; Path=/professional; Max-Age=28800; HttpOnly; Secure; SameSite=Strict",
    "roomscan_professional=<secret>; Path=/publications; Max-Age=28800; HttpOnly; Secure; SameSite=Strict",
  ]);
  const secret = /^roomscan_professional=([A-Za-z0-9_-]{43});/u.exec(exchanged.cookies?.[0] ?? "")?.[1];
  assert.notEqual(secret, undefined);
  assert.equal(exchanged.cookies?.[0]?.includes(`roomscan_professional=${secret}`), true);
  assert.equal(exchanged.cookies?.[1]?.includes(`roomscan_professional=${secret}`), true, "both scoped cookies carry the same opaque session capability");
  assert.equal(exchanged.cookies?.some((cookie) => /Path=\/$/u.test(cookie)), false, "professional state is never wide-scoped to the whole service");

  const staleCanary = "stale-professional-cookie-canary:discard-only";
  const replacement = await handler({
    ...request("POST", "/professional/session/exchange", undefined, { authorization: `Bearer ${"a".repeat(32)}` }),
    cookies: [`roomscan_professional=${staleCanary}`],
  });
  assert.equal(replacement.statusCode, 200, "a fresh app bearer can replace exactly one stale scoped professional cookie");
  assert.equal(replacement.cookies?.length, 2);
  const replacementSecret = /^roomscan_professional=([A-Za-z0-9_-]{43});/u.exec(replacement.cookies?.[0] ?? "")?.[1];
  assert.notEqual(replacementSecret, undefined);
  assert.notEqual(replacementSecret, secret, "replacement cannot reuse the discarded stale session's server capability");
  assert.equal(replacement.cookies?.every((cookie) => cookie.includes(`roomscan_professional=${replacementSecret}`)), true, "both narrow cookie paths are overwritten with the fresh issued secret");
  assert.equal(JSON.parse(replacement.body).csrfToken, Buffer.from(hasher.hash("professional-csrf", replacementSecret!)).toString("base64url"), "the replacement response returns CSRF derived only from its fresh server session");
  assert.equal(JSON.stringify({ replacement, calls: recording.calls }).includes(staleCanary), false, "the discarded professional cookie value is never parsed, hashed, logged, or passed to the service");

  const callsBeforeConfusion = recording.calls.length;
  for (const cookies of [
    [`roomscan_professional=${staleCanary}`, `roomscan_professional=${staleCanary}`],
    [`roomscan_portal=${staleCanary}`],
    [`unrelated_cookie=${staleCanary}`],
  ]) {
    const denied = await handler({
      ...request("POST", "/professional/session/exchange", undefined, { authorization: `Bearer ${"a".repeat(32)}` }),
      cookies,
    });
    assert.equal(denied.statusCode, 401, "the session exchange accepts no unrelated, duplicate, or mixed cookie family");
  }
  assert.equal((await handler({
    ...request("POST", "/professional/session/exchange"),
    cookies: [`roomscan_professional=${staleCanary}`],
  })).statusCode, 401, "a stale cookie alone never authenticates a professional exchange");
  assert.equal(recording.calls.length, callsBeforeConfusion, "rejected ambient cookie combinations do not reach the session issuer");

  const csrf = Buffer.from(hasher.hash("professional-csrf", secret!)).toString("base64url");
  const loggedOut = await handler({
    ...request("POST", "/professional/session/logout", undefined, { "x-roomscan-csrf": csrf }),
    cookies: [`roomscan_professional=${secret}`],
  });
  assert.equal(loggedOut.statusCode, 200);
  assert.equal(recording.calls.filter((call) => call.method === "revokeProfessionalSession").length, 1, "cookie aliases share one server-side session revocation");
  assert.deepEqual(loggedOut.cookies, [
    "roomscan_professional=; Path=/professional; Max-Age=0; HttpOnly; Secure; SameSite=Strict",
    "roomscan_professional=; Path=/publications; Max-Age=0; HttpOnly; Secure; SameSite=Strict",
  ]);
});

test("the professional asset route requires only its scoped cookie and returns no storage capability metadata", async () => {
  const hasher = new PublicationSecretHasher(Buffer.alloc(32, 0x88));
  const recording = recordingPublicationService();
  const handler = createSlice6PublicationHandler(withPortalDocument({
    legacy: async () => response(200, { legacy: true }),
    publication: recording.service,
    secretHasher: hasher,
  }));
  const professional = Buffer.alloc(32, 0x89).toString("base64url");
  const payload = canonicalJson({ assetID: `ast_${"z".repeat(16)}`, byteCount: 3, offset: 4, requestID: "professional-asset-request-001" });

  const accepted = await handler({
    ...request("POST", "/publications/assets/read", payload, { "content-type": "application/json" }),
    cookies: [`roomscan_professional=${professional}`],
  });
  assert.equal(accepted.statusCode, 206);
  assert.equal(accepted.isBase64Encoded, true);
  assert.equal(accepted.headers["content-range"], "bytes 4-6/10");
  assert.equal(accepted.headers["content-disposition"], "attachment");
  assert.equal(accepted.body.includes("objectKey"), false);
  assert.equal(accepted.body.includes("objectVersion"), false);
  assert.equal(recording.calls.at(-1)?.method, "deliverProfessionalAsset");

  const callsBeforeConfusion = recording.calls.length;
  const confused = await handler(request("POST", "/publications/assets/read", payload, { authorization: `Bearer ${"a".repeat(32)}`, "content-type": "application/json" }));
  assert.equal(confused.statusCode, 401, "the asset route does not accept an app bearer or mix it with a browser capability");
  assert.equal(recording.calls.length, callsBeforeConfusion);
});

test("a RoomScan-Link replaces stale portal cookie families without consuming their values", async () => {
  const hasher = new PublicationSecretHasher(Buffer.alloc(32, 0x82));
  const recording = recordingPublicationService("active");
  const handler = createSlice6PublicationHandler(withPortalDocument({
    legacy: async () => response(200, { legacy: true }),
    publication: recording.service,
    secretHasher: hasher,
  }));
  const link = Buffer.alloc(32, 0x83).toString("base64url");
  const staleCanary = "stale-cookie-token-canary:not-a-secret";
  const exchanged = await handler({
    ...request("POST", "/portal/link/exchange", undefined, { authorization: `RoomScan-Link ${link}` }),
    cookies: [
      `roomscan_portal=${staleCanary}`,
      `roomscan_portal_pending=${staleCanary}`,
      `roomscan_feedback=${staleCanary}`,
    ],
  });
  assert.equal(exchanged.statusCode, 200);
  assert.deepEqual(JSON.parse(exchanged.body), { status: "active" });
  assert.match(exchanged.cookies?.[0] ?? "", /^roomscan_portal=[A-Za-z0-9_-]{43}; Path=\/portal;/u);
  assert.equal(exchanged.cookies?.includes("roomscan_portal_pending=; Path=/portal; Max-Age=0; HttpOnly; Secure; SameSite=Strict"), true);
  assert.equal(exchanged.cookies?.includes("roomscan_feedback=; Path=/portal; Max-Age=0; HttpOnly; Secure; SameSite=Strict"), true);
  assert.equal(JSON.stringify({ exchanged, calls: recording.calls }).includes(staleCanary), false, "stale values are neither service arguments nor response/log/audit material");

  const activeSecret = /^roomscan_portal=([A-Za-z0-9_-]{43});/u.exec(exchanged.cookies?.[0] ?? "")?.[1];
  assert.notEqual(activeSecret, undefined);
  const reload = await handler({ ...request("POST", "/portal/snapshot"), cookies: [`roomscan_portal=${activeSecret}`] });
  assert.equal(reload.statusCode, 200, "a fragment-free reload resumes only the replacement portal session");
  assert.equal(recording.calls.at(-1)?.method, "portalSnapshot");

  const callsBeforeConfusion = recording.calls.length;
  assert.equal((await handler({ ...request("POST", "/portal/link/exchange", undefined, { authorization: `Bearer ${"a".repeat(32)}` }), cookies: [`roomscan_portal=${staleCanary}`] })).statusCode, 401);
  assert.equal((await handler({ ...request("POST", "/portal/link/exchange", undefined, { authorization: `RoomScan-Link ${link}` }), cookies: [`roomscan_professional=${staleCanary}`] })).statusCode, 401);
  assert.equal(recording.calls.length, callsBeforeConfusion, "app/professional credentials are denied before the public link capability service path");
});

test("feedback verification forwards only the parsed request identity to the sealed v3 request capability", async () => {
  const hasher = new PublicationSecretHasher(Buffer.alloc(32, 0x86));
  const recording = recordingPublicationService();
  const handler = createSlice6PublicationHandler(withPortalDocument({
    legacy: async () => response(200, { legacy: true }),
    publication: recording.service,
    secretHasher: hasher,
  }));
  const portal = Buffer.alloc(32, 0x87).toString("base64url");
  const requestID = "feedback-verification-request-001";
  const email = "canary.client@example.test";
  const accepted = await handler({
    ...request("POST", "/portal/feedback/verification/request", canonicalJson({ email, requestID }), { "content-type": "application/json" }),
    cookies: [`roomscan_portal=${portal}`],
  });
  assert.equal(accepted.statusCode, 200);
  assert.deepEqual(JSON.parse(accepted.body), { status: "accepted" });
  assert.deepEqual(recording.calls.at(-1), {
    method: "requestFeedbackVerification",
    args: [{ hash: hasher.hash("portal-session", portal) }, { email, requestID }],
  }, "the route does not discard the stable request identity required for v3 lost-response replay");
  assert.equal(JSON.stringify(accepted).includes(email), false, "a feedback email is never reflected into the public response");

  const callsBeforeConfusion = recording.calls.length;
  const confused = await handler({
    ...request("POST", "/portal/feedback/verification/request", canonicalJson({ email, requestID }), { authorization: `Bearer ${"a".repeat(32)}`, "content-type": "application/json" }),
    cookies: [`roomscan_portal=${portal}`],
  });
  assert.equal(confused.statusCode, 401);
  assert.equal(recording.calls.length, callsBeforeConfusion, "app credentials cannot call the portal-only feedback request capability");
});

test("professional and portal paths keep credentials, CSRF, link fragments, feedback capability, and binary chunks in separate lanes", async () => {
  const hasher = new PublicationSecretHasher(Buffer.alloc(32, 0x75));
  const recording = recordingPublicationService();
  const handler = createSlice6PublicationHandler(withPortalDocument({
    legacy: async () => response(200, { legacy: true }),
    publication: recording.service,
    secretHasher: hasher,
    portalOrigin: "https://app.roomscanstudio.test",
  }));
  const professional = Buffer.alloc(32, 0x76).toString("base64url");
  const link = Buffer.alloc(32, 0x77).toString("base64url");
  const portal = Buffer.alloc(32, 0x78).toString("base64url");
  const feedback = Buffer.alloc(32, 0x79).toString("base64url");
  const csrf = Buffer.from(hasher.hash("professional-csrf", professional)).toString("base64url");
  const revokeBody = canonicalJson({ expectedGeneration: 1, linkID: `lnk_${"l".repeat(16)}` });

  const missingCSRF = await handler({ ...request("POST", "/publications/links/revoke", revokeBody, { "content-type": "application/json" }), cookies: [`roomscan_professional=${professional}`] });
  assert.equal(missingCSRF.statusCode, 401, "browser mutations need the independently held CSRF value");
  assert.equal(recording.calls.length, 0);

  const browserMutation = await handler({ ...request("POST", "/publications/links/revoke", revokeBody, { "content-type": "application/json", "x-roomscan-csrf": csrf }), cookies: [`roomscan_professional=${professional}`] });
  assert.equal(browserMutation.statusCode, 200);
  assert.equal(recording.calls.at(-1)?.method, "revokeLink");

  const nativeMutation = await handler(request("POST", "/publications/links/revoke", revokeBody, { authorization: `Bearer ${"a".repeat(32)}`, "content-type": "application/json" }));
  assert.equal(nativeMutation.statusCode, 200, "the frozen app bearer branch remains native-CSRF-free");

  const confused = await handler({ ...request("POST", "/publications/links/revoke", revokeBody, { authorization: `Bearer ${"a".repeat(32)}`, "content-type": "application/json", "x-roomscan-csrf": csrf }), cookies: [`roomscan_professional=${professional}`] });
  assert.equal(confused.statusCode, 401, "a browser cookie and native bearer cannot be merged into a mutation authority");

  const correctedDTO = await handler({ ...request("POST", "/publications/links/create", canonicalJson({ aiPolicy: "enabled", downloadsPolicy: "enabled", feedbackPolicy: "enabled", idempotencyKey: "link-request-0001", snapshotID: `snp_${"s".repeat(16)}` }), { "content-type": "application/json", "x-roomscan-csrf": csrf }), cookies: [`roomscan_professional=${professional}`] });
  assert.equal(correctedDTO.statusCode, 400, "the obsolete downloadsPolicy canary cannot silently widen the link DTO");

  const exchanged = await handler(request("POST", "/portal/link/exchange", undefined, { authorization: `RoomScan-Link ${link}` }));
  assert.equal(exchanged.statusCode, 200);
  assert.deepEqual(JSON.parse(exchanged.body), { status: "pin_required" });
  assert.match(exchanged.cookies?.[0] ?? "", /^roomscan_portal_pending=[A-Za-z0-9_-]{43};/u);
  assert.equal(JSON.stringify(exchanged).includes(link), false, "the bearer link is never reflected into the exchange body, headers, or cookie");

  const rejectedPIN = await handler({ ...request("POST", "/portal/pin/verify", canonicalJson({ pin: "123456" }), { "content-type": "application/json" }), cookies: [`roomscan_portal_pending=${portal}`] });
  assert.equal(rejectedPIN.statusCode, 401, "PIN mutation needs strict same-origin Fetch Metadata");
  const acceptedPIN = await handler({ ...request("POST", "/portal/pin/verify", canonicalJson({ pin: "123456" }), { "content-type": "application/json", origin: "https://app.roomscanstudio.test", "sec-fetch-site": "same-origin" }), cookies: [`roomscan_portal_pending=${portal}`] });
  assert.equal(acceptedPIN.statusCode, 200);
  assert.equal(acceptedPIN.cookies?.length, 2, "successful PIN verification rotates pending state to the active portal cookie");

  const asset = await handler({ ...request("POST", "/portal/asset", canonicalJson({ assetID: `ast_${"z".repeat(16)}`, byteCount: 3, offset: 4, requestID: "portal-request-001" }), { "content-type": "application/json" }), cookies: [`roomscan_portal=${portal}`] });
  assert.equal(asset.statusCode, 206);
  assert.equal(asset.isBase64Encoded, true);
  assert.equal(asset.headers["content-disposition"], "attachment");
  assert.equal(asset.headers["content-range"], "bytes 4-6/10");
  assert.deepEqual(Buffer.from(asset.body, "base64"), Buffer.from([7, 8, 9]));

  const feedbackBody = canonicalJson({ action: "approve", requestID: "feedback-request-01" });
  const confusedFeedback = await handler({ ...request("POST", "/portal/feedback", feedbackBody, { authorization: `Bearer ${"a".repeat(32)}`, "content-type": "application/json" }), cookies: [`roomscan_portal=${portal}`, `roomscan_feedback=${feedback}`] });
  assert.equal(confusedFeedback.statusCode, 401, "feedback's compound portal/capability pair cannot call a project bearer path");
  const acceptedFeedback = await handler({ ...request("POST", "/portal/feedback", feedbackBody, { "content-type": "application/json" }), cookies: [`roomscan_portal=${portal}`, `roomscan_feedback=${feedback}`] });
  assert.equal(acceptedFeedback.statusCode, 200);
  assert.equal(recording.calls.at(-1)?.method, "createFeedback");
  assert.match(acceptedFeedback.cookies?.[0] ?? "", /^roomscan_feedback=; Path=\/portal; Max-Age=0/u, "the one-time feedback capability is cleared after the immutable record");
});

function emptyPublicationService(): PublicationCapabilityService {
  return new Proxy({}, {
    get: () => async () => { throw new Error("unexpected_publication_capability"); },
  }) as PublicationCapabilityService;
}

function recordingPublicationService(portalExchangeStatus: "active" | "pin_required" = "pin_required"): { readonly service: PublicationCapabilityService; readonly calls: Array<{ readonly method: string; readonly args: readonly unknown[] }> } {
  const calls: Array<{ readonly method: string; readonly args: readonly unknown[] }> = [];
  let professionalSessionIssues = 0;
  const service = new Proxy({}, {
    get: (_target, property) => async (...args: readonly unknown[]) => {
      const method = String(property); calls.push({ method, args });
      switch (method) {
      case "issueProfessionalSession": {
        professionalSessionIssues += 1;
        return { cookieSecret: Buffer.alloc(32, 0x83 + professionalSessionIssues).toString("base64url"), expiresAt: "2030-01-01T08:00:00.000Z", bootstrap: { membership: { memberID: `mem_${"a".repeat(64)}`, displayName: `mem_${"a".repeat(64)}`, role: "owner", state: "active" }, subscription: { plan: "professional", status: "active", currentPeriodEnd: "2030-02-01T00:00:00.000Z" }, quota: { policyVersion: 6, portalPeriod: "2030-01", used: 0, reserved: 0, limit: 100 } } };
      }
      case "revokeProfessionalSession": return undefined;
      case "revokeLink": return { status: "revoked" };
      case "exchangePortalLink": return { status: portalExchangeStatus, cookieSecret: Buffer.alloc(32, 0x78).toString("base64url") };
      case "verifyPortalPIN": return { status: "verified" };
      case "portalSnapshot": return { snapshotID: `snp_${"s".repeat(16)}`, kind: "room", presentation: { assetID: `ast_${"a".repeat(16)}`, contentType: "application/json", byteCount: 1 }, rooms: [] };
      case "deliverPortalAsset": return { bytes: Uint8Array.from([7, 8, 9]), contentType: "application/pdf", attachment: true, range: { offset: 4, byteCount: 3, totalBytes: 10 } };
      case "deliverProfessionalAsset": return { bytes: Uint8Array.from([7, 8, 9]), contentType: "application/pdf", attachment: true, range: { offset: 4, byteCount: 3, totalBytes: 10 } };
      case "requestFeedbackVerification": return undefined;
      case "createFeedback": return { status: "recorded", feedbackID: "feedback-public" };
      default: throw new Error(`unexpected_publication_capability:${method}`);
      }
    },
  }) as PublicationCapabilityService;
  return { service, calls };
}

function request(method: "GET" | "POST", rawPath: string, body?: string, headers?: Readonly<Record<string, string>>): ApiGatewayV2Request {
  return { version: "2.0", rawPath, rawQueryString: "", ...(body === undefined ? {} : { body }), ...(headers === undefined ? {} : { headers }), requestContext: { http: { method } } };
}

function response(statusCode: number, body: unknown) {
  return { statusCode, headers: { "cache-control": "no-store", "content-type": "application/json" }, body: JSON.stringify(body) };
}

function withPortalDocument(input: Readonly<Record<string, unknown>>): Parameters<typeof createSlice6PublicationHandler>[0] {
  return { ...input, portalDocument: SAFE_PORTAL_DOCUMENT } as unknown as Parameters<typeof createSlice6PublicationHandler>[0];
}
