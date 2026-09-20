import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import { createSlice6PortalDocument } from "../src/publication/portal-document.js";

const stylesheet = Uint8Array.from(Buffer.from(":root{color-scheme:light}#roomscan-portal{min-height:100vh}", "utf8"));
const script = Uint8Array.from(Buffer.from("\"use strict\";(()=>{const fragment=location.hash;history.replaceState(null,\"\",\"/p\");void fragment;})();", "utf8"));

test("portal document accepts only bounded inert UTF-8 build assets and emits their exact CSP hashes", () => {
  const first = createSlice6PortalDocument({ stylesheet, script });
  const second = createSlice6PortalDocument({ stylesheet, script });
  const styleHash = createHash("sha256").update(stylesheet).digest("base64");
  const scriptHash = createHash("sha256").update(script).digest("base64");
  assert.equal(first.html, second.html, "document construction has no request or runtime-file input");
  assert.equal(first.headers["cache-control"], "no-store");
  assert.equal(first.headers["referrer-policy"], "no-referrer");
  assert.equal(first.headers["x-content-type-options"], "nosniff");
  const csp = first.headers["content-security-policy"];
  assert.equal(csp, `default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'; connect-src 'self'; img-src 'self' data: blob:; style-src 'sha256-${styleHash}'; script-src 'sha256-${scriptHash}'; require-trusted-types-for 'script'; trusted-types roomscan-portal`);
  assert.equal(/(?:^|;)\s*(?:script-src|style-src|connect-src)[^;]*\bblob:/u.test(csp ?? ""), false, "temporary binary URLs are available only to rendered image elements, never code/style/network fetches");
  assert.equal(first.html.includes("CustomEvent"), false, "the service document has no hardcoded fragment-event shell");
  assert.equal(/(?:sourceMappingURL|@import|https?:\/\/|<script[^>]+src=|\son[a-z]+\s*=)/iu.test(first.html), false);

  const unsafe = [
    { stylesheet: Uint8Array.of(0xff), script },
    { stylesheet: Uint8Array.from(Buffer.from("@import url('https://evil.example/style.css')", "utf8")), script },
    { stylesheet, script: Uint8Array.from(Buffer.from("import('https://evil.example/app.js')", "utf8")) },
    { stylesheet, script: Uint8Array.from(Buffer.from("//# sourceMappingURL=app.js.map", "utf8")) },
    { stylesheet, script: Uint8Array.from(Buffer.from("document.write('<img onerror=alert(1)>')", "utf8")) },
    { stylesheet, script: new Uint8Array(524_289).fill(0x20) },
  ];
  for (const candidate of unsafe) {
    assert.throws(
      () => createSlice6PortalDocument(candidate),
      /invalid_slice6_portal_document/u,
      "fatal UTF-8, bounded-size, source-map, import, and unsafe-DOM controls each fail before a route can be built",
    );
  }
});

test("portal document permits ordinary compiled function declarations while rejecting dynamic-code constructors", () => {
  const compiledApplication = Uint8Array.from(Buffer.from("\"use strict\";function boot(){return 1;}boot();", "utf8"));
  assert.doesNotThrow(
    () => createSlice6PortalDocument({ stylesheet, script: compiledApplication }),
    "ordinary compiler output must cross the static-asset seam",
  );
  for (const dynamicCode of ["eval('1')", "Function('return 1')()"] as const) {
    assert.throws(
      () => createSlice6PortalDocument({ stylesheet, script: Uint8Array.from(Buffer.from(dynamicCode, "utf8")) }),
      /invalid_slice6_portal_document/u,
      `dynamic code remains rejected: ${dynamicCode}`,
    );
  }
});
