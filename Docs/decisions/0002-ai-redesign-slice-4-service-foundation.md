# ADR 0002: Slice 4 professional-service foundation

- Status: Accepted for local implementation; not authorization to provision or deploy
- Date: 2026-08-19
- Decision owners: RoomScanStudio engineering and product
- Supersedes: legacy blanket statements that RoomScanStudio has no server or account boundary
- Preserves: ADR 0001's AWS selection and the authoritative local/package contracts

## Context

ADR 0001 selected an app-owned AWS boundary for the optional professional
service. Slice 4 must make that boundary implementable without turning account
sign-in, remote configuration, or hosted availability into a prerequisite for
guest launch or any existing local workflow. The repository previously had no
hosted runtime or infrastructure project, so runtime, deployment description,
database access, identity composition, environment separation, local test
strategy, and operational defaults required an explicit decision.

## Decision

### Runtime and repository layout

The hosted service uses strict TypeScript targeting Node.js 24. The infrastructure
definition uses AWS CDK v2 in TypeScript. The repository layout is:

- `HostedService/service`: app-owned domain, provider-neutral contracts,
  handlers, and provider adapters;
- `HostedService/db`: forward-only PostgreSQL migrations and disposable
  PostgreSQL integration tests;
- `HostedService/infra`: CDK stacks, policy assertions, offline synthesis, and
  artifact inspection.

The iOS app imports no AWS, Cognito, Stripe, SES, S3, RDS, or database type.
`RoomScanCore` remains Foundation-only and provider-neutral. The hosted service
coordinates professional identity, membership, entitlement, quota, and future
resource lineage; it is never the source of captured room truth.

### Control plane and persistence

The private control plane is API Gateway HTTP API payload v2 to Node.js 24
Lambda functions in `us-east-1`. Canonical principals, workspaces, memberships,
sessions, subscription/quota state, audit state, and future coordination state
use Aurora PostgreSQL Serverless v2 with PostgreSQL 16 semantics. Infrastructure
targets the Aurora PostgreSQL 16.8 LTS family; the local database oracle uses a
disposable PostgreSQL 16 cluster (16.13 at the Slice 4 checkpoint).

Lambda request paths use the RDS Data API. Each operation begins one explicit
transaction, clears request context, resolves the opaque access-token digest to
the authoritative principal/membership context, sets transaction-local
`app.principal_id`, `app.tenant_id`, and `app.authorization_version`, performs
authorization and mutation in that same unit of work, and then commits or rolls
back. Statements are serialized and transaction identifiers are never reused.
No provider or other network call is made inside the database transaction.
Long-lived client-side database pools and caller-supplied workspace scope are
not part of this architecture.

Tenant tables enable and force PostgreSQL row-level security. Tenant-table
owners are `NOLOGIN`; runtime roles are `NOSUPERUSER`, `NOINHERIT`, and
`NOBYPASSRLS`, own no tenant table, and receive only lane-specific capabilities.
The shared `roomscan_app` role is `NOLOGIN`. A custom `app.*` setting is context,
not authority; LOGIN roles cannot convert a caller-chosen UUID into authority.

### Object and provider boundaries

S3 buckets are private, versioned, TLS-only, KMS-encrypted boundaries with
server-owned tenant prefixes. An authorized operation may allocate only a
random, immutable `server/quarantine/v1/...` key and a narrowly constrained
single PUT. Object storage does not decide authorization and clients receive no
AWS, database, or service-role credential.

Cognito is an upstream Apple-federation and custom-auth challenge substrate.
It does not own the app principal and its tokens are never the client session.
RoomScanStudio issues app-owned opaque access and refresh tokens only after its
own identity and session rules pass.

Sign in with Apple uses the app-owned server directly for the authorization-code
exchange and JWT validation. The server validates issuer, audience, RS256
signature and trusted JWKS, key rotation, timestamps, nonce, state, single-use
attempt/code state, and an app-owned RFC 7636 S256 challenge. The Apple token
exchange sends only Apple's documented fields: `client_id`, `client_secret`,
`code`, `grant_type`, and the conditional `redirect_uri`; the app validates the
`code_verifier` before exchange and does not send it as an unsupported Apple
field. Only the validated Apple issuer/subject and an app-owned one-time proof
cross the Cognito bridge. Cognito cannot choose a canonical principal.

