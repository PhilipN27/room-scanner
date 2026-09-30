# Hosted professional service

Applies to this tree; inherit the root guide. This is four separate npm packages,
not one npm workspace. Use Node 24.15.0 and committed lockfiles. There is no
`start`, `dev`, or lint script and no configured production endpoint.

## Service commands

From the repository root:

```sh
npm --prefix HostedService ci
npm --prefix HostedService run typecheck
npm --prefix HostedService test
npm --prefix HostedService run build
```

The scripts in `package.json` compile strict TypeScript before Node's test runner;
tests are `service/test/*.test.ts`, emitted to `.test-dist/service/test/`.
Do not run stale emitted JavaScript as evidence of current-source behavior.
The hosted umbrella and browser setup are in
`../.factory/skills/roomscan-hosted-verification/SKILL.md`.

## Service map and conventions

- `service/*.ts`: identity/session/magic-link/privacy primitives.
- `service/src/contracts/`: app-owned public contracts, sealed route manifests
  and provider ports; `authorization/`: centralized permissions and gates.
- `composition/`, `handlers/`, `http/`: request/production composition;
  `adapters/`, `persistence/`: provider ports and transaction-bound repositories.
- `sync/`, `publication/`: bounded validators and capability-specific workers.
- `db/`, `infra/`, `web/`: follow their narrower guides.
- Match strict compiler settings: NodeNext ESM with `.js` import specifiers,
  explicit readonly interfaces, unchecked-index/optional-property guards and
  unknown-error handling. Dependencies use reviewed exact pins.

## Security and compatibility

- Preserve sealed Slice 4/5 exports and the additive 55-route Slice 6 manifest.
  Cross-runtime changes must match `../Docs/contracts/` and Swift consumers.
- Authorize from app-owned sessions/current membership in the same transaction
  as protected repository work. Clear stale pooled context before pre-resolution.
  Do not let handlers select runtime roles or internal SQL/object targets.
- Cognito/provider tokens are not app sessions. Preserve verifier-bound,
  one-time magic completion, replay denial, signature-before-parse Stripe ingress
  and reconciliation from current authoritative subscription state.
- Allocation, completion, validation, immutable promotion and expected-head CAS
  are distinct durable transitions. Queues wake targetless server selection;
  advisory edit leases do not authorize writes.
- Publication accepts a typed public allowlist, never a private package dump.
  Recheck live grant/flag/version authorization at every protected read and after
  object reads; feedback has no private-project mutation capability.
- Keep privacy-safe allowlisted logs and exact synthetic secret/body canaries.
  Do not log payloads, email, tokens, GPS, object keys or signed URLs.

## Generated output

`dist/` and `.test-dist/` are replaced by their build/test scripts. Edit TypeScript
sources, not emitted JavaScript/declarations. Publication base64 archives and
`expectations.json` are production-builder golden inputs shared with Core, not
build outputs.
