// Composed local oracle: real PostgreSQL roles/reducers, production HTTP
// compositions and workers, and an exact Swift-generated property archive.
// Only object storage, delivery transport, and the authoritative clock are
// synthetic. No browser fixture responses or hand-written reducer outcomes.
import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';
import { PublicationObjectAdapter, mapPublicationQuarantineStorageKey } from '../../dist/service/src/adapters/s3-publication.js';
import { createSlice6DataApiPublicationHandler, createSlice6DataApiPortalDeliveryHandler, createSlice6PublicationWorker } from '../../dist/service/src/composition/publication-application.js';
import { PublicationSecretHasher } from '../../dist/service/src/publication/capabilities.js';
import { validatePublicationArchive } from '../../dist/service/src/publication/archive-validator.js';
import { canonicalJson } from '../../dist/service/src/publication/contracts.js';
import { AesGcmPublicationFeedbackEnvelopeSealer } from '../../dist/service/src/publication/feedback-service.js';
import { DataApiPublicationFeedbackDeliveryWorker } from '../../dist/service/src/persistence/publication-feedback-delivery.js';

const startedAt = new Date().toISOString();
const now = new Date('2030-01-01T12:00:00.000Z');
const clock = { now: () => now };
const key = Buffer.alloc(32, 0x42);
const hasher = new PublicationSecretHasher(key);
const bearer = 'synthetic-composed-owner-access-token-0001';
const archive = Buffer.from((await readFile(new URL('../../fixtures/publication/property-v1.zip.base64', import.meta.url), 'utf8')).trim(), 'base64');
const expected = JSON.parse(await readFile(new URL('../../fixtures/publication/expectations.json', import.meta.url), 'utf8')).fixtures.find(({ name }) => name === 'property-v1');
const validated = await validatePublicationArchive({ reader: { byteLength: archive.length, read: async (offset, length) => archive.subarray(offset, offset + length) }, expected });
const sourceDigest = hash32('composed-source-archive');
const sourceManifestDigest = hash32('composed-source-manifest');
const sourceBindings = validated.sourceBindings.map((binding, index) => ({
  publicRoomKey: binding.publicRoomKey, ...binding.sourceRevision,
  projectPublicID: `prj_composedproject000${index}`, revisionPublicID: `rev_composedrevision00${index}`,
}));
const cluster = await startPostgresCluster();
const bootstrap = new pg.Pool(cluster.bootstrapConfig);
const pools = [];
const clients = [];
const events = [];
const sqlDenials = [];

// Translation only: every statement and parameter originates in real service
// sources. Connections log in as their production role, never SET ROLE from a
// privileged connection. Keep JSON/timestamps in the Data API wire shape.
function dataApi(role) {
  const pool = new pg.Pool({ ...appPoolConfig(cluster, 3), user: role });
  pools.push(pool);
  const transactions = new Map();
  const finish = async (id, operation) => {
    const connection = transactions.get(id); assert.ok(connection);
    try { await connection.query(operation); } finally { transactions.delete(id); connection.release(); }
  };
  const adapter = {
    async begin() { const connection = await pool.connect(); await connection.query('BEGIN'); const transactionId = randomUUID(); transactions.set(transactionId, connection); return { transactionId }; },
    async execute({ transactionId, sql, parameters = [] }) {
      const connection = transactions.get(transactionId); assert.ok(connection);
      const values = [];
      const query = sql.replace(/(?<!:):([a-z_][a-z0-9_]*)/gu, (_match, name) => {
        const parameter = parameters.find((item) => item.name === name); assert.ok(parameter, `missing SQL parameter ${name}`);
        const value = parameter.value;
        values.push(value.kind === 'null' ? null : value.kind === 'blob' ? Buffer.from(value.bytes) : value.value);
        return `$${values.length}`;
      });
      try {
        const result = await connection.query(query, values);
        return { rows: result.rows.map((row) => Object.fromEntries(Object.entries(row).map(([name, value]) => [name,
          value instanceof Date ? value.toISOString() : result.fields.find((field) => field.name === name)?.dataTypeID === 20 && value !== null ? Number(value) : value !== null && typeof value === 'object' && !Buffer.isBuffer(value) ? JSON.stringify(value) : value,
        ]))) };
      } catch (error) { const denial = { role, code: error.code, reason: /^[A-Z_]+$/u.test(error.message) ? error.message : 'sql_error', reducer: /roomscan\.([a-z0-9_]+)/u.exec(sql)?.[1] ?? 'context' }; sqlDenials.push(denial); console.error(`SYSTEM_CHAIN_SQL_FAILURE ${JSON.stringify(denial)}`); throw error; }
    },
    commit: (id) => finish(id, 'COMMIT'), rollback: (id) => finish(id, 'ROLLBACK'),
    async close() { for (const id of transactions.keys()) await finish(id, 'ROLLBACK'); },
  };
  clients.push(adapter); return adapter;
}

