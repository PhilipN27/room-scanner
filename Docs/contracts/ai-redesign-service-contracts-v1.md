# AI redesign professional-service contracts v1

- Status: Slice 4 local contract foundation; no production deployment claim
- Date: 2026-08-19
- Route-set version: `roomscan-slice4-routes-v3`
- Authoritative implementation: `HostedService/service/src/contracts`,
  `HostedService/service/src/authorization/policy.ts`
- Preserves: [`ai-redesign-contracts-v1.md`](ai-redesign-contracts-v1.md)

This document defines the provider-neutral, app-owned professional-service
boundary. It does not change the existing room-package, AI Room Package,
Concept Set, future sync, or portal-snapshot schemas. Provider request/response
types, ARNs, database rows, internal UUIDs, credentials, and provider tokens
are not public contracts.

## Trust and identifier rules

- Clients authenticate only to the app-owned API with app-owned opaque tokens.
- A request never establishes tenant scope by supplying a workspace ID. The
  server resolves the canonical principal and active membership and selects the
  tenant inside the operation transaction.
- Internal database UUIDs remain private. Public identifiers use stable,
  bounded, type-specific values and cannot be accepted as direct authority.
- Resource authorization checks the resolved tenant, current membership state,
  current role and authorization version, exact action, resource tenant, recent
  server authentication where required, and current operational flags.
- Face ID/passcode state, biometric material, and LocalAuthentication domain
  state have no field in this contract.

## Authentication policy

Verified-email magic-link requests return the same asynchronous response shape
and size for known, unknown, disabled, relay, throttled, or transiently
unavailable addresses. Before requesting a link, the app retains a random
32-byte completion verifier and sends only its RFC 7636 S256 challenge. The
server returns an equally shaped random 32-byte completion ID and expiry even
when it deliberately creates no redeemable transaction. Normalization trims
outer whitespace and lowercases only the domain. Links have 32-byte secrets,
10-minute expiry, a 60-second issuance cooldown, and at most two outstanding
links per address and purpose. Initial configurable test limits are three
deliveries per 15 minutes and ten per day per address HMAC, plus 20 requests per
15 minutes per network HMAC. Link, completion, receipt, access, and refresh
material is stored only as keyed hashes; the sealed email outbox is the narrow
exception required to deliver the one-time link.

`GET /auth/magic-link/:selector` renders a static, first-party, scanner-safe
confirmation with no token interpolation or third-party resource. It never
consumes or authenticates. A trusted form submit sends selector, fragment
secret, and exact purpose to `POST /auth/magic-link/consume`; that atomic step
confirms the mailbox proof but creates no session or identity receipt. Instead,
the browser displays a deterministic eight-character Crockford transfer code
and never receives an app token. The requesting app redeems with completion ID,
verifier, exact purpose, and transfer code. Only then may the server atomically
create or recover the corresponding app-owned session or purpose-bound verified
authentication receipt. Wrong, swapped, expired, replayed, or rate-limited
material fails closed; an exact lost-response retry recovers only a still-live
original result. Clicking-device context is derived from the bounded API
Gateway v2 request ID, while the redemption rate bucket is derived from the API
Gateway source IP. Neither binds the flow to one device or network, so a user
may confirm on a different device without making a blind mailbox click
sufficient for an attacker to claim the session. Responses and HTML are
`no-store`; the confirmation uses a restrictive CSP,
`Referrer-Policy: no-referrer`, and replaces fragment-bearing history before
interaction.

Apple attempts last five minutes and bind state, nonce, expected client ID,
redirect URI, and an S256 code challenge. The public begin/finish flow may sign
in only. Candidate Apple identity proof begins only from a current app session
with recent server authentication; it cannot create a full session or link an
identity by itself. Identity linking/unlinking requires recent authentication
of the current principal, a separate recent purpose-bound proof for the
candidate identity, literal deliberate confirmation, audit and notification,
and rejection if the candidate identity belongs to another principal. Email
equality never links identities.

Apple finish runs in the explicit
`apple-api-exchange-cognito-challenge-session` lane. The API generates raw
app-owned access/refresh tokens and keyed hashes, starts and awaits Cognito
custom auth, discards Cognito tokens, then resolves its own issued access hash.
Only the auth-challenge runtime may atomically consume the one-time Apple proof,
derive/create the app principal, and insert the app session. The API receives
no proof-consumer or principal-creation capability. Session refresh is a
separate `session-refresh-hash-rotation` lane. Raw app tokens or bridge proofs
must not be put in Cognito `ClientMetadata`.

Access tokens expire after five minutes. Refresh families have seven-day
inactivity and 30-day absolute limits, rotate on every use with no grace, detect
ancestor reuse, and support current-family logout, logout-all, revocation,
principal-epoch invalidation, and membership-change invalidation. Sensitive
operations and identity linking require server recent authentication no older
than five minutes. Local device unlock is intentionally insufficient.

## Sealed Slice 4 route manifest

