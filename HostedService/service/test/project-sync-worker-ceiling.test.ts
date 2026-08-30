import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";

import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "../src/contracts/project-sync.js";

test("a 64 MiB real Core-derived working archive validates after an invalid claim within the production worker envelope", async () => {
  const runner = new URL("./project-sync-worker-ceiling-runner.js", import.meta.url);
  const result = await runChild(process.execPath, [
    "--expose-gc",
    "--max-old-space-size=1024",
    runner.pathname,
  // The child first constructs and hashes a test-only 64 MiB ZIP before the
  // separately measured production worker run. Keep a bounded setup margin
  // without weakening the worker's strict 30-second assertion below.
  ], 60_000);
  assert.equal(result.exitCode, 0, result.stderr);
  const report = JSON.parse(result.stdout.trim()) as {
    readonly archiveBytes: number;
    readonly elapsedMs: number;
    readonly peakRssBytes: number;
    readonly first: { readonly status: string; readonly reason?: string };
    readonly second: { readonly status: string; readonly outcome?: string };
    readonly rejected: readonly string[];
    readonly finalized: readonly string[];
  };
  assert.equal(report.archiveBytes, PROJECT_SYNC_MAX_ARCHIVE_BYTES);
  assert.equal(report.first.status, "rejected", "the invalid first claim reaches the real worker rejection path");
  assert.equal(report.first.reason, "invalid_archive");
  assert.equal(report.second.status, "finalized", "the following valid claim is not starved by the invalid one");
  assert.equal(report.second.outcome, "canonical");
  assert.deepEqual(report.rejected, ["upload-invalid"]);
  assert.deepEqual(report.finalized, ["upload-valid"]);
  assert.ok(report.elapsedMs < 30_000, `worker elapsed ${report.elapsedMs}ms exceeds its 30-second timeout`);
  assert.ok(report.peakRssBytes < 1_073_741_824,
    `worker peak RSS ${report.peakRssBytes} exceeds its configured 1 GiB memory envelope`);
  assert.ok(report.peakRssBytes > report.archiveBytes,
    "the child-process peak RSS probe reaches the real large-archive execution");
});

async function runChild(command: string, args: readonly string[], timeoutMs: number): Promise<{
  readonly exitCode: number | null;
  readonly stdout: string;
  readonly stderr: string;
}> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, [...args], { cwd: process.cwd(), stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => { stdout += chunk; });
    child.stderr.on("data", (chunk: string) => { stderr += chunk; });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`project-sync worker ceiling oracle exceeded ${timeoutMs}ms`));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("close", (exitCode) => {
      clearTimeout(timer);
      resolve({ exitCode, stdout, stderr });
    });
  });
}