const objects = new Map();
let activeReads = 0;
const storage = new PublicationObjectAdapter({
  async presignImmutablePut(input) { return { url: 'https://synthetic-upload.example.invalid/publication', headers: { 'content-length': String(input.contentLength), 'content-type': input.contentType, 'x-amz-checksum-sha256': input.checksumSha256, 'if-none-match': '*' } }; },
  async headCurrent({ physicalKey }) { const value = objects.get(physicalKey); assert.ok(value); return { versionId: value.versionId, contentLength: value.bytes.length, contentType: value.contentType, checksumSha256: createHash('sha256').update(value.bytes).digest('base64') }; },
  async readRangeExact({ physicalKey, versionId, offset, length }) { const value = objects.get(physicalKey); assert.ok(value); assert.equal(versionId, value.versionId); if (physicalKey.includes('/active/')) activeReads++; return Uint8Array.from(value.bytes.subarray(offset, offset + length)); },
  async putImmutable({ physicalKey, bytes, contentType, ifNoneMatch }) { assert.equal(ifNoneMatch, '*'); assert.equal(objects.has(physicalKey), false); const versionId = `synthetic-version-${objects.size + 1}`; objects.set(physicalKey, { bytes: Buffer.from(bytes), contentType, versionId }); return { versionId }; },
});

async function flag(scope, flagKey, sequence) {
  const existing = scope === 'global'
    ? (await bootstrap.query('SELECT version FROM roomscan.global_operational_flags WHERE flag_key=$1', [flagKey])).rows[0]
    : (await bootstrap.query('SELECT version FROM roomscan.workspace_operational_flags WHERE workspace_id=$1 AND flag_key=$2', [ids.workspaceA, flagKey])).rows[0];
  await bootstrap.query('SET ROLE roomscan_operator');
  try { await bootstrap.query("SELECT * FROM roomscan.set_operational_flag($1,$2,$3,true,$4,'composed synthetic chain',$5,$6)", [scope, scope === 'global' ? null : ids.workspaceA, flagKey, existing?.version ?? null, `ofaud_composedchain${sequence}`, now]); }
  finally { await bootstrap.query('RESET ROLE'); }
}
async function seed() {
  await applyMigrations({ pool: bootstrap }); await seedCoreFixtures(bootstrap);
  let sequence = 0;
  for (const name of ['hosted_operations_enabled', 'publication_enabled']) for (const scope of ['global', 'workspace']) await flag(scope, name, ++sequence);
  await bootstrap.query('SET ROLE roomscan_operator');
  try { await bootstrap.query("SELECT * FROM roomscan.activate_quota_policy_v2($1,1,'roomscan-quota-policy-v1','test-only','roomscan-period-v1:composed',10,10,10000000,10000000,10000000,80,1,1,$2)", [ids.workspaceA, now]); }
  finally { await bootstrap.query('RESET ROLE'); }
  for (const [index, binding] of sourceBindings.entries()) {
    const project = index === 0 ? ids.projectA : randomUUID(); const revision = randomUUID();
    if (index !== 0) await bootstrap.query('INSERT INTO roomscan.projects(id,workspace_id,slug,title) VALUES($1,$2,$3,$4)', [project, ids.workspaceA, `composed-${index}`, `Room ${index + 1}`]);
    await bootstrap.query('INSERT INTO roomscan.professional_projects(workspace_id,project_id,public_id,source_project_id,raw_archive_enabled,version,created_at,updated_at) VALUES($1,$2,$3,$4,false,1,$5,$5)', [ids.workspaceA, project, binding.projectPublicID, binding.projectID, now]);
    await bootstrap.query("INSERT INTO roomscan.project_revisions(workspace_id,id,public_id,project_id,source_revision_id,branch_state,working_object_key,working_object_version,working_digest,working_bytes,working_manifest_digest,created_at) VALUES($1,$2,$3,$4,$5,'canonical',$6,'synthetic-source-version', $7,1234,$8,$9)", [ids.workspaceA, revision, binding.revisionPublicID, project, binding.revisionID, `professional-sync/active/working/${binding.revisionPublicID}.zip`, sourceDigest, sourceManifestDigest, now]);
    await bootstrap.query('UPDATE roomscan.professional_projects SET head_revision_id=$1 WHERE workspace_id=$2 AND project_id=$3', [revision, ids.workspaceA, project]);
  }
  const family = randomUUID();
  await bootstrap.query("INSERT INTO roomscan.auth_session_families(id,public_id,principal_id,authentication_epoch,authenticated_at,last_used_at,inactivity_expires_at,absolute_expires_at,policy_version,workspace_id,role,authorization_version,state,created_at) VALUES($1,'fam_composedowner0001',$2,0,$3,$3,$3::timestamptz+interval '1 day',$3::timestamptz+interval '7 days','session-v1',$4,'owner',1,'active',$3)", [family, ids.principalA, now, ids.workspaceA]);
  await bootstrap.query("INSERT INTO roomscan.auth_access_tokens(id,family_id,token_hash,expires_at,principal_id,authentication_epoch,authenticated_at,issued_at,workspace_id,role,authorization_version,state,created_at) VALUES(gen_random_uuid(),$1,$2,$3::timestamptz+interval '1 day',$4,0,$3,$3,$5,'owner',1,'active',$3)", [family, hasher.accessTokenHash(bearer), now, ids.principalA, ids.workspaceA]);
}

