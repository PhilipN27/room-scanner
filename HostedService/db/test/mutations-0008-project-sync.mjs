import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const dbRoot = fileURLToPath(new URL('../', import.meta.url));
const sourceMigrations = fileURLToPath(new URL('../migrations/', import.meta.url));
const projectSyncIntegration = fileURLToPath(new URL('./integration-0008-project-sync.mjs', import.meta.url));
const securityIntegration = fileURLToPath(new URL('./integration-0008-project-sync-security.mjs', import.meta.url));

async function runOracle(script, migrationsDir) {
  return await execFileAsync(process.execPath, [script], {
    cwd: dbRoot,
    env: {
      ...process.env,
      ...(migrationsDir ? { ROOMSCAN_TEST_MIGRATIONS_DIR: migrationsDir } : {}),
    },
    maxBuffer: 2 * 1024 * 1024,
  });
}

async function expectGreen(label, script) {
  const { stdout } = await runOracle(script);
  assert.match(stdout, /status=pass/u, `${label} baseline did not pass`);
}

async function mutateAndProve({ label, script, needle, replacement, failure }) {
  const root = await mkdtemp(path.join(tmpdir(), `rss-0008-mutation-${label}-`));
  const migrationsDir = path.join(root, 'migrations');
  try {
    await cp(sourceMigrations, migrationsDir, { recursive: true });
    const migrationPath = path.join(migrationsDir, '0008_professional_project_sync.up.sql');
    const original = await readFile(migrationPath, 'utf8');
    assert.equal(original.includes(needle), true, `${label} mutation target drifted`);
    await writeFile(migrationPath, original.replaceAll(needle, replacement));
    await assert.rejects(
      () => runOracle(script, migrationsDir),
      (error) => {
        const output = `${error?.stdout ?? ''}\n${error?.stderr ?? ''}\n${error?.message ?? ''}`;
        return failure.test(output);
      },
      `${label} neutralization did not make its focused oracle fail`,
    );
    console.log(`MUTATION_0008_RED ${label}`);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
  // The working-tree migration is the restored guard.  Run the same real
  // oracle again, rather than treating a source-text replacement as proof.
  await expectGreen(`${label} restored`, script);
  console.log(`MUTATION_0008_RESTORE_GREEN ${label}`);
}

await mutateAndProve({
  label: 'expected-head-cas',
  script: projectSyncIntegration,
  needle: `      AND project.head_revision_id IS NOT DISTINCT FROM target_upload.expected_head_revision_id;`,
  replacement: `      AND true;`,
  failure: /the stale expected-head append must be retained as stale|stale expected-head append/u,
});

await mutateAndProve({
  label: 'targetless-claim',
  script: projectSyncIntegration,
  needle: `  WHERE upload.state = 'validation_pending'
    OR (upload.state = 'validating' AND upload.lease_expires_at <= authoritative_time)`,
  replacement: `  WHERE upload.state IN ('allocated', 'validation_pending')
    OR (upload.state = 'validating' AND upload.lease_expires_at <= authoritative_time)`,
  failure: /allocated bytes must be unclaimable/u,
});

await mutateAndProve({
  label: 'forced-rls',
  script: securityIntegration,
  needle: `ALTER TABLE roomscan.professional_projects FORCE ROW LEVEL SECURITY;`,
  replacement: `-- FORCE ROW LEVEL SECURITY intentionally neutralized by mutation harness`,
  failure: /professional_projects must FORCE RLS/u,
});

await mutateAndProve({
  label: 'raw-target-uniqueness',
  script: projectSyncIntegration,
  needle: `CREATE UNIQUE INDEX project_uploads_raw_target_nonterminal_once
  ON roomscan.project_uploads (workspace_id, target_revision_id)
  WHERE operation = 'attach_raw_archive'
    AND state IN ('allocated', 'validation_pending', 'validating');`,
  replacement: `-- raw target nonterminal uniqueness intentionally neutralized by mutation harness`,
  failure: /the database must reject a second nonterminal raw row for the same target revision/u,
});

await mutateAndProve({
  label: 'claim-source-binding',
  script: projectSyncIntegration,
  needle: `    WHERE project.workspace_id = target_upload.workspace_id
      AND project.project_id = target_upload.project_id
      AND project.public_id = target_upload.project_public_id
    FOR KEY SHARE;`,
  replacement: `    WHERE project.workspace_id = target_upload.workspace_id
      AND project.project_id = target_upload.project_id
      AND true
    FOR KEY SHARE;`,
  failure: /a mismatched uploaded project binding must fail closed/u,
});

await mutateAndProve({
  label: 'opaque-version-schema',
  script: projectSyncIntegration,
  needle: `  working_object_version text NOT NULL CHECK (
    octet_length(working_object_version) BETWEEN 1 AND 1024
    AND working_object_version !~ '[[:cntrl:]]'
  ),`,
  replacement: `  working_object_version text NOT NULL CHECK (true),`,
  failure: /working revision VersionId must enforce the 1024-byte opaque provider VersionId boundary/u,
});

await mutateAndProve({
  label: 'opaque-version-finalizer-input',
  script: projectSyncIntegration,
  needle: `    OR octet_length(requested_quarantine_version) NOT BETWEEN 1 AND 1024
    OR octet_length(requested_active_object_version) NOT BETWEEN 1 AND 1024
    OR requested_quarantine_version ~ '[[:cntrl:]]'
    OR requested_active_object_version ~ '[[:cntrl:]]' THEN`,
  replacement: `    OR false THEN`,
  failure: /worker finalization must reject invalid opaque provider VersionId input/u,
});

await mutateAndProve({
  label: 'unified-64-mib-archive-ceiling',
  script: projectSyncIntegration,
  needle: '67108864',
  replacement: '268435456',
  failure: /64 MiB \+ 1 must fail before (migration|append|raw) quota reservation|persistent project-sync archive records must enforce the same 64 MiB ceiling/u,
});

await mutateAndProve({
  label: 'raw-upload-target-revision-status',
  script: projectSyncIntegration,
  needle: 'COALESCE(upload.proposed_revision_public_id, target_revision.public_id),',
  replacement: 'upload.proposed_revision_public_id,',
  failure: /raw upload status exposes the persisted target revision public ID/u,
});

console.log('MUTATIONS_0008_PROJECT_SYNC_SUMMARY expected_head_cas=detected targetless_claim=detected forced_rls=detected raw_target_uniqueness=detected claim_source_binding=detected opaque_version_schema=detected opaque_version_finalizer_input=detected unified_64_mib_archive_ceiling=detected raw_upload_target_revision_status=detected restored_controls=9 status=pass');
