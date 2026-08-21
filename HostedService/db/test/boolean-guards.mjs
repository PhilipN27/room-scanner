import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const migrationsDir = fileURLToPath(new URL('../migrations/', import.meta.url));
const migrationNames = (await readdir(migrationsDir))
  .filter((name) => name.endsWith('.up.sql'))
  .sort();
const sources = await Promise.all(migrationNames.map(async (name) => ({
  name,
  sql: await readFile(path.join(migrationsDir, name), 'utf8'),
})));
const allSql = sources.map(({ name, sql }) => `-- ${name}\n${sql}`).join('\n');

// Every Boolean routine argument is explicitly classified. SQL NULL must not
// bypass either the external signature decision or an operator flag/policy
// mutation.
const functionArgumentBlocks = [...allSql.matchAll(
  /CREATE FUNCTION\s+[^\n]+\(([\s\S]*?)\)\nRETURNS/gmu,
)].map((match) => match[1]);
const booleanArguments = functionArgumentBlocks.flatMap((argumentsSql) => (
  [...argumentsSql.matchAll(/^\s{2}([a-z][a-z0-9_]*) boolean,?$/gmu)]
    .map((match) => match[1])
));
assert.deepEqual(booleanArguments, [
  'signature_is_verified',
  'requested_enabled',
  'requested_editor_publishing_allowed',
  'deliberate_confirmation',
]);
assert.match(allSql, /IF signature_is_verified IS DISTINCT FROM true THEN/u);
assert.match(allSql, /requested_enabled IS NULL/u);
assert.match(allSql, /requested_editor_publishing_allowed IS NULL/u);
assert.match(allSql, /deliberate_confirmation IS NULL/u);
assert.match(allSql, /deliberate_confirmation IS DISTINCT FROM true/u);
assert.doesNotMatch(allSql, /IF\s+NOT\s+signature_is_verified\b/u);

// Other Boolean branch variables are either positive tests where NULL means
// "no row/no action", initialized explicitly, or populated from non-null
// expressions/SELECT EXISTS. Keep these anchors explicit so a new nullable
// negated Boolean guard cannot blend into the migration set unnoticed.
assert.match(allSql, /inserted boolean;[\s\S]*IF inserted THEN/u);
assert.match(allSql, /was_applied boolean := false;[\s\S]*IF was_applied THEN/u);
assert.match(allSql, /removing_owner boolean;[\s\S]*removing_owner :=[\s\S]*IF removing_owner THEN/u);
assert.match(allSql, /SELECT EXISTS \([\s\S]*\)\s+INTO another_owner_exists;[\s\S]*IF NOT another_owner_exists THEN/u);

console.log('BOOLEAN_GUARD_SCAN_SUMMARY boolean_arguments=4 literal_true_guards=2 explicit_null_guards=3 nullable_negated_guards=0 internal_guards_classified=4 status=pass');
