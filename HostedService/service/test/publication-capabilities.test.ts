import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import type { DataApiClient, SqlResult } from "../src/adapters/data-api.js";
import { PublicationObjectAdapter, PublicationStorageError, type PublicationContentType, type PublicationObjectProvider } from "../src/adapters/s3-publication.js";
import { PUBLICATION_MAX_PRESENTATION_BYTES, canonicalSourceBindingsSHA256 } from "../src/publication/contracts.js";
import {
  DataApiPublicationCapabilityService,
  PublicationCapabilityError,
  PublicationFeedbackCapabilityRepository,
  PublicationSecretHasher,
  type PublicationCredential,
} from "../src/publication/capabilities.js";

const PUA = `pua_${"p".repeat(16)}`;
const SNP = `snp_${"s".repeat(16)}`;
const LNK = `lnk_${"l".repeat(16)}`;
const AST = `ast_${"a".repeat(16)}`;
const KEY = `server/published/active/v1/${PUA}/${AST}.bin`;
const VERSION = "publication-version/one";
const CLOCK = new Date("2030-01-01T00:00:00.000Z");

test("room candidate reads expose only bounded project identity and title through professional credentials", async () => {
  const statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  const client: DataApiClient = {
    begin: async () => ({ transactionId: "candidate-inventory-transaction" }),
    commit: async () => undefined, rollback: async () => undefined,
    execute: async (statement) => {
      statements.push(statement);
      return { rows: [{ project_public_id: `prj_${"c".repeat(16)}`, title: "New synced room", working_object_key: "private-canary", geometry: "private-geometry-canary" }] };
    },
  };
  const service = serviceFor(client, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })));
  assert.deepEqual(await service.listRoomCandidates(appCredential()), [{ projectID: `prj_${"c".repeat(16)}`, title: "New synced room" }]);
  assert.match(statements[0]?.sql ?? "", /publication_list_room_candidates_v1/u);
  assert.deepEqual(statements[0]?.parameters?.find((item) => item.name === "limit")?.value, { kind: "long", value: 100 });
  assert.deepEqual(statements[0]?.parameters?.find((item) => item.name === "cursor")?.value, { kind: "null" });
});

test("portal delivery emits an exact range only after the live finalizer, including a post-read revocation barrier", async () => {
  const events: string[] = [];
  let revoked = false;
  const client = new PublicationDataApiFake(events, () => revoked);
  const bytes = Uint8Array.from([7, 8, 9, 10]);
  const storage = new PublicationObjectAdapter(provider({
    bytes,
    onRead: () => events.push("object-read"),
  }));
  const audits: unknown[] = [];
  const service = serviceFor(client, storage, { notifyPublicationValidationWake: async () => undefined }, undefined, { record: (event) => { audits.push(event); } });
  const session = { hash: Buffer.alloc(32, 0x42) };

  const delivered = await service.deliverPortalAsset(session, { assetID: AST, offset: 0, byteCount: bytes.byteLength, requestID: "portal-request-001" });
  assert.deepEqual(Buffer.from(delivered.bytes), Buffer.from(bytes));
  assert.deepEqual(events.filter((event) => ["authorize", "object-read", "finalize"].includes(event)), ["authorize", "object-read", "finalize"]);
  assert.deepEqual(audits, [{ action: "publication.portal.asset", result: "delivered", bytes: 4 }], "the live service can emit only the publication audit's bounded event shape");

  events.length = 0;
  const revokingStorage = new PublicationObjectAdapter(provider({
    bytes,
    onRead: () => { events.push("object-read"); revoked = true; },
  }));
  const revokingService = serviceFor(client, revokingStorage);
  await assert.rejects(
    () => revokingService.deliverPortalAsset(session, { assetID: AST, offset: 0, byteCount: bytes.byteLength, requestID: "portal-request-002" }),
    (error: unknown) => error instanceof PublicationCapabilityError && error.code === "unavailable",
    "a live DB denial after the exact object read must suppress the bytes",
  );
  assert.deepEqual(events.filter((event) => ["authorize", "object-read", "finalize"].includes(event)), ["authorize", "object-read", "finalize"], "the test reaches the final revocation/accounting reducer rather than merely failing the provider read");
});

