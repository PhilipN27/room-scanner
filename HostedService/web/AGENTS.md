# Publication portal and professional browser

Applies to this tree; inherit parent guides. This is a lightweight TypeScript/
DOM frontend, not React/Vite and not a capture or full spatial editor.

## Exact commands

From the repository root:

```sh
npm --prefix HostedService/web ci
npm --prefix HostedService/web run typecheck
npm --prefix HostedService/web run test:focused
npm --prefix HostedService/web test
npm --prefix HostedService/web run build
npm --prefix HostedService/web run test:integration
npm --prefix HostedService/web run test:e2e
```

`test:focused` is the existing portal-security unit target. For Chromium
installation and ordered setup, use
`../../.factory/skills/roomscan-hosted-verification/SKILL.md`.
No `dev`/`start` or lint script exists. `test:e2e` owns its synthetic loopback
fixture server and shuts it down; do not use it as a real hosted backend.

## Browser rules

- Production code lives in `src/shared/`, `src/portal/`, `src/professional/`,
  composed through `src/main.ts`. Match the existing `RoomScanWeb` namespace;
  the explicit `tsconfig.build.json` file order matters.
- Use `shared/dom.ts` safe tags/attributes/text nodes and validated DTOs/URLs.
  Stored markup stays inert. No `innerHTML`, `eval`, external imports/scripts,
  CDN, service worker, WebSocket or public reusable object URL.
- Tokens/grants stay memory-only; scrub the fragment before asynchronous work.
  No token persistence in local/session storage, browser history, logs or fixtures.
  Revoke protected blob URLs through the registry on invalidation/cleanup.
- Maintain CSP-hashed, no-store, request-independent `/p` document delivery,
  bounded asset sizes, trusted user submissions and immediate grant revocation.
- Property rooms remain independent. Professional navigation exposes only the
  eight bounded management/read flows; do not add browser capture/spatial editing.
- Preserve keyboard/focus/labels, responsive desktop/mobile layouts, long-text
  wrapping, reduced-motion behavior and honest static rendering fallbacks.

## Tests and generated assets

- Unit tests: `test/*.test.mjs` against freshly compiled `.test-dist/`;
  interaction tests: `e2e/*.desktop.spec.mjs` / `*.mobile.spec.mjs`.
- Playwright uses one Chromium worker, no retries, desktop/mobile projects and
  `test-results/results.json`. Do not hide failures with retries/skips.
- `npm run build` compiles `dist/portal.js`; `scripts/build-assets.mjs` joins
  source CSS and emits `portal.css` / `asset-manifest.json` with exact digests.
  Edit TS/CSS, not `dist/`. Rebuild before service/infrastructure asset inspection.
- Preserve deliberate screenshot baselines under `screenshots/`; treat their
  replacement as reviewed evidence. Chromium mobile emulation is not Safari proof.
