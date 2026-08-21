import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const sourceDir = fileURLToPath(new URL('../migrations/', import.meta.url));
const root = mkdtempSync(path.join(tmpdir(), 'rss-accepted-0006-'));
export const accepted0006MigrationsDir = path.join(root, 'migrations');
mkdirSync(accepted0006MigrationsDir);
for (const name of readdirSync(sourceDir).sort()) {
  if (/^000[1-6]_[a-z0-9_]+\.up\.sql$/u.test(name)) {
    copyFileSync(path.join(sourceDir, name), path.join(accepted0006MigrationsDir, name));
  }
}

process.once('exit', () => {
  rmSync(root, { recursive: true, force: true });
});