test("professional asset delivery is cookie-only, reads one exact active version, and repeats the live finalizer before bytes escape", async () => {
  const events: string[] = [];
  const bytes = Uint8Array.from([11, 12, 13, 14]);
  const client = new PublicationDataApiFake(events);
  const service = serviceFor(client, new PublicationObjectAdapter(provider({ bytes, onRead: () => events.push("object-read") })));
  const input = { assetID: AST, offset: 0, byteCount: bytes.byteLength, requestID: "professional-asset-request-001" } as const;

  const delivered = await service.deliverProfessionalAsset(browserCredential(), input);
  assert.deepEqual(Buffer.from(delivered.bytes), Buffer.from(bytes));
  assert.deepEqual(events.filter((event) => ["professional-authorize", "object-read", "professional-finalize"].includes(event)), ["professional-authorize", "object-read", "professional-finalize"]);
  assert.equal("objectKey" in delivered, false, "the delivery DTO never exposes a private storage key");
  assert.equal("objectVersion" in delivered, false, "the delivery DTO never exposes the immutable provider version");
  assert.equal(client.statements.some((statement) => statement.sql.includes("portal_authorize_professional_asset_v1")), true);
  assert.equal(client.statements.some((statement) => statement.sql.includes("portal_finalize_professional_asset_delivery_v1")), true);

  const beforeNative = client.statements.length;
  await assert.rejects(
    () => service.deliverProfessionalAsset(appCredential(), input),
    (error: unknown) => error instanceof PublicationCapabilityError && error.code === "forbidden",
    "native/app credentials cannot invoke the portal-runtime professional asset reducer",
  );
  assert.equal(client.statements.length, beforeNative, "credential confusion is denied before a portal-runtime database operation");
});

test("professional asset reservation digests bind the same request identity to its professional session", async () => {
  const input = { assetID: AST, offset: 0, byteCount: 4, requestID: "professional-asset-request-002" } as const;
  const first = new PublicationDataApiFake([]);
  const second = new PublicationDataApiFake([]);
  const storage = new PublicationObjectAdapter(provider({ bytes: Uint8Array.from([1, 2, 3, 4]) }));
  await serviceFor(first, storage).deliverProfessionalAsset(browserCredential(0x2a), input);
  await serviceFor(second, storage).deliverProfessionalAsset(browserCredential(0x2b), input);
  const digest = (client: PublicationDataApiFake) => {
    const statement = client.statements.find((candidate) => candidate.sql.includes("portal_authorize_professional_asset_v1"));
    const value = statement?.parameters?.find((parameter) => parameter.name === "request_digest")?.value;
    assert.equal(value?.kind, "blob");
    return Buffer.from((value as { readonly kind: "blob"; readonly bytes: Uint8Array }).bytes).toString("hex");
  };
  assert.notEqual(digest(first), digest(second), "two professional sessions reusing an opaque request ID cannot collide in the workspace reservation namespace");
  assert.equal(JSON.stringify(first.statements).includes(input.requestID), false, "the raw request ID never reaches the portal-runtime SQL capability");
});

test("completion is targetless: it commits only archive identity before the durable wake and never reads quarantine storage", async () => {
  const events: string[] = [];
  const archive = Buffer.from("fixed-publication-archive", "utf8");
  const digest = createHash("sha256").update(archive).digest("hex");
  const client = new PublicationDataApiFake(events);
  const storage = new PublicationObjectAdapter(provider({
    bytes: archive,
    contentType: "application/zip",
    onHead: () => events.push("head-quarantine"),
  }));
  const service = serviceFor(client, storage, { notifyPublicationValidationWake: async () => { events.push("wake"); } });
  const result = await service.completeSnapshot(appCredential(), {
    allocationID: PUA,
    archiveSHA256: digest,
    archiveManifestSHA256: "b".repeat(64),
    archiveByteCount: archive.byteLength,
  });
  assert.deepEqual(result, { status: "validation_pending", allocationID: PUA });
  assert.equal(events.includes("head-quarantine"), false, "the API write role has no quarantine HeadObject capability");
  assert.ok(events.indexOf("complete") < events.indexOf("commit"));
  assert.ok(events.indexOf("commit") < events.indexOf("wake"));
  assert.equal(JSON.stringify(result).includes(VERSION), false, "an opaque provider version is never returned to a client");
  assert.equal(client.statements.some((statement) => statement.sql.includes("publication_complete_v2") && !statement.sql.includes("quarantine_version")), true, "only the worker binds a provider version after claiming the queued job");
});