Exactly these 19 routes exist in the Slice 4 manifest:

| Method and path | Visibility | Purpose |
| --- | --- | --- |
| `GET /health` | Public | Minimal service status; no tenant data. |
| `POST /auth/magic-link/request` | Public | Uniform verified-email completion request; source IP is trusted only from the API Gateway v2 context. |
| `POST /auth/magic-link/candidate/request` | App session + recent auth | Begin an independently verified, purpose-bound email candidate transaction. |
| `GET /auth/magic-link/:selector` | Public | Static scanner-safe confirmation; never consumes. |
| `POST /auth/magic-link/consume` | Public | Deliberately confirm mailbox control and return only the transfer code. |
| `POST /auth/magic-link/completion/redeem` | Public with completion proof | Redeem the app-held verifier plus transfer code into a session or candidate receipt. |
| `POST /auth/apple/begin` | Public | Begin sign-in attempt with app-owned S256 challenge. |
| `POST /auth/apple/candidate/begin` | App session + recent auth | Begin a purpose-bound candidate proof; not a sign-in/session endpoint. |
| `POST /auth/apple/finish` | Public | Finish the matching sign-in attempt after state/PKCE/code validation. |
| `POST /auth/session/refresh` | Public with refresh secret | Rotate an app-owned refresh token. |
| `POST /billing/stripe/webhook` | Public provider ingress | Exact raw-body signature verification and durable acceptance; never client authorization. |
| `POST /auth/session/logout` | App session | Revoke the current family. |
| `POST /workspace/bootstrap` | Unscoped app session + recent auth | Create the principal's first workspace and Owner membership, then atomically scope the calling family. |
| `POST /workspace/activate` | Unscoped app session + recent auth | Select an existing active membership by public slug; the server derives and scopes the tenant. |
| `GET /workspace` | Workspace, `workspace.read` | Read the resolved current workspace. |
| `GET /membership` | Workspace, `member.read` | Read the current membership through its resource resolver. |
| `GET /subscription` | Workspace, `subscription.read` | Read app-owned subscription/entitlement state. |
| `GET /quota` | Workspace, `quota.warning.read` | Read all five quota metrics and warnings. |
| `POST /identity/mutate` | App session + recent auth | Deliberately link or unlink a separately verified candidate identity and audit/notify the result. |

The manifest is deep-frozen and drives matching, visibility, validation,
authorization metadata, handlers, and OpenAPI 3.1 generation. Extra or missing
handlers fail composition. Protected routes never have optional bearer
middleware. OpenAPI renders the manifest's `:selector` path variable as
`{selector}` without changing the runtime route. There is no caller workspace
path and no Slice 5 sync/upload,
Slice 6 portal/publication, or Slice 7 lifecycle endpoint. Membership mutation
HTTP routes remain unapproved even though the service/DB domain supports their
later composition.

## Central role/action matrix

`R` means the role is allowed only with recent server authentication. `C` means
an Editor additionally requires the explicit current
`editor_publishing_allowed` policy. A blank cell denies. The implementation has
54 literal actions and no default allow.

| Exact actions | Owner | Admin | Editor | Viewer |
| --- | :---: | :---: | :---: | :---: |
| `workspace.read`, `member.read`, `project.read`, `private.download`, `quota.warning.read` | yes | yes | yes | yes |
| `workspace.profile.update`, `security.read`, `access_history.read`, `audit.read` | yes | yes |  |  |
| `audit.export`, `workspace.security.change`, `ownership.transfer`, `workspace.permanent_delete` | R |  |  |  |
| `member.invite.viewer`, `member.revoke.viewer`, `member.change.viewer`, `member.remove.viewer` | R | R |  |  |
| `member.invite.editor`, `member.revoke.editor`, `member.change.editor`, `member.remove.editor` | R | R |  |  |
| `member.invite.admin`, `member.change.admin`, `member.remove.admin` | R |  |  |  |
| `member.add.owner`, `member.change.owner`, `member.remove.owner` | R |  |  |  |
| `subscription.read`, `usage.read`, `limit.read` | yes | yes |  |  |
| `subscription.manage`, `billing.manage` | R |  |  |  |
| `project.create`, `project.revise`, `concept.import`, `concept.edit`, `concept.archive`, `comment.create`, `concept.approve` | yes | yes | yes |  |
| `project.archive`, `project.restore` | yes | yes |  |  |
| `project.permanent_delete`, `raw_archive.configure` | R |  |  |  |
| `raw_archive.allocate` | yes | yes | yes |  |
| `publication.record.read` (reserved) | yes | yes | yes | yes |
| `publication.policy.change` (reserved) | R | R |  |  |
| `publication.create`, `publication.update`, `publication.revoke` (reserved) | R | R | R+C |  |
| `system.quota_policy.change`, `system.stripe.reconcile`, `system.audit.write`, `system.break_glass`, `system.kill_switch.mutate` |  |  |  |  |