function request(path, body, credential = {}) {
  return { version: '2.0', rawPath: path, rawQueryString: '', requestContext: { http: { method: path === '/p' ? 'GET' : 'POST', sourceIp: '192.0.2.1' } }, headers: { 'content-type': 'application/json', origin: 'https://portal.roomscanstudio.test', ...credential.headers }, ...(credential.cookies ? { cookies: credential.cookies } : {}), ...(body === undefined ? {} : { body: canonicalJson(body), isBase64Encoded: false }) };
}
const owner = { headers: { authorization: `Bearer ${bearer}` } };
async function ok(handler, path, body, credential = owner, status = 200) {
  const response = await handler(request(path, body, credential)); assert.equal(response.statusCode, status, `${path}: ${response.body}`);
  return { response, value: JSON.parse(response.body) };
}
const cookie = (response, name) => { const value = response.cookies?.find((entry) => entry.startsWith(`${name}=`))?.split(';')[0]; assert.ok(value, `missing ${name}`); return value; };

const privateTruthTables = ['memberships', 'professional_projects', 'project_raw_archives', 'project_revisions', 'projects'];
async function privateTruthDigest(connection = bootstrap) {
  const truth = {};
  for (const table of privateTruthTables) {
    // The identifiers are a closed local list. Full JSONB rows retain source
    // archive digests/version identities as well as heads and membership.
    const result = await connection.query(`SELECT to_jsonb(t)::text AS row FROM roomscan.${table} t WHERE workspace_id=$1 ORDER BY to_jsonb(t)::text`, [ids.workspaceA]);
    truth[table] = result.rows.map(({ row }) => row);
  }
  assert.equal(truth.project_revisions.length, 2);
  assert.equal(truth.professional_projects.length, 2);
  assert.ok(truth.memberships.length > 0);
  return createHash('sha256').update(JSON.stringify(truth)).digest('hex');
}