test("allocation idempotency uses a server HMAC scoped to the resolved credential instead of a public constant key", async () => {
  const first = new AllocationDataApiFake();
  const second = new AllocationDataApiFake();
  const storage = new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) }));
  await serviceFor(first, storage).allocateSnapshot(appCredential(0x21), allocationInput("allocation-operation-01"));
  await serviceFor(second, storage).allocateSnapshot(appCredential(0x22), allocationInput("allocation-operation-01"));
  const digest = (client: AllocationDataApiFake) => {
    const value = client.statements[0]?.parameters?.find((parameter) => parameter.name === "idempotency_digest")?.value;
    assert.equal(value?.kind, "blob");
    return Buffer.from((value as { readonly kind: "blob"; readonly bytes: Uint8Array }).bytes).toString("hex");
  };
  assert.notEqual(digest(first), digest(second), "two credential scopes reusing an operation key cannot collide in the principal-scoped DB uniqueness domain");
  assert.equal(JSON.stringify(first.statements).includes("allocation-operation-01"), false, "the raw allocation operation key never reaches SQL");
});

test("browser link rotation is the only response that receives a one-time share URL, while stored SQL receives hashes rather than the secret", async () => {
  const events: string[] = [];
  const client = new PublicationDataApiFake(events);
  const service = serviceFor(client, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })), undefined, "https://app.roomscanstudio.test");
  const browser = await service.createLink(browserCredential(), { snapshotID: SNP, aiPolicy: "enabled", feedbackPolicy: "enabled", idempotencyKey: "browser-link-create-01" });
  const url = browser.shareURL;
  assert.equal(typeof url, "string");
  assert.match(url as string, /^https:\/\/app\.roomscanstudio\.test\/p#[A-Za-z0-9_-]{43}$/u);
  const rawSecret = (url as string).split("#")[1]!;
  assert.equal(JSON.stringify(client.statements).includes(rawSecret), false, "the browser-only bearer secret does not cross the persistence boundary");
  const native = await service.createLink(appCredential(), { snapshotID: SNP, aiPolicy: "enabled", feedbackPolicy: "enabled", idempotencyKey: "native-link-create-001" });
  assert.equal("shareURL" in native, false, "native account credentials never receive browser bearer material");
  const create = client.statements.find((statement) => statement.sql.includes("publication_create_link_v1"));
  assert.ok(create);
  assert.equal(create?.parameters?.some((parameter) => parameter.name === "expires_at" && parameter.value.kind === "null"), true, "omitted expiry is a DB-derived 30-day default, never client/server clock drift");
});

test("property creation supplies only a server-HMAC idempotency digest and lets v2 generate the hosted prop_ identity", async () => {
  const client = new PropertyCreateDataApiFake();
  const service = serviceFor(client, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })));
  const result = await service.upsertProperty(appCredential(), {
    title: "North unit",
    createIdempotencyKey: "property-create-request-01",
    rooms: [{ roomKey: "room-north", roomOrder: 1, projectID: `prj_${"p".repeat(16)}` }],
  });
  assert.deepEqual(result, { status: "created", propertyID: `prop_${"r".repeat(16)}`, version: 1, roomCount: 1 });
  const statement = client.statements.at(-1);
  assert.ok(statement?.sql.includes("publication_upsert_property_v2"));
  assert.equal(statement?.parameters?.some((parameter) => parameter.name === "property_public_id" && parameter.value.kind === "null"), true, "the app never pre-allocates a prop_ identifier");
  const createDigest = statement?.parameters?.find((parameter) => parameter.name === "create_idempotency_digest");
  assert.equal(createDigest?.value.kind, "blob");
  assert.equal(JSON.stringify(statement).includes("property-create-request-01"), false, "only the server-HMAC digest reaches persistence");
});

test("browser link replay deterministically reconstructs one capability while native responses remain secret-free", async () => {
  const client = new LinkReplayDataApiFake();
  const service = serviceFor(client, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })), undefined, "https://app.roomscanstudio.test");
  const input = { snapshotID: SNP, aiPolicy: "enabled" as const, feedbackPolicy: "enabled" as const, idempotencyKey: "browser-link-replay-01" };
  const created = await service.createLink(browserCredential(), input);
  const replay = await service.createLink(browserCredential(), input);
  assert.equal(created.status, "created");
  assert.equal(replay.status, "existing");
  assert.equal(created.shareURL, replay.shareURL, "a lost browser response reconstructs the same fragment capability without storing raw token bytes");
  assert.match(created.shareURL as string, /^https:\/\/app\.roomscanstudio\.test\/p#[A-Za-z0-9_-]{43}$/u);
  const tokenHashes = client.statements.map((statement) => statement.parameters?.find((parameter) => parameter.name === "token_hash")?.value).filter((value): value is { readonly kind: "blob"; readonly bytes: Uint8Array } => value?.kind === "blob").map((value) => Buffer.from(value.bytes).toString("hex"));
  assert.deepEqual(tokenHashes, [tokenHashes[0], tokenHashes[0]], "the database sees one stable hash, never the bearer");
  const native = await service.createLink(appCredential(), { ...input, idempotencyKey: "native-link-replay-0001" });
  assert.equal("shareURL" in native, false, "native account credentials cannot receive a raw link capability");
});