The server-side call chain is asymmetric by design. The API generates the raw
app-owned access/refresh tokens, their keyed hashes, family public ID and
bounded session times, then starts and awaits Cognito Admin custom auth. Only
the Cognito auth-challenge runtime may atomically consume the one-time Apple
bridge and create the app principal/session records. After Cognito success, the
API discards provider tokens, resolves its own new access hash, and returns
only app-owned public identity plus the raw app tokens it generated. The API
must not call the proof-consumer function directly. Raw app tokens or bridge
proofs must not be placed in Cognito `ClientMetadata`, which AWS does not
validate, encrypt, or store; concrete transport/repository composition must
preserve an internal server-side binding.

SES v2 delivery is bound to an exact sender, sender-identity ARN, and
configuration set. Stripe webhooks retain the exact raw API Gateway bytes,
verify signatures before parsing, durably accept by account/event identity,
and only mark reconciliation dirty. Neither Stripe events nor client state
directly authorize work.

### Authentication and local unlock policy

The approved policy values are:

- magic links: 10-minute lifetime, 60-second issuance cooldown, at most two
  outstanding links per normalized address and purpose, high-entropy secrets
  stored only as keyed hashes, scanner-safe GET followed by deliberate POST;
- Apple authorization attempts: five minutes with state, nonce, and S256 PKCE;
- app access tokens: five minutes;
- refresh families: seven-day inactivity and 30-day absolute lifetime, rotation
  on every use with zero grace and family revocation on reuse;
- recent independent server authentication for sensitive operations and
  identity linking: five minutes;
- local Face ID or device-passcode proof for non-destructive unlock: at most
  five minutes; sensitive actions always request a fresh evaluation; entering
  the background clears plaintext professional session state and the local
  proof with no grace period.

Face ID/passcode and LocalAuthentication domain state are device-local signals.
They are never server identity, are never uploaded, and never satisfy server
recent-authentication requirements.

### Environment and account separation

The infrastructure consumes, but does not create, an explicit six-account
topology: management, log archive, security/audit, development workload,
staging workload, and production workload. Development, staging, and production
have distinct data, keys, secrets, identity resources, billing endpoints, and
deployment roles. All application data-plane resources target `us-east-1`.
Email, Apple, Stripe, DNS, CDN, and AWS management/control planes may process
metadata globally; the product must not claim that all processing occurs in the
United States.

No real account identifier, credential, domain, provider object, or production
configuration is committed. Local testing uses deterministic provider fakes,
offline CDK synthesis with `.invalid` references, and disposable Unix-socket-
only PostgreSQL 16 clusters with real restricted roles and connection reuse.
Authorized non-production provider tests are separate release gates.

### Operations and retention

The three server-side flags are `professional_sign_in_enabled`,
`hosted_operations_enabled`, and `publication_enabled`. Missing, stale, or
unavailable state is false. Guest launch does not fetch them. Publication
remains reserved for Slice 6 and is disabled by default.

Operational logs have a 30-day retention target. Protected audit evidence is
bounded to 400 days across current and noncurrent object versions; this is not
an Object Lock or WORM claim. Customer-managed KMS keys use managed rotation
where supported. Database, application-HMAC, Apple, SES, Stripe, and other
provider-secret rotation requires an operator workflow and a successful
non-production drill before production. No standing tenant-data access is
permitted. Break-glass access requires two-person approval, attribution and a
ticket, alerts on use, and a maximum 60-minute session.

Production prices and quota values remain undecided. The implementation has a
versioned five-metric quota mechanism and a deliberately small test policy only.

## Consequences

- Guest capture, save, view/edit, legacy export, AI Room Package construction,
  disclosure, Concept Set import/comparison/archive/delete, and Share Sheet
  preparation remain account-free and usable without hosted initialization.
- Disabling professional sign-in and hosted operations is a valid rollback;
  local packages and local export/import behavior remain intact.
- Provider SDK and database representations remain behind service ports and do
  not revise the v1 package/resource contracts.
- Data API transaction overhead is accepted in exchange for an explicit,
  stateless Lambda boundary and transaction-scoped tenant context.
- Immediate portal-link revocation is a Slice 6 gate. Full production
  deletion/restore and backup-lifecycle proof is a Slice 7 gate.
- This ADR authorizes local code, migrations, fakes, tests, and infrastructure
  definitions only. Provisioning, credential creation/rotation, deployment,
  DNS/provider configuration, real customer data, and production release each
  require separate authorization.

## Verification state

Local lane evidence exists, but the final `0007`/repository/infrastructure
composition and top-level matrices were still in progress when this ADR was
written. The authoritative current status is recorded in
[`../evidence/2026-08-19-ai-redesign-slice-4-verification.md`](../evidence/2026-08-19-ai-redesign-slice-4-verification.md).
