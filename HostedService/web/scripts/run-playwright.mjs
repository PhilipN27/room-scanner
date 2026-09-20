import { spawn } from "node:child_process";

const port = process.env.ROOMSCAN_WEB_FIXTURE_PORT ?? "4173";
const baseURL = `http://127.0.0.1:${port}`;
const fixture = spawn(process.execPath, ["scripts/serve-fixture.mjs"], {
  cwd: process.cwd(),
  env: { ...process.env, ROOMSCAN_WEB_FIXTURE_PORT: port },
  stdio: ["ignore", "pipe", "inherit"],
});

try {
  await ready(fixture, `roomscan-web-fixture-ready:${port}`);
  const result = await child("playwright", ["test", "--config", "playwright.config.mjs"], {
    ...process.env,
    ROOMSCAN_WEB_BASE_URL: baseURL,
  });
  process.exitCode = result;
} finally {
  if (fixture.exitCode === null) {
    fixture.kill("SIGTERM");
    await Promise.race([onceExit(fixture), new Promise((resolve) => setTimeout(resolve, 5_000))]);
  }
  if (fixture.exitCode === null) throw new Error("fixture_server_did_not_exit");
}

function child(command, args, env) {
  return new Promise((resolve, reject) => {
    const childProcess = spawn(command, args, { cwd: process.cwd(), env, stdio: "inherit" });
    childProcess.once("error", reject);
    childProcess.once("exit", (code, signal) => signal === null && code !== null ? resolve(code) : reject(new Error(`playwright_terminated:${signal ?? "unknown"}`)));
  });
}

function ready(process, marker) {
  return new Promise((resolve, reject) => {
    let output = "";
    const timer = setTimeout(() => reject(new Error("fixture_server_timeout")), 15_000);
    const fail = (error) => { clearTimeout(timer); reject(error); };
    process.once("error", fail);
    process.once("exit", (code) => fail(new Error(`fixture_server_exit:${code ?? "unknown"}`)));
    process.stdout.on("data", (chunk) => {
      output += chunk.toString("utf8");
      if (output.includes(marker)) { clearTimeout(timer); resolve(); }
    });
  });
}

function onceExit(process) {
  return new Promise((resolve) => process.once("exit", resolve));
}