test("professional link list consumes v2 bounded feedback aggregates and never projects feedback body or identity", async () => {
  const client = new LinkListDataApiFake();
  const service = serviceFor(client, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })));
  const items = await service.listLinks(browserCredential(), { limit: 10 });
  assert.deepEqual(items, [{
    linkID: LNK,
    snapshotID: SNP,
    generation: 1,
    state: "active",
    expiresAt: "2030-01-31T00:00:00.000Z",
    pinRequired: false,
    aiEnabled: true,
    feedbackEnabled: true,
    feedbackCount: 10_000,
    feedbackCountCapped: true,
    latestFeedbackAction: "approve",
    latestFeedbackAt: "2030-01-01T00:00:00.000Z",
  }]);
  assert.equal(JSON.stringify(items).includes("comment"), false);
  assert.equal(JSON.stringify(items).includes("email"), false);
  assert.equal(client.statements[0]?.sql.includes("publication_list_links_v2"), true);
});

test("PIN material is derived with the fixed DB parameters and the raw six digits never enter a SQL statement", async () => {
  const events: string[] = [];
  const client = new PublicationDataApiFake(events);
  const service = serviceFor(client, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })));
  const outcome = await service.verifyPortalPIN({ hash: Buffer.alloc(32, 0x57) }, "123456");
  assert.deepEqual(outcome, { status: "verified" });
  const pinStatements = client.statements.filter((statement) => statement.sql.includes("portal_pin_") || statement.sql.includes("portal_verify_pin_"));
  assert.equal(pinStatements.length, 2);
  assert.equal(JSON.stringify(pinStatements).includes("123456"), false, "the verifier is the only PIN value passed to the database");
});

test("professional session exchange composes a current privacy-bounded membership with the DB subscription/quota bootstrap", async () => {
  const client = new ProfessionalBootstrapDataApiFake();
  const service = serviceFor(client, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })));
  const issued = await service.issueProfessionalSession(Buffer.alloc(32, 0x68));

  assert.match(issued.cookieSecret, /^[A-Za-z0-9_-]{43}$/u);
  assert.deepEqual(issued.bootstrap, {
    membership: { memberID: "mem_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", displayName: "mem_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", role: "owner", state: "active" },
    subscription: { plan: "professional", status: "active", currentPeriodEnd: "2030-02-01T00:00:00.000Z" },
    quota: { policyVersion: 6, portalPeriod: "2030-01", used: 12, reserved: 3, limit: 1000 },
  }, "the browser gets one pseudonymous current membership record, never raw email or principal identity");
  assert.equal(client.statements.some((statement) => statement.sql.includes("professional_list_members_v1")), true, "membership is resolved with the newly issued server-side browser capability rather than claimed by the app bearer");

  const members = await service.listMembers({ kind: "web_session", hash: Buffer.alloc(32, 0x69), browser: true }, { limit: 10 });
  assert.deepEqual(members, [{ memberID: "mem_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", displayName: "mem_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", role: "owner", state: "active", current: true }]);
});

test("portal snapshot invokes the property-room reducer only for property snapshots and returns live capability flags", async () => {
  const propertyClient = new PortalSnapshotDataApiFake("property", false);
  const property = await serviceFor(propertyClient, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })))
    .portalSnapshot({ hash: Buffer.alloc(32, 0x6a) }) as Readonly<{ readonly rooms: unknown; readonly feedbackEnabled: boolean; readonly aiReadyPackageEnabled: boolean }>;
  assert.deepEqual(property.rooms, [
    { roomKey: "room-living", roomOrder: 1 },
    { roomKey: "room-kitchen", roomOrder: 2 },
  ], "positive control proves property snapshots reach their ordered independent-room reducer");
  assert.deepEqual({ feedbackEnabled: property.feedbackEnabled, aiReadyPackageEnabled: property.aiReadyPackageEnabled }, { feedbackEnabled: true, aiReadyPackageEnabled: true });
  assert.equal(propertyClient.propertyRoomReducerCalls, 1);

  const roomClient = new PortalSnapshotDataApiFake("room", true);
  await assert.doesNotReject(
    () => serviceFor(roomClient, new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })))
      .portalSnapshot({ hash: Buffer.alloc(32, 0x6b) }),
    "an injected room reducer call must be detected: room snapshots are self-contained and return no property-room list",
  );
  const room = await serviceFor(new PortalSnapshotDataApiFake("room", false), new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })))
    .portalSnapshot({ hash: Buffer.alloc(32, 0x6c) }) as Readonly<{ readonly rooms: unknown }>;
  assert.deepEqual(room.rooms, []);
});