Identity/session self-service and invitation acceptance are principal-scoped,
not workspace role actions. System-only actions require separated operator or
service capabilities and reject every workspace role. Reserved publication
actions are policy constants only; Slice 4 exposes no publication endpoint.

## Transaction and persistence contract

One operation transaction binds access-token resolution, centralized
authorization, resource lookup, flag/publishing-policy checks, and the mutation
or read. A transaction-scoped repository bundle is the only handler-facing data
surface; handlers do not receive raw SQL execution. Provider work, including
Apple/SES/Stripe current-state fetches and S3 signing, occurs outside the
database transaction.

Every tenant table has forced RLS. The application role owns no tenant table and
has no `BYPASSRLS`. Server code clears and sets principal, tenant, and
authorization-version GUCs transaction-locally. Missing, malformed, stale, or
unscoped context fails closed, and pooled connections may not retain another
request's context.

Invitations are hash-addressed, expiring, versioned, and atomically single-use.
Membership composites protect the last Owner, reserve/release member slots,
advance authorization versions, invalidate affected sessions, and create
bounded audit/outbox records in one transaction.

## Subscription and quota contract

Subscription/provider state is input to an app-owned entitlement reducer; it
never directly authorizes an operation. Quotas are versioned across exactly
five metrics: `project_count`, `member_count`, `working_bytes`, `raw_bytes`, and
`portal_bytes`. A quota response includes usage, reservation, limit, warning,
policy version, and the applicable lifetime or portal-period identity.

The approved test-only policy is three projects, two members, 10 MiB working
bytes, 20 MiB raw bytes, 30 MiB portal traffic per test period, and an 80%
warning threshold. These are not production entitlements or prices. Production
values require measurement and owner approval.

Reservation/finalize/release/reconcile operations are idempotent, atomic, and
period-aware. New allocations fail at the boundary or while over limit, but
existing records stay readable/exportable with a warning. A quota or
entitlement change never deletes, compresses, mutates, or silently degrades
existing data.

## Operational flags and rollback

`professional_sign_in_enabled`, `hosted_operations_enabled`, and
`publication_enabled` are versioned and fail closed when missing or unreadable.
Sign-in gates new hosted authentication. Hosted operations gate mutations and
allocations while retaining allowed reads/exports. Publication gates every
reserved publication action and future protected asset authorization. Valid
Stripe ingestion may be durably accepted during a hosted freeze, but
entitlement application may pause visibly.

Rollback disables sign-in and hosted/publication operations without altering
local packages, AI export, Concept Sets, legacy export, or Share Sheet behavior.

## Error, logging, and provider boundaries

The HTTP boundary enforces API Gateway v2 shape, exact method/path, bounded
headers/query/body, fatal UTF-8, duplicate decoded JSON-key rejection,
allowlisted schemas, uniform app-owned errors, bounded responses, and
`Cache-Control: no-store`. It never logs raw headers, query strings, bodies, or
provider responses.

Structured logs and audit envelopes accept only bounded event codes,
correlation/request IDs, pseudonymous principal/workspace IDs, actions,
results, durations, and counters. They reject or drop email addresses, access
or refresh tokens, magic-link tokens, Apple/Cognito tokens, Stripe signatures
or bodies, presigned URLs, room bytes, filenames, GPS, biometrics, arbitrary
request bodies, and free text.

Provider adapters are private implementation details:

- Apple exchange is HTTPS-only, bounded, non-redirecting, and never logs token
  bodies;
- Cognito custom challenge events preserve exact Define/Create/Verify semantics
  and synthetic-user nondisclosure; `answerCorrect` is server-derived;
- SES binds sender address, identity ARN, and configuration set on every send;
- S3 allocation returns only a narrow, HTTPS single-PUT capability for an
  authorization-derived tenant prefix;
- Stripe accepts the exact supported `application/json` media type, verifies
  exact raw bytes before parsing, and persists only bounded, privacy-safe event
  metadata and a digest. Reconciliation is selected only from a server-owned
  `(platform|connected, account, customer, subscription)` binding. It performs
  an exact subscription retrieve, sends `Stripe-Account` only for a connected
  account, and rejects an ID/customer mismatch. The allowlist is exactly
  `customer.subscription.created`, `.deleted`, `.paused`, `.resumed`,
  `.trial_will_end`, and `.updated`; an unrelated but correctly signed event is
  acknowledged without mutating entitlement state.

## Compatibility and open gates

Contract additions require a new route-set/schema version, tests for exact
manifest/OpenAPI parity, and a privacy/security review. Vendor identifiers or
later-slice behavior cannot be added under this v1 name.

Real API Gateway byte preservation, browser scanner/referrer/history behavior,
Cognito custom challenges, Apple exchange/JWKS rotation, SES delivery/bounces,
Stripe delivery/retries, S3/KMS/IAM semantics, Data API behavior, and provider
control planes require separately authorized non-production proof. Immediate
portal revocation and full deletion/restore remain Slice 6 and Slice 7 gates.