try {
  await seed();
  const version = (await bootstrap.query('SHOW server_version')).rows[0].server_version;
  assert.match(version, /^16\./u);
  const apiClient = dataApi('roomscan_api_runtime'); const portalClient = dataApi('roomscan_portal_runtime');
  const workerClient = dataApi('roomscan_publication_worker'); const emailClient = dataApi('roomscan_email_delivery_runtime');
  const common = { clock, accessTokenHmacKey: key, storage, validationWake: { notifyPublicationValidationWake: async () => events.push('validation-wake') }, feedbackEnvelopeSealer: new AesGcmPublicationFeedbackEnvelopeSealer({ keyID: 'composed-feedback-v1', key, random: { bytes: randomBytes } }), feedbackDeliveryWake: { notifyFeedbackDeliveryWake: async () => events.push('feedback-wake') }, portalOrigin: 'https://portal.roomscanstudio.test' };
  const api = createSlice6DataApiPublicationHandler({ ...common, client: apiClient, legacy: async () => ({ statusCode: 404, headers: {}, body: '{}' }) });
  const portal = createSlice6DataApiPortalDeliveryHandler({ ...common, client: portalClient, portalDocument: { stylesheet: await readFile(new URL('../../web/dist/portal.css', import.meta.url)), script: await readFile(new URL('../../web/dist/portal.js', import.meta.url)) } });
  const shell = await portal(request('/p')); assert.equal(shell.statusCode, 200); assert.match(shell.headers['content-security-policy'], /sha256-/u); events.push('built-portal-shell');
  const inventory = (await ok(api, '/professional/properties/list', {})).value;
  assert.deepEqual(inventory.items, [], 'new rooms must not depend on an existing property');
  assert.deepEqual(inventory.roomCandidates.map((room) => room.projectID), sourceBindings.map((binding) => binding.projectPublicID));
  assert.ok(inventory.roomCandidates.every((room) => Object.keys(room).sort().join(',') === 'projectID,title'), 'professional inventory exposes no source content or storage identity');
  events.push('unpublished-synced-room-inventory');
  const property = (await ok(api, '/professional/properties/upsert', { title: 'Composed property', createIdempotencyKey: 'composed-property-create-0001', rooms: sourceBindings.map((binding, index) => ({ projectID: binding.projectPublicID, roomKey: binding.publicRoomKey, roomOrder: index + 1 })) })).value;
  const allocation = (await ok(api, '/publications/snapshots/allocate', { publicationKind: 'property', projectID: sourceBindings[0].projectPublicID, sourceRevisionID: sourceBindings[0].revisionPublicID, sourceRevisionDigest: sourceDigest.toString('hex'), sourceManifestDigest: sourceManifestDigest.toString('hex'), sourceBindings, sourceBindingsSHA256: expected.sourceBindingsSHA256, selectionManifestSHA256: expected.selectionManifestSHA256, approvalSHA256: expected.approvalSHA256, disclosureStatus: 'approved', propertyID: property.propertyID, archiveManifestSHA256: expected.publicationManifest.sha256, archiveSHA256: expected.archive.sha256, archiveByteCount: archive.length, idempotencyKey: 'composed-allocation-0001' }, owner, 202)).value;
  events.push('approved-core-archive-allocated');
  objects.set(mapPublicationQuarantineStorageKey({ allocationPublicID: allocation.allocationID }), { bytes: archive, contentType: 'application/zip', versionId: 'synthetic-quarantine-version-1' });
  await ok(api, '/publications/snapshots/complete', { allocationID: allocation.allocationID, archiveSHA256: expected.archive.sha256, archiveManifestSHA256: expected.publicationManifest.sha256, archiveByteCount: archive.length }, owner, 202);
  const published = await createSlice6PublicationWorker({ client: workerClient, clock, storage }).runOnce(); assert.equal(published.status, 'published', JSON.stringify(published)); events.push('validated-promoted-published');
  const browserSession = await ok(api, '/professional/session/exchange', undefined);
  const professional = { cookies: [cookie(browserSession.response, 'roomscan_professional')], headers: { 'x-roomscan-csrf': browserSession.value.csrfToken } };
  const link = (await ok(api, '/publications/links/create', { snapshotID: published.snapshotID, aiPolicy: 'disabled', feedbackPolicy: 'enabled', idempotencyKey: 'composed-link-create-0001' }, professional)).value;
  const exchange = await ok(portal, '/portal/link/exchange', undefined, { headers: { authorization: `RoomScan-Link ${new URL(link.shareURL).hash.slice(1)}` } }); assert.equal(exchange.value.status, 'active');
  const portalCookie = cookie(exchange.response, 'roomscan_portal'); const clientCredential = { cookies: [portalCookie] }; events.push('link-exchanged');
  const snapshot = (await ok(portal, '/portal/snapshot', undefined, clientCredential)).value;
  const asset = snapshot.presentation; assert.ok(asset);
  const chunkBody = { assetID: asset.assetID, offset: 0, byteCount: asset.byteCount, requestID: 'composed-chunk-before-0001' };
  const chunk = await portal(request('/portal/asset', chunkBody, clientCredential)); assert.equal(chunk.statusCode, 200, chunk.body);
  const presentation = JSON.parse(Buffer.from(chunk.body, 'base64').toString('utf8')); assert.equal(presentation.rooms.length, 2); assert.ok(activeReads > 0); events.push('exact-version-chunk-delivered');
  const privateBefore = (await bootstrap.query('SELECT project_id,head_revision_id,version FROM roomscan.professional_projects ORDER BY project_id')).rows;
  const beforeSHA256 = await privateTruthDigest();
  const control = await bootstrap.connect();
  try {
    await control.query('BEGIN');
    await control.query("UPDATE roomscan.projects SET title='private-truth-positive-control' WHERE workspace_id=$1 AND id=$2", [ids.workspaceA, ids.projectA]);
    assert.notEqual(await privateTruthDigest(control), beforeSHA256, 'private truth comparison must detect a real database mutation');
  } finally {
    await control.query('ROLLBACK');
    control.release();
  }
  assert.equal(await privateTruthDigest(), beforeSHA256, 'private truth positive control must restore completely');
  await ok(portal, '/portal/feedback/verification/request', { email: 'synthetic-client@example.invalid', requestID: 'composed-feedback-request-0001' }, clientCredential);
  let delivered;
  const email = new DataApiPublicationFeedbackDeliveryWorker({ client: emailClient, clock: { nowMs: () => now.getTime() }, random: { bytes: randomBytes }, decryptionKeys: { resolve: async () => key }, delivery: { send: async (message) => { delivered = message; } }, leaseMs: 60000 });
  assert.equal(await email.handleRecord({ messageId: 'composed-feedback-delivery-0001' }), true); assert.ok(delivered); events.push('encrypted-outbox-delivered');
  const verified = await ok(portal, '/portal/feedback/verification/consume', { verificationCode: delivered.verificationCode }, clientCredential); assert.equal(verified.value.status, 'verified');
  const feedbackCredential = { cookies: [portalCookie, cookie(verified.response, 'roomscan_feedback')] };
  const feedback = (await ok(portal, '/portal/feedback', { action: 'approve', requestID: 'composed-feedback-submit-0001' }, feedbackCredential)).value; assert.equal(feedback.status, 'recorded');
  const visible = (await ok(api, '/publications/feedback/list', { snapshotID: published.snapshotID })).value; assert.equal(visible.items.length, 1); assert.equal(visible.items[0].action, 'approve');
  assert.deepEqual((await bootstrap.query('SELECT project_id,head_revision_id,version FROM roomscan.professional_projects ORDER BY project_id')).rows, privateBefore); events.push('feedback-recorded-private-heads-unchanged');
  const afterSHA256 = await privateTruthDigest();
  assert.equal(afterSHA256, beforeSHA256, 'feedback must not alter private project, revision, raw archive, or membership rows');
  // Negative control intentionally omits revocation; the same denial oracle
  // must then fail, proving it reached an active, deliverable capability.
  if (!process.argv.includes('--control-skip-revoke')) await ok(api, '/publications/links/revoke', { linkID: link.linkID, expectedGeneration: link.generation });
  const readsBeforeDenied = activeReads;
  const deniedChunk = await portal(request('/portal/asset', { ...chunkBody, requestID: 'composed-chunk-after-0001' }, clientCredential));
  assert.equal(deniedChunk.statusCode, 503, 'revoked chunk must be denied immediately'); assert.equal(activeReads, readsBeforeDenied, 'revoked capability cannot reach object storage');
  assert.deepEqual(sqlDenials.at(-1), { role: 'roomscan_portal_runtime', code: '42501', reason: 'PORTAL_ACCESS_DENIED', reducer: 'portal_authorize_asset_v1' }, 'denial must come from the live authorization guard, not an incidental transport failure');
  assert.equal((await portal(request('/portal/snapshot', undefined, clientCredential))).statusCode, 503);
  assert.equal((await portal(request('/portal/feedback', { action: 'approve', requestID: 'composed-feedback-after-0001' }, feedbackCredential))).statusCode, 503);
  const deniedExchange = await ok(portal, '/portal/link/exchange', undefined, { headers: { authorization: `RoomScan-Link ${new URL(link.shareURL).hash.slice(1)}` } }); assert.equal(deniedExchange.value.status, 'unavailable'); events.push('revoked-immediate-denial');
  assert.equal(objects.size - 1, 12, 'the exact two-room fixture must promote twelve assets');
  console.log(`SYSTEM_CHAIN_SUMMARY ${JSON.stringify({ schemaVersion: 1, status: 'pass', startedAt, completedAt: new Date().toISOString(), postgresVersion: version, fixtureSHA256: expected.archive.sha256, rooms: 2, roles: 4, promotedAssets: objects.size - 1, privateTruth: { beforeSHA256, afterSHA256, positiveControlDetected: true, tables: privateTruthTables }, events, syntheticPorts: ['object-storage', 'email-transport', 'clock'], realComponents: ['core-golden-archive', 'service-http-compositions', 'postgresql-reducers', 'publication-worker', 'feedback-delivery-worker', 'built-portal-document'] })}`);
} finally {
  for (const client of clients) await client.close();
  await Promise.all(pools.map((pool) => pool.end())); await bootstrap.end(); await cluster.stop();
}