test("feedback capability repository exposes only immutable portal feedback SQL, never project mutation capability", async () => {
  const calls: string[] = [];
  const repository = new PublicationFeedbackCapabilityRepository({
    query: async (sql) => {
      calls.push(sql);
      return { rows: [{ status: "recorded", feedback_id: "11111111-1111-4111-8111-111111111111", display_label: "Verified guest" }] };
    },
    now: () => new Date(CLOCK),
    hasher: new PublicationSecretHasher(Buffer.alloc(32, 0x61)),
  });
  const result = await repository.create({ portalSessionHash: Buffer.alloc(32, 0x62), feedbackTokenHash: Buffer.alloc(32, 0x63) }, { action: "approve", requestID: "feedback-request-001" });
  assert.deepEqual(result, { status: "recorded", feedbackID: "11111111-1111-4111-8111-111111111111", displayName: "Verified guest" });
  assert.deepEqual(Object.getOwnPropertyNames(PublicationFeedbackCapabilityRepository.prototype).sort(), ["constructor", "create"]);
  assert.equal(calls.length, 1);
  assert.match(calls[0] ?? "", /portal_create_feedback_v1/u);
  assert.equal(/project_|revision_|concept_|membership_/u.test(calls[0] ?? ""), false, "the feedback repository cannot select a project-mutation path");
});

test("feedback verification v3 atomically seals a bounded envelope, uses a request identity, and wakes only after commit", async () => {
  const events: string[] = [];
  const client = new FeedbackRequestDataApiFake(events);
  const seen: Array<Readonly<{ readonly email: string; readonly verificationCode: string }>> = [];
  const legacyDelivery = { sendFeedbackVerification: async () => { throw new Error("legacy-provider-callback-must-not-run"); } };
  const service = new DataApiPublicationCapabilityService({
    client,
    clock: { now: () => new Date(CLOCK) },
    hasher: new PublicationSecretHasher(Buffer.alloc(32, 0x64)),
    storage: new PublicationObjectAdapter(provider({ bytes: Uint8Array.of(1) })),
    validationWake: { notifyPublicationValidationWake: async () => undefined },
    // This deliberately reaches the future request-side sealer with the
    // largest database-permitted ciphertext.  It proves that v3 does not
    // accidentally reuse the generic 64-byte hash/blob guard.
    feedbackEnvelopeSealer: {
      seal: (input: Readonly<{ readonly email: string; readonly verificationCode: string }>) => {
        seen.push(input);
        return Object.freeze({ keyID: "feedback-v1", iv: Buffer.alloc(12, 0x11), ciphertext: Buffer.alloc(4_096, 0x22), authenticationTag: Buffer.alloc(16, 0x33) });
      },
    },
    feedbackDeliveryWake: { notifyFeedbackDeliveryWake: async () => { events.push("feedback-wake"); } },
    // A Slice 5-shaped optional delivery callback must be ignored completely;
    // the atomic v3 outbox is the only delivery handoff.
    feedbackDelivery: legacyDelivery,
  } as unknown as ConstructorParameters<typeof DataApiPublicationCapabilityService>[0]);

  await (service as unknown as { requestFeedbackVerification(session: { readonly hash: Uint8Array }, input: { readonly email: string; readonly requestID: string }): Promise<void> }).requestFeedbackVerification(
    { hash: Buffer.alloc(32, 0x65) },
    { email: "verified.client@example.test", requestID: "feedback-request-v3-0001" },
  );

  assert.equal(seen.length, 1, "the API lane seals the email and one-time verification code before the reducer call");
  assert.match(seen[0]?.verificationCode ?? "", /^[A-Za-z0-9_-]{43}\.[A-Za-z0-9_-]{43}$/u);
  assert.equal(events.indexOf("commit") < events.indexOf("feedback-wake"), true, "the targetless wake occurs only after the v3 outbox transaction commits");
  const request = client.statements.find((statement) => statement.sql.includes("portal_request_feedback_verification_v3"));
  assert.ok(request, "the request path uses the atomic v3 reducer rather than a post-commit provider callback");
  const ciphertext = request?.parameters?.find((parameter) => parameter.name === "ciphertext")?.value;
  assert.equal(ciphertext?.kind, "blob");
  assert.equal((ciphertext as { readonly kind: "blob"; readonly bytes: Uint8Array }).bytes.byteLength, 4_096);
  assert.equal(JSON.stringify({ statements: client.statements, events }).includes("verified.client@example.test"), false, "email is sealed before persistence and never enters local structured events");
  assert.equal(JSON.stringify({ statements: client.statements, events }).includes(seen[0]?.verificationCode ?? ""), false, "the verification code is never persisted or reflected as plaintext");
});

