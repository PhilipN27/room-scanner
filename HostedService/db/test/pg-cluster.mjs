import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import {
  closeSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  realpathSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';

const execFileAsync = promisify(execFile);

const EXPECTED_MAJOR = 16;
export const POSTGRES_BIN_CANDIDATES = Object.freeze([
  '/opt/homebrew/opt/postgresql@16/bin',
  '/usr/local/opt/postgresql@16/bin',
  '/usr/lib/postgresql/16/bin',
]);

function postgresMajor(versionOutput) {
  const versionMatch = versionOutput.match(/PostgreSQL\)\s+(\d+)\.(\d+)/u);
  return versionMatch ? Number(versionMatch[1]) : null;
}

export async function resolvePostgresBin({
  candidates = POSTGRES_BIN_CANDIDATES,
  execute = execFileAsync,
} = {}) {
  const uniqueCandidates = [...new Set(candidates)];
  for (const candidate of uniqueCandidates) {
    const postgres = path.join(candidate, 'postgres');
    if (!path.isAbsolute(candidate) || !existsSync(postgres)) {
      continue;
    }
    try {
      const { stdout } = await execute(postgres, ['--version']);
      if (postgresMajor(stdout) === EXPECTED_MAJOR) {
        return realpathSync(candidate);
      }
    } catch {
      // Continue to the next explicit PostgreSQL 16 installation candidate.
    }
  }
  throw new Error(
    `PostgreSQL ${EXPECTED_MAJOR} binary directory missing or wrong-version: `
      + uniqueCandidates.join(', '),
  );
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === 'ESRCH') {
      return false;
    }
    throw error;
  }
}

export async function resolveProcessImage(pid, {
  platform = process.platform,
  procRoot = '/proc',
  execute = execFileAsync,
} = {}) {
  assert.equal(Number.isSafeInteger(pid) && pid > 0, true, 'PID must be a positive safe integer');

  if (platform === 'linux') {
    const procImage = path.join(procRoot, String(pid), 'exe');
    try {
      return realpathSync(procImage);
    } catch (error) {
      throw new Error(`Cannot resolve Linux process image for PID ${pid}: ${error.message}`);
    }
  }

  const procPidPath = '/usr/bin/proc_pidpath';
  if (existsSync(procPidPath)) {
    try {
      const { stdout } = await execute(procPidPath, [String(pid)]);
      const image = stdout.trim();
      if (path.isAbsolute(image) && existsSync(image)) {
        return realpathSync(image);
      }
    } catch {
      // Continue to the lsof/ps fallbacks on supported non-Linux hosts.
    }
  }

  for (const lsof of ['/usr/sbin/lsof', '/usr/bin/lsof']) {
    if (!existsSync(lsof)) {
      continue;
    }
    try {
      const { stdout } = await execute(lsof, [
        '-a',
        '-p',
        String(pid),
        '-d',
        'txt',
        '-Fn',
      ]);
      const image = stdout
        .split('\n')
        .find((line) => line.startsWith('n/'))
        ?.slice(1);
      if (image && existsSync(image)) {
        return realpathSync(image);
      }
    } catch {
      // Continue to the next exact executable resolver.
    }
  }

  for (const ps of ['/bin/ps', '/usr/bin/ps']) {
    if (!existsSync(ps)) {
      continue;
    }
    try {
      const { stdout } = await execute(ps, ['-p', String(pid), '-o', 'comm=']);
      const image = stdout.trim();
      if (path.isAbsolute(image) && existsSync(image)) {
        return realpathSync(image);
      }
    } catch {
      // Produce one bounded error below after all safe resolvers fail.
    }
  }
  throw new Error(`Cannot resolve exact process image for PID ${pid} on ${platform}`);
}

async function directChildren(pid) {
  try {
    const { stdout } = await execFileAsync('/usr/bin/pgrep', ['-P', String(pid)]);
    return stdout
      .trim()
      .split(/\s+/u)
      .filter(Boolean)
      .map(Number);
  } catch (error) {
    if (error?.code === 1) {
      return [];
    }
    throw error;
  }
}

async function processTree(rootPid) {
  const pending = [rootPid];
  const seen = new Set();
  const result = [];

  while (pending.length > 0) {
    const pid = pending.shift();
    if (seen.has(pid) || !processExists(pid)) {
      continue;
    }
    seen.add(pid);
    const image = await resolveProcessImage(pid);
    result.push({ pid, image });
    pending.push(...(await directChildren(pid)));
  }

  return result;
}

