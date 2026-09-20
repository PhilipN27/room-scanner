import assert from "node:assert/strict";
import test from "node:test";

async function web() {
  await import(new URL("../.test-dist/roomscan-web.js", import.meta.url));
  return globalThis.RoomScanWeb;
}

class FakeText {
  constructor(data) { this.nodeType = 3; this.data = data; }
}

class FakeElement {
  constructor(tagName) { this.nodeType = 1; this.tagName = tagName; this.attributes = new Map(); this.children = []; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = [...items]; }
  setAttribute(name, value) { this.attributes.set(name, value); }
  set innerHTML(_value) { throw new Error("unsafe HTML sink invoked"); }
  set outerHTML(_value) { throw new Error("unsafe HTML sink invoked"); }
}

const fakeDocument = {
  createElement: (tag) => new FakeElement(tag),
  createTextNode: (text) => new FakeText(text),
};

test("safe DOM renders stored markup canaries as literal text and rejects unsafe URLs", async () => {
  const api = await web();
  const canary = '<img src=x onerror="fetch(\'/leak\')">';
  const element = api.safeElement(fakeDocument, "p", { text: canary, attributes: { "aria-live": "polite", class: "folio-note" } });
  assert.equal(element.children.length, 1);
  assert.equal(element.children[0].nodeType, 3);
  assert.equal(element.children[0].data, canary);
  assert.equal(element.attributes.get("aria-live"), "polite");
  assert.throws(() => api.safeHref("javascript:alert(1)"), /invalid_dom/u);
  assert.equal(api.safeHref("/p?workspace=1"), "/p?workspace=1");
  assert.equal(api.safeHref("#presentation-content"), "#presentation-content");
  assert.throws(() => api.safeHref("//evil.example/path"), /invalid_dom/u);
  assert.equal(api.safeHref("https://example.invalid/contact"), "https://example.invalid/contact");
});