test("the storage adapter itself rejects oversized promoted JSON before a provider write", async () => {
  const oversized = new Uint8Array(PUBLICATION_MAX_PRESENTATION_BYTES + 1);
  const adapter = new PublicationObjectAdapter(provider({ bytes: oversized, contentType: "application/json" }));
  await assert.rejects(
    () => adapter.putActiveDerivative({ allocationPublicID: PUA, assetPublicID: AST, kind: "presentation", bytes: oversized, contentType: "application/json" }),
    (error: unknown) => error instanceof PublicationStorageError && error.code === "invalid_publication_storage_key",
    "the provider must never receive a JSON presentation/geometry object above its eight-mebibyte boundary",
  );
});

function serviceFor(client: DataApiClient, storage: PublicationObjectAdapter, wake: { notifyPublicationValidationWake(): Promise<void> } = { notifyPublicationValidationWake: async () => undefined }, portalOrigin?: string, publicationAudit?: { record(event: { readonly action: string; readonly result: string; readonly bytes?: number }): void }): DataApiPublicationCapabilityService {
  return new DataApiPublicationCapabilityService({
    client,
    clock: { now: () => new Date(CLOCK) },
    hasher: new PublicationSecretHasher(Buffer.alloc(32, 0x31)),
    storage,
    validationWake: wake,
    feedbackEnvelopeSealer: {
      seal: () => Object.freeze({ keyID: "feedback-test-v1", iv: Buffer.alloc(12, 0x31), ciphertext: Buffer.alloc(32, 0x32), authenticationTag: Buffer.alloc(16, 0x33) }),
    },
    feedbackDeliveryWake: { notifyFeedbackDeliveryWake: async () => undefined },
    ...(portalOrigin === undefined ? {} : { portalOrigin }),
    ...(publicationAudit === undefined ? {} : { publicationAudit }),
  });
}

function appCredential(byte = 0x21): PublicationCredential { return { kind: "app_bearer", hash: Buffer.alloc(32, byte), browser: false }; }
function browserCredential(byte = 0x22): PublicationCredential { return { kind: "web_session", hash: Buffer.alloc(32, byte), browser: true }; }

function allocationInput(idempotencyKey: string) {
  const sourceBindings = [{
    publicRoomKey: "room-north",
    projectPublicID: `prj_${"p".repeat(16)}`,
    revisionPublicID: `rev_${"r".repeat(16)}`,
    projectID: "project-north",
    revisionID: "revision-north",
    coordinateSpaceEpochID: "epoch-north",
    packageSchemaVersion: "room-scan-project-v2" as const,
    semanticSHA256: "a".repeat(64),
    revisionManifestSHA256: "b".repeat(64),
  }];
  return {
    publicationKind: "room" as const,
    projectID: sourceBindings[0]!.projectPublicID,
    sourceRevisionID: sourceBindings[0]!.revisionPublicID,
    sourceRevisionDigest: "c".repeat(64),
    sourceManifestDigest: "d".repeat(64),
    sourceBindings,
    sourceBindingsSHA256: canonicalSourceBindingsSHA256(sourceBindings),
    selectionManifestSHA256: "e".repeat(64),
    approvalSHA256: "f".repeat(64),
    disclosureStatus: "approved" as const,
    archiveManifestSHA256: "1".repeat(64),
    archiveSHA256: createHash("sha256").update(Uint8Array.of(1)).digest("hex"),
    archiveByteCount: 1,
    idempotencyKey,
  };
}

