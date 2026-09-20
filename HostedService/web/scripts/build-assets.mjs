import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const outputRoot = resolve(webRoot, "dist");
const scriptPath = resolve(outputRoot, "portal.js");
const stylesheetPath = resolve(outputRoot, "portal.css");
const portalStylesheetPath = resolve(webRoot, "src/portal/portal.css");
const professionalStylesheetPath = resolve(webRoot, "src/professional/professional.css");

const MAX_STYLESHEET_BYTES = 262_144;
const MAX_SCRIPT_BYTES = 524_288;

const [script, portalStylesheet, professionalStylesheet] = await Promise.all([
  readFile(scriptPath),
  readFile(portalStylesheetPath),
  readFile(professionalStylesheetPath),
]);

const stylesheet = Buffer.from(`${portalStylesheet.toString("utf8").trim()}\n\n${professionalStylesheet.toString("utf8").trim()}\n`, "utf8");
validateUTF8(script, "script");
validateUTF8(stylesheet, "stylesheet");
validateScript(script.toString("utf8"));
validateStylesheet(stylesheet.toString("utf8"));
if (script.byteLength > MAX_SCRIPT_BYTES || stylesheet.byteLength > MAX_STYLESHEET_BYTES) fail("asset_size");

await writeFile(stylesheetPath, stylesheet);
const manifest = {
  schemaVersion: "roomscan-published-web-assets-v1",
  assets: [
    { path: "portal.css", byteCount: stylesheet.byteLength, sha256: sha256(stylesheet), mediaType: "text/css; charset=utf-8" },
    { path: "portal.js", byteCount: script.byteLength, sha256: sha256(script), mediaType: "text/javascript; charset=utf-8" },
  ],
};
await writeFile(resolve(outputRoot, "asset-manifest.json"), `${JSON.stringify(manifest)}\n`, { encoding: "utf8" });

function validateUTF8(bytes, kind) {
  if (!Buffer.isBuffer(bytes) || bytes.byteLength < 1 || bytes.includes(0)) fail(`invalid_${kind}`);
  const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  if (!Buffer.from(text, "utf8").equals(bytes)) fail(`invalid_${kind}`);
}

function validateStylesheet(value) {
  if (/(?:<\/style|@import\b|url\s*\(|sourceMappingURL|expression\s*\()/iu.test(value)) fail("unsafe_stylesheet");
}

function validateScript(value) {
  if (/(?:<\/script|sourceMappingURL|\bimport\s*(?:\(|[\s{*])|\b(?:document\.write|innerHTML|outerHTML|insertAdjacentHTML)\b|https?:\/\/)/iu.test(value)
    || /\b(?:eval|Function)\b/u.test(value)) fail("unsafe_script");
  if (/(?:RoomScanWebTestExports|serviceWorker|new\s+Worker\s*\(|WebSocket\s*\()/u.test(value)) fail("unsafe_script");
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function fail(code) {
  throw new Error(`invalid_published_web_asset:${code}`);
}
