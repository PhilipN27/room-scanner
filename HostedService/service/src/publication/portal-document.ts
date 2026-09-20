import { createHash } from "node:crypto";

/** Build-time portal bytes are injected through composition. The service never
 * reads a web directory, accepts an asset path, or fetches a bundle at run
 * time. Keeping this document request-independent prevents bearer fragments
 * and other request values from becoming HTML interpolation inputs. */
export interface Slice6PortalDocumentAssets {
  readonly stylesheet: Uint8Array;
  readonly script: Uint8Array;
}

export interface Slice6PortalDocument {
  readonly html: string;
  readonly headers: Readonly<Record<string, string>>;
}

const MAX_STYLESHEET_BYTES = 262_144;
const MAX_SCRIPT_BYTES = 524_288;
const MAX_DOCUMENT_BYTES = 1_048_576;

export function createSlice6PortalDocument(input: Slice6PortalDocumentAssets): Slice6PortalDocument {
  if (input === null || typeof input !== "object") throw new Error("invalid_slice6_portal_document");
  const stylesheet = safeUTF8Asset(input.stylesheet, MAX_STYLESHEET_BYTES, "stylesheet");
  const script = safeUTF8Asset(input.script, MAX_SCRIPT_BYTES, "script");
  validateStylesheet(stylesheet);
  validateScript(script);
  const styleHash = sha256(input.stylesheet);
  const scriptHash = sha256(input.script);
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>RoomScanStudio presentation</title><style>${stylesheet}</style></head><body><main id="roomscan-portal" aria-live="polite"><p>Loading RoomScanStudio presentation…</p></main><script>${script}</script></body></html>`;
  if (Buffer.byteLength(html, "utf8") > MAX_DOCUMENT_BYTES) throw new Error("invalid_slice6_portal_document");
  return Object.freeze({
    html,
    headers: Object.freeze({
      "cache-control": "no-store",
      "content-type": "text/html; charset=utf-8",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      "content-security-policy": `default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'; connect-src 'self'; img-src 'self' data: blob:; style-src 'sha256-${styleHash}'; script-src 'sha256-${scriptHash}'; require-trusted-types-for 'script'; trusted-types roomscan-portal`,
    }),
  });
}

function safeUTF8Asset(value: unknown, maximumBytes: number, kind: "stylesheet" | "script"): string {
  if (!(value instanceof Uint8Array) || value.byteLength < 1 || value.byteLength > maximumBytes) throw new Error("invalid_slice6_portal_document");
  let text: string;
  try { text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(value); } catch { throw new Error("invalid_slice6_portal_document"); }
  // A strict round-trip keeps CSP hashes tied to exactly the bytes embedded in
  // the document, rather than to a decoder-normalized representation.
  if (!Buffer.from(text, "utf8").equals(Buffer.from(value))) throw new Error("invalid_slice6_portal_document");
  if (kind === "script" && text.length > MAX_SCRIPT_BYTES) throw new Error("invalid_slice6_portal_document");
  return text;
}

function validateStylesheet(value: string): void {
  if (/(?:<\/style|@import\b|url\s*\(|sourceMappingURL|expression\s*\()/iu.test(value)) throw new Error("invalid_slice6_portal_document");
}

function validateScript(value: string): void {
  if (/(?:<\/script|sourceMappingURL|\bimport\s*(?:\(|[\s{*])|\b(?:document\.write|innerHTML|outerHTML|insertAdjacentHTML)\b|https?:\/\/)/iu.test(value)
    || /\b(?:eval|Function)\b/u.test(value)) {
    throw new Error("invalid_slice6_portal_document");
  }
}

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("base64");
}