function provider(input: { readonly bytes: Uint8Array; readonly contentType?: PublicationContentType; readonly onRead?: () => void; readonly onHead?: () => void }): PublicationObjectProvider {
  const contentType = input.contentType ?? "image/png";
  const checksum = createHash("sha256").update(input.bytes).digest("base64");
  return {
    presignImmutablePut: async () => ({ url: "https://upload.roomscanstudio.test/immutable", headers: { "content-length": String(input.bytes.byteLength), "content-type": "application/zip", "x-amz-checksum-sha256": checksum, "if-none-match": "*" } }),
    headCurrent: async () => {
      input.onHead?.();
      return { versionId: VERSION, contentLength: input.bytes.byteLength, contentType, checksumSha256: checksum };
    },
    readRangeExact: async ({ offset, length }) => {
      input.onRead?.();
      return Uint8Array.from(input.bytes.subarray(offset, offset + length));
    },
    putImmutable: async () => ({ versionId: VERSION }),
  };
}

class PublicationDataApiFake implements DataApiClient {
  readonly statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  #nextTransaction = 0;
  constructor(private readonly events: string[], private readonly revoked: () => boolean = () => false) {}
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `publication-tx-${this.#nextTransaction++}` }; }
  async commit(): Promise<void> { this.events.push("commit"); }
  async rollback(): Promise<void> { this.events.push("rollback"); }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.statements.push(input);
    if (input.sql.includes("portal_authorize_asset_v1")) {
      this.events.push("authorize");
      return { rows: [deliveryRow()] };
    }
    if (input.sql.includes("portal_finalize_asset_delivery_v1")) {
      this.events.push("finalize");
      if (this.revoked()) throw new Error("synthetic live revocation");
      return { rows: [deliveryRow()] };
    }
    if (input.sql.includes("portal_authorize_professional_asset_v1")) {
      this.events.push("professional-authorize");
      return { rows: [deliveryRow()] };
    }
    if (input.sql.includes("portal_finalize_professional_asset_delivery_v1")) {
      this.events.push("professional-finalize");
      if (this.revoked()) throw new Error("synthetic live professional revocation");
      return { rows: [deliveryRow()] };
    }
    if (input.sql.includes("publication_complete_v2")) {
      this.events.push("complete");
      return { rows: [{ status: "validation_pending", allocation_public_id: PUA }] };
    }
    if (input.sql.includes("publication_create_link_v1")) {
      return { rows: [{ status: "created", link_public_id: LNK, generation: 1, expires_at: "2030-01-31T00:00:00.000Z", pin_required: false }] };
    }
    if (input.sql.includes("portal_pin_parameters_v1")) {
      return { rows: [{ pin_salt: Buffer.alloc(16, 0x41), scrypt_n: 16_384, scrypt_r: 8, scrypt_p: 1, key_length: 32 }] };
    }
    if (input.sql.includes("portal_verify_pin_v1")) return { rows: [{ status: "verified" }] };
    throw new Error(`unexpected SQL: ${input.sql}`);
  }
}

class FeedbackRequestDataApiFake implements DataApiClient {
  readonly statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  #transaction = 0;
  constructor(private readonly events: string[]) {}
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `feedback-request-${this.#transaction++}` }; }
  async commit(): Promise<void> { this.events.push("commit"); }
  async rollback(): Promise<void> { this.events.push("rollback"); }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.statements.push(input);
    if (input.sql.includes("portal_request_feedback_verification_v3")) {
      this.events.push("feedback-v3");
      return { rows: [{ status: "issued", challenge_id: "11111111-1111-4111-8111-111111111111", expires_at: "2030-01-01T00:15:00.000Z", retry_after: null }] };
    }
    throw new Error(`unexpected SQL: ${input.sql}`);
  }
}

class AllocationDataApiFake implements DataApiClient {
  readonly statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  #transaction = 0;
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `allocation-${this.#transaction++}` }; }
  async commit(): Promise<void> { /* isolated reducer */ }
  async rollback(): Promise<void> { /* isolated reducer */ }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.statements.push(input);
    if (!input.sql.includes("publication_allocate_v1")) throw new Error(`unexpected SQL: ${input.sql}`);
    return { rows: [{ status: "allocated", allocation_public_id: PUA, allocation_expires_at: "2030-01-01T01:00:00.000Z" }] };
  }
}

class PropertyCreateDataApiFake implements DataApiClient {
  readonly statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  #transaction = 0;
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `property-create-${this.#transaction++}` }; }
  async commit(): Promise<void> { /* isolated reducer */ }
  async rollback(): Promise<void> { /* isolated reducer */ }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.statements.push(input);
    if (!input.sql.includes("publication_upsert_property_v2")) throw new Error(`unexpected SQL: ${input.sql}`);
    return { rows: [{ status: "created", property_public_id: `prop_${"r".repeat(16)}`, curation_version: 1, room_count: 1 }] };
  }
}