async function waitForExit(child, timeoutMs = 15_000) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return { code: child.exitCode, signal: child.signalCode };
  }

  return await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`PostgreSQL postmaster did not stop within ${timeoutMs}ms`));
    }, timeoutMs);
    child.once('exit', (code, signal) => {
      clearTimeout(timeout);
      resolve({ code, signal });
    });
    child.once('error', (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}

async function waitForReady(pgBin, socketDir, port) {
  let lastError;
  for (let attempt = 0; attempt < 150; attempt += 1) {
    try {
      await execFileAsync(path.join(pgBin, 'pg_isready'), [
        '-h',
        socketDir,
        '-p',
        String(port),
        '-U',
        'postgres',
        '-d',
        'postgres',
      ]);
      return;
    } catch (error) {
      lastError = error;
      await delay(100);
    }
  }
  throw new Error(`PostgreSQL did not become ready: ${lastError?.stderr ?? lastError}`);
}

async function assertUnixSocketOnly(pgBin, socketDir, port) {
  const { stdout } = await execFileAsync(path.join(pgBin, 'psql'), [
    '-h',
    socketDir,
    '-p',
    String(port),
    '-U',
    'postgres',
    '-d',
    'postgres',
    '-Atc',
    "SELECT setting = '' FROM pg_settings WHERE name = 'listen_addresses'",
  ]);
  assert.equal(stdout.trim(), 't', 'Temporary PostgreSQL must have no TCP listen address');
}

export async function startPostgresCluster() {
  const pgBin = await resolvePostgresBin();
  const postgresImage = realpathSync(path.join(pgBin, 'postgres'));
  const { stdout: versionOutput } = await execFileAsync(postgresImage, ['--version']);
  assert.equal(postgresMajor(versionOutput), EXPECTED_MAJOR, versionOutput.trim());

  const root = mkdtempSync(path.join(tmpdir(), 'rss-pg16-'));
  const dataDir = path.join(root, 'data');
  const socketDir = path.join(root, 'socket');
  const logPath = path.join(root, 'postgres.log');
  const port = 5432;
  mkdirSync(socketDir, { mode: 0o700 });

  try {
    await execFileAsync(path.join(pgBin, 'initdb'), [
      '-D',
      dataDir,
      '--username=postgres',
      '--encoding=UTF8',
      '--no-locale',
      '--auth-local=trust',
      '--auth-host=reject',
    ]);
  } catch (error) {
    rmSync(root, { recursive: true, force: true });
    throw error;
  }

  const logFd = openSync(logPath, 'a');
  const postmaster = spawn(
    postgresImage,
    [
      '-D',
      dataDir,
      '-k',
      socketDir,
      '-h',
      '',
      '-p',
      String(port),
      '-c',
      'unix_socket_permissions=0700',
      '-c',
      'fsync=on',
      '-c',
      'synchronous_commit=on',
    ],
    { detached: false, stdio: ['ignore', logFd, logFd] },
  );

  let stopped = false;
  let cleanupEvidence;

  try {
    await waitForReady(pgBin, socketDir, port);
    await assertUnixSocketOnly(pgBin, socketDir, port);
    const postmasterPid = Number(readFileSync(path.join(dataDir, 'postmaster.pid'), 'utf8').split('\n')[0]);
    assert.equal(postmasterPid, postmaster.pid, 'Directly spawned PID must be the real PostgreSQL postmaster');
    const image = await resolveProcessImage(postmasterPid);
    assert.equal(realpathSync(image), postgresImage);

    return {
      root,
      dataDir,
      socketDir,
      logPath,
      port,
      postmasterPid,
      postgresBin: pgBin,
      postgresVersion: versionOutput.trim(),
      bootstrapConfig: {
        host: socketDir,
        port,
        user: 'postgres',
        database: 'postgres',
        max: 4,
      },
      async stop() {
        if (stopped) {
          return cleanupEvidence;
        }
        stopped = true;

        const before = await processTree(postmasterPid);
        const expectedImage = postgresImage;
        for (const processInfo of before) {
          assert.equal(
            realpathSync(processInfo.image),
            expectedImage,
            `Refusing to stop unresolved non-PostgreSQL image: ${JSON.stringify(processInfo)}`,
          );
        }

        postmaster.kill('SIGTERM');
        const exit = await waitForExit(postmaster);
        await delay(250);
        const surviving = before.filter(({ pid }) => processExists(pid));
        const { stdout: matchingOutput } = await execFileAsync('/usr/bin/pgrep', ['-f', dataDir]).catch((error) => {
          if (error?.code === 1) {
            return { stdout: '' };
          }
          throw error;
        });
        const matching = matchingOutput.trim().split(/\s+/u).filter(Boolean).map(Number);
        assert.deepEqual(surviving, [], `Captured PostgreSQL children survived shutdown: ${JSON.stringify(surviving)}`);
        assert.deepEqual(matching, [], `Orphan process still references temporary cluster: ${matching.join(', ')}`);

        closeSync(logFd);
        rmSync(root, { recursive: true, force: true });
        cleanupEvidence = {
          postmasterPid,
          resolvedProcesses: before,
          exit,
          survivingPids: surviving.map(({ pid }) => pid),
          matchingClusterPids: matching,
          tempRoot: root,
          tempRootRemoved: !existsSync(root),
          tcpRejected: true,
        };
        return cleanupEvidence;
      },
    };
  } catch (error) {
    if (processExists(postmaster.pid)) {
      const image = await resolveProcessImage(postmaster.pid).catch(() => '');
      if (image && realpathSync(image) === postgresImage) {
        postmaster.kill('SIGTERM');
        await waitForExit(postmaster).catch(() => undefined);
      }
    }
    closeSync(logFd);
    const log = existsSync(logPath) ? readFileSync(logPath, 'utf8') : '';
    rmSync(root, { recursive: true, force: true });
    error.message += `\nPostgreSQL log:\n${log}`;
    throw error;
  }
}