class LinkReplayDataApiFake implements DataApiClient {
  readonly statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  #transaction = 0;
  #calls = 0;
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `link-replay-${this.#transaction++}` }; }
  async commit(): Promise<void> { /* isolated reducer */ }
  async rollback(): Promise<void> { /* isolated reducer */ }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.statements.push(input);
    if (!input.sql.includes("publication_create_link_v1")) throw new Error(`unexpected SQL: ${input.sql}`);
    this.#calls += 1;
    return { rows: [{ status: this.#calls === 1 ? "created" : "existing", link_public_id: LNK, generation: 1, expires_at: "2030-01-31T00:00:00.000Z", pin_required: false }] };
  }
}

class LinkListDataApiFake implements DataApiClient {
  readonly statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  #transaction = 0;
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `link-list-${this.#transaction++}` }; }
  async commit(): Promise<void> { /* isolated reducer */ }
  async rollback(): Promise<void> { /* isolated reducer */ }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.statements.push(input);
    if (!input.sql.includes("publication_list_links_v2")) throw new Error(`unexpected SQL: ${input.sql}`);
    return { rows: [{
      link_public_id: LNK,
      snapshot_public_id: SNP,
      generation: 1,
      state: "active",
      expires_at: "2030-01-31T00:00:00.000Z",
      pin_required: false,
      ai_enabled: true,
      feedback_enabled: true,
      feedback_count: 10_000,
      feedback_count_capped: true,
      latest_feedback_kind: "approve",
      latest_feedback_at: "2030-01-01T00:00:00.000Z",
    }] };
  }
}

class ProfessionalBootstrapDataApiFake implements DataApiClient {
  readonly statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  #nextTransaction = 0;
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `professional-bootstrap-${this.#nextTransaction++}` }; }
  async commit(): Promise<void> { /* each reducer is atomic in the production Data API transaction */ }
  async rollback(): Promise<void> { /* no mutable test state */ }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.statements.push(input);
    if (input.sql.includes("resolve_access_context")) return { rows: [{ workspace_id: "11111111-1111-4111-8111-111111111111" }] };
    if (input.sql.includes("professional_session_issue_v1")) return { rows: [{ status: "issued", session_id: "22222222-2222-4222-8222-222222222222", expires_at: "2030-01-01T08:00:00.000Z" }] };
    if (input.sql.includes("professional_session_bootstrap_v1")) return { rows: [{ plan_key: "professional", subscription_status: "active", current_period_end: "2030-02-01T00:00:00.000Z", quota_policy_version: 6, portal_period_key: "2030-01", portal_bytes_used: 12, portal_bytes_reserved: 3, portal_bytes_limit: 1000 }] };
    if (input.sql.includes("professional_list_members_v1")) return { rows: [{ member_reference: "mem_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", role: "owner", state: "active", is_current_principal: true, updated_at: "2030-01-01T00:00:00.000Z" }] };
    throw new Error(`unexpected SQL: ${input.sql}`);
  }
}

class PortalSnapshotDataApiFake implements DataApiClient {
  propertyRoomReducerCalls = 0;
  #transaction = 0;
  constructor(private readonly kind: "room" | "property", private readonly failOnPropertyReducer: boolean) {}
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `portal-snapshot-${this.#transaction++}` }; }
  async commit(): Promise<void> { /* each publication reducer is atomic in production */ }
  async rollback(): Promise<void> { /* no test state */ }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    if (input.sql.includes("portal_get_snapshot_v2")) return { rows: [{ snapshot_public_id: SNP, publication_kind: this.kind, feedback_enabled: true, ai_enabled: true }] };
    if (input.sql.includes("portal_lookup_presentation_asset_v1")) return { rows: [{ asset_public_id: AST, content_type: "application/json", asset_bytes: 17 }] };
    if (input.sql.includes("portal_list_property_rooms_v1")) {
      this.propertyRoomReducerCalls += 1;
      if (this.failOnPropertyReducer) throw new Error("room-snapshot-must-not-call-property-room-reducer");
      return { rows: [{ room_key: "room-living", room_order: 1 }, { room_key: "room-kitchen", room_order: 2 }] };
    }
    throw new Error(`unexpected SQL: ${input.sql}`);
  }
}

function deliveryRow() {
  return { status: "allowed", asset_public_id: AST, object_key: KEY, object_version: VERSION, content_type: "image/png", asset_bytes: 4, byte_offset: 0, byte_length: 4, delivered_bytes: 0, already_accounted: false } as const;
}
