# ADR 0001: Hosted service boundary for AI redesign

- Status: accepted for Slice 0; production implementation is gated by the
  spikes and operator approvals below
- Date: 2026-08-12
- Decision owners: RoomScanStudio engineering and product
- Scope: professional shared-lineage coordination, private assets,
  publication, web access, identity, billing, audit, and deletion
- Out of scope: local capture truth, local editing, guest export/import,
  first-party AI inference, production provisioning, credentials, subscription
  prices, and customer quotas

## Decision

Use an app-owned hosted API in AWS `us-east-1` for the first professional
service implementation:

- Amazon API Gateway HTTP API and Lambda form the only private authorization
  and control-plane mutation boundary. A client may use a narrowly presigned
  request only to create one server-allocated immutable quarantine object; it
  cannot choose tenant scope, overwrite/read, promote, publish, or mutate
  canonical state.
- Aurora PostgreSQL Serverless v2 stores canonical principals, tenants,
  memberships, projects, immutable revision lineage, expected heads,
  publication records, link state, feedback, audit events, and lifecycle
  state.
- Private, versioned Amazon S3 buckets store staged uploads, validated active
  assets, bounded published derivatives, and backups. AWS Backup provides a
  separately inventoried recovery copy whose recovery points expire no later
  than 30 days.
- Amazon Cognito brokers Sign in with Apple and provides the custom-auth
  challenge substrate for email. The literal secure magic-link protocol is
  app-owned and unproven until the mandatory spike below passes. RoomScanStudio
  owns canonical-principal and explicit identity-link records; matching email
  alone never links principals.
- AWS Amplify Hosting deploys the professional and portal web applications.
  Only link-independent application-shell bytes may use public static/shared
  caching. Every bearer-protected HTML document, manifest, asset, derivative,
  and download must cross a revocation-aware authorization decision and must
  not be served from a shared or browser cache that can bypass a later denial.
  Global shell delivery is disclosed.
- CloudTrail including S3 data events, privacy-minimized application audit
  records, PostgreSQL audit logging, CloudWatch alarms, and a protected audit
  sink provide attributable operations evidence.
- Stripe Checkout/Billing/customer portal and signature-verified, idempotent
  webhooks provide subscription state. Stripe never becomes the authorization
  source of truth; the hosted API derives entitlements from accepted events.

This is a vendor architecture decision, not authorization to create accounts,
purchase services, provision infrastructure, or move production data. Slice 0
adds no network dependency or production network path.

The vendor remains behind RoomScanStudio-owned contracts. Hosted state owns
shared-lineage coordination; a validated immutable room revision remains the
sync unit and the local package remains capture truth. Private CloudKit backup
is unchanged and is not part of this topology.

## Non-negotiable implementation constraints

1. A client authenticates to the hosted API, not directly to a database or a
   privileged cloud role. General AWS credentials, database credentials, and
   service-role tokens never ship in the iOS or web clients.
2. An append inserts an immutable candidate revision and changes a project
   head in one database transaction only when the stored head equals the
   supplied expected head. A mismatch returns a typed stale-head conflict.
   Neither branch is merged, overwritten, or discarded.
3. The application database role does not own tenant tables and does not have
   `BYPASSRLS`. Every tenant table has forced row-level security, while the API
   also performs centralized authorization from the authenticated canonical
   principal. Caller-supplied tenant identifiers are never trusted as identity.
   Canonical principal and tenant context is set by the server inside each
   database transaction, cannot be set by a caller, and is cleared by
   transaction completion before a pooled connection serves another tenant.
   Security-definer functions are denied by default and individually reviewed.
4. Direct uploads land in a per-tenant quarantine prefix. A server-side worker
   verifies declared size, digest, content type, archive closure, safe paths,
   decompression bounds, contract version, revision binding, and tenant before
   logical promotion. Promotion is not an S3 rename: the worker creates and
   verifies immutable active objects, then one database transaction makes the
   validated manifest/head visible. Interrupted copies remain unreachable
   orphans for bounded collection. Possession of an upload URL is not
   publication or project authorization.
5. Default working-project sync rejects raw RGB sequences, depth, confidence,
   diagnostics, and raw capture bundles. The distinct raw-archive path requires
   an owner-controlled opt-in plus size and disclosure review.
6. Published snapshots are built from an allowlist into separate immutable
   objects. They are never derived by subtracting known-sensitive files from a
   private package. Precise GPS, world maps, raw capture evidence, diagnostics,
   private notes, full history, and unapproved material have no snapshot schema
   field.
7. S3 presigned URLs are bearer credentials and remain usable until expiry.
   Therefore a long-lived presigned URL does **not** satisfy immediate portal
   revocation. Publication may not ship until a spike proves either
   authorization on every protected asset request or another revocation-aware
   delivery path. Short expiry alone is only defense in depth. The same rule
   applies to warmed CDN and browser caches: no cache may return a protected
   byte after its authorization grant is revoked.
8. Logical trash, active database purge, deletion of every current and
   noncurrent S3 object version, quarantine/orphan/multipart state, worker and
   dead-letter payloads, derivatives/caches/mail artifacts, privacy-bearing
   logs/audit identifiers, and backup-recovery-point expiry are distinct
   inventoried states. Each has a finite approved retention rule or disclosed
   audit-integrity exception. S3 lifecycle rules are housekeeping, not proof of
   a seven-day active purge.
9. Audit events contain identifiers and actions, not room bytes, presigned
   URLs, magic-link tokens, PINs, biometric information, or free-form secrets.
   Exceptional operator access is separately authorized, attributed, alerted,
   and reviewed.
10. Guest launch, capture, save, view/edit, head export, AI package construction,
    Concept Set import, and Share Sheet handoff remain account-free and usable
    with networking disabled.

## Required feasibility spikes before Slice 4 or Slice 6 ships

These spikes prove already-approved behavior. They are not invitations to
replace it with a weaker product decision.

### Verified email magic links

Cognito supports custom authentication challenges, but a literal secure magic
link is application work. The spike must prove random high-entropy tokens stored
only as hashes, short expiry, atomic single use, replay rejection, rate limits,
uniform anti-enumeration responses, Apple private-relay addresses, cross-device
universal links, and safe handling of email scanners. A link `GET` opens a
confirmation surface; it must not consume the token until a deliberate state-
changing request. The landing page loads no third-party resources, sends
`Referrer-Policy: no-referrer`, redacts the token from access/error/analytics
logs, replaces token-bearing browser history after an opaque transaction
exchange, and keeps the token out of crash reports. Failure blocks the AWS
identity adapter rather than silently substituting passwords or email OTP.

### Explicit identity linking

Both the existing canonical principal and the candidate Apple/email identity
must have recent, independent verification. Linking requires a deliberate user
action, creates an audit record, rejects an identity already owned by another
principal, and never relies on email equality. The spike includes Apple relay
email and account-takeover controls.

### Sign in with Apple federation

The hosted adapter must perform the authorization-code exchange and validate
Apple issuer, audience/client, signature through the rotating Apple key set,
timestamps, nonce, state, and PKCE. Codes and nonces are single-use; client-
supplied email or subject claims are never trusted. The spike must reject wrong
issuer/audience/client, stale/future or bad-signature tokens, replay, missing or
mismatched state/PKCE, forged email, and key-rotation cases while accepting a
valid control. Passing this gate authenticates a provider subject; it does not
weaken the separate explicit identity-linking requirement.

### Immediate link revocation

The spike must demonstrate that after revocation no new portal HTML, metadata,
download, or asset request succeeds under a controlled clock. It must include a
positive pre-revocation control and an already-established-session control. If
the chosen asset path leaves a bearer URL usable for any residual interval, it
does not satisfy the approved guarantee and must be replaced with a revocation-
aware request path.

### Delete and restore lifecycle

A time-controlled drill must enumerate and delete all S3 object versions,
confirm active database and object purge within seven days, restore a backup
before expiry, and prove the same customer content cannot be restored after the
30-day backup boundary. Unbounded manual snapshots and object lock are forbidden
for ordinary customer content.

## Evidence comparison

Official sources were reviewed on 2026-08-12. Prices are volatile and must be
re-measured before purchasing or setting quotas.

| Requirement | Selected: AWS `us-east-1` | Viable alternative: Supabase Team `us-east-1` + Vercel Pro + independent object backup | Consequence |
| --- | --- | --- | --- |
| Conditional immutable append | PostgreSQL transaction: insert the candidate and update with `WHERE head_revision_id = expected RETURNING`; zero updated rows is stale. | The same PostgreSQL transaction can live in an app-owned RPC/API. | Both work; keep the protocol vendor-neutral. |
| Tenant isolation | PostgreSQL RLS plus a non-owner/non-`BYPASSRLS` app role, forced RLS, API authorization, and IAM isolation. [PostgreSQL RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html) | Supabase supports RLS, but its service keys bypass RLS and therefore cannot be used in ordinary request paths. [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) | Both require positive same-tenant controls for every cross-tenant denial. |
| Private object access | Private S3, TLS-only policies, KMS keys, and short-lived grants. Presigned URLs are bearer capabilities bounded by the signing credential and expiry. [S3 presigned URLs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html) | Private Storage supports signed URLs, but its documentation says an issued URL remains usable until expiry and individual revocation requires support. [Supabase private downloads](https://supabase.com/docs/guides/storage/serving/downloads) | Neither vendor's signed URL alone proves immediate revocation. |
| Encryption | S3 encrypts new objects at rest by default; select SSE-KMS and deny non-TLS access. Aurora supports KMS-backed encryption and forced TLS. [S3 encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingEncryption.html) [Aurora encryption](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Overview.Encryption.html) | Managed encryption in transit and at rest is available, with fewer app-controlled key and audit surfaces. [Supabase DPA](https://supabase.com/downloads/docs/Supabase%2BDPA%2B260601.pdf) | V1 claims managed encryption, not end-to-end or operator-inaccessible storage. |
| Delete and recovery copies | Delete every S3 version explicitly; Aurora automated backup retention and AWS Backup recovery points can be bounded. [Delete S3 versions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DeletingObjectVersions.html) [Aurora backups](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Aurora.Managing.Backups.html) [AWS Backup for S3](https://docs.aws.amazon.com/aws-backup/latest/devguide/s3-backups.html) | Supabase database backups exclude Storage objects, and deleted Storage objects are not restored by database backup; a separate object-copy system is required. [Supabase backups](https://supabase.com/docs/guides/platform/backups) [Supabase object deletion](https://supabase.com/docs/guides/storage/management/delete-objects) | AWS has fewer cross-vendor lifecycle edges. Neither option eliminates restore drills. |
| Audit/operator access | CloudTrail plus explicitly enabled S3 data events, application audit records, database audit logs, protected export, and least-privilege roles. [CloudTrail](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/how-cloudtrail-works.html) [S3 data events](https://docs.aws.amazon.com/AmazonS3/latest/userguide/cloudtrail-logging-s3-info.html) | Platform audit logs and more granular platform roles require Team/Enterprise; ordinary application audit still must be built. [Supabase audit logs](https://supabase.com/docs/guides/security/platform-audit-logs) | AWS provides the more controllable evidence and break-glass path. |
| Email and Apple identity | Cognito supports Apple federation and custom challenges. Literal magic links and safe explicit linking require the gated app-owned flows above. [Cognito custom challenges](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-challenge.html) [Cognito Apple IdP](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-social-idp.html) | Supabase has native magic links and Apple. Its documented automatic linking for matching verified email and beta manual linking conflict with app-owned explicit linking unless a canonical-principal layer prevents implicit ownership changes. [Supabase identity linking](https://supabase.com/docs/guides/auth/auth-identity-linking) [Supabase Apple](https://supabase.com/docs/guides/auth/social-login/auth-apple) | Supabase is easier for sign-in; AWS is selected only with the magic-link spike. |
| Subscription billing | Stripe webhooks enter through the hosted API and are signature-checked, idempotent, and order-independent. [Stripe subscription webhooks](https://docs.stripe.com/billing/subscriptions/webhooks) | Same. | Billing is replaceable and never authorizes directly from client state. |
| Local development | PostgreSQL in containers, an S3 emulator, SAM/local Lambda tests, and an identity-adapter fake; a non-production Cognito pool is needed for end-to-end auth. | Supabase has a strong Docker-based local stack; production TLS, quotas, and provider control planes remain integration tests. [Supabase local development](https://supabase.com/docs/guides/local-development/cli/getting-started) | Supabase wins developer convenience; contract tests must not depend on either stack. |
| Web deployment | Amplify provides Git-based atomic deployment and a global CDN. [Amplify Hosting](https://docs.aws.amazon.com/amplify/latest/userguide/welcome.html) | Vercel Pro provides managed deployment and global delivery. [Vercel Pro](https://vercel.com/docs/plans/pro-plan) | Global web/CDN control planes are disclosed; authoritative private data remains in the selected U.S. region. |
| Region | Database, private objects, backups, and APIs can be placed in `us-east-1`. Identity, email, payments, DNS, and CDN include global control planes/subprocessors. | Supabase offers U.S. regions and Vercel functions can be pinned, while its delivery network remains global. [Supabase regions](https://supabase.com/docs/guides/platform/regions) | Product wording is “one disclosed U.S. data region,” never “all processing stays in the U.S.” |

## Measured cost bounds

The repository currently contains two size observations, not a representative
professional workload sample:

- `find RoomScanStudio/Fixtures/MockRoom-v1 -type f -exec stat ...` measured
  eight files totaling **2,500,500 bytes (2.385 MiB)**. This fixture is a lower
  bound: it has semantic documents and a thumbnail, but not the complete hosted
  working set promised by the design.
- `Docs/PHOTOREAL_ROADMAP.md` records one physical-device raw capture export of
  **204 files / 36.7 MB**. Raw capture is excluded from default sync, so this is
  an upper proxy, not a default working-project measurement.

For a transparent bound, assume 1,000 active projects, ten full downloads per
project per month, at most 8 GB of database storage, 5,000 monthly active users,
one million API calls, one production environment, and no raw-archive sync.
Using the two observed sizes yields 2.5005--36.7 GB active objects and
25.005--367 GB monthly object egress.

At official rates retrieved 2026-08-12, a continuously warm 0.5-ACU Aurora
Serverless v2 floor is `0.5 * $0.12 * 730 = $43.80`; 8 GB Aurora storage is
approximately `$0.80`; S3 Standard active objects at `$0.023/GB-month` are
`$0.06--$0.84`; an illustrative full S3 recovery copy at `$0.05/GB-month` is
`$0.13--$1.84`; egress after the aggregate first 100 GB allowance is
`$0--$24.03`; one million HTTP API calls are about `$1`; and an illustrative
Data API/KMS/SES allowance adds `$2.35`. For a visible web-hosting bound, assume
ten 1.5 MB portal page loads per project and twenty three-minute production
builds: at standard Amplify rates, 15 GB served, 60 build minutes, and roughly
2 GB of retained deploy artifacts add about `$2.90` without relying on new-
account free tiers. The resulting illustrative infrastructure-service-spend
bound is
approximately **$51.04--$77.56/month** before request-level S3 charges, Lambda
duration, logs/alarms, WAF, support, taxes, engineering, security operations,
incident/on-call work, compliance work, and actual incremental backup churn.
Aurora can scale to zero, but AWS documents a typical
resume near 15 seconds and 30 seconds or more after long idle periods, so this
ADR does not assume auto-pause for the production SLO. [Aurora pricing](https://aws.amazon.com/rds/aurora/pricing/) [Aurora auto-pause](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html) [S3 pricing](https://aws.amazon.com/s3/pricing/) [AWS Backup pricing](https://aws.amazon.com/backup/pricing/) [API Gateway pricing](https://aws.amazon.com/api-gateway/pricing/)
[Amplify pricing](https://aws.amazon.com/amplify/pricing/)

The `$2.35` illustrative allowance is one million Data API calls at about
`$0.35`, one KMS key at `$1`, and 10,000 SES emails at about `$1`; request size,
key API operations, attachments, and dedicated IPs can change it. Protected
portal delivery cost is deliberately unresolved until the immediate-revocation
spike selects a path; direct S3/presigned egress cannot be assumed if that path
fails the revocation oracle.

The viable managed alternative has a much higher control-plane floor:
Supabase Team is `$599/month` and Vercel Pro is `$20/month`; observed storage is
within Supabase's included 100 GB, while the upper observed egress proxy adds
about `$3.51` at the cached overage rate. A separately recoverable object copy
adds at least the storage charge above. With one deploying Vercel seat, the
cached-egress total is roughly **$619.13--$624.35/month**; treating the same
117 GB overage as uncached raises the upper proxy to about
**$631.37/month**. These figures precede SMTP, cross-cloud replication, log
drains, support, taxes, and the still-unselected revocation-aware delivery
path. Supabase Pro plus Vercel would start near `$45/month`, but
lacks required platform audit logs and still lacks recoverable Storage-object
backup, so it is not equivalent. [Supabase pricing](https://supabase.com/pricing) [Vercel pricing](https://vercel.com/pricing)

Stripe is common to both. At an illustrative 100 domestic-card subscriptions
at `$29`, `$2,900 * 0.7% = $20.30` Billing fees and
`$2,900 * 2.9% + 100 * $0.30 = $114.10` payment fees total **$134.40/month**.
This excludes taxes, refunds, disputes, and international adjustments.
[Stripe Billing pricing](https://stripe.com/billing/pricing)

These calculations are transparent proxies from two nonrepresentative size
observations, not full operating cost, subscription pricing, or quota
recommendations. Before Slice 7 sets quotas, a small/median/large physical-room
sample must record active working-set bytes, revision deltas, published
derivatives, revocation-aware delivery traffic, request/database usage, and
backup churn. The resulting measurement must replace these proxies.

Slice 0 deliberately provisioned no hosted service, opened no vendor account,
and incurred no service bill. Consequently there is no production operating
trace from which to claim measured database load, request volume, Lambda
duration, protected-delivery egress, backup incrementality, or support burden.
The evidence available for this conditional decision is the measured
repository/capture byte data above plus a reproducible calculation against
official rate cards. That is sufficient to compare viable control-plane
floors without creating external state, but it is not a substitute for the
required workload measurement. Production selection, customer pricing, and
quotas remain blocked until the representative-room and revocation-path
measurements above are captured and this ADR is amended with actual results.

## Alternatives rejected for v1

### Supabase Team + Vercel as the primary stack

This remains technically viable with an app-owned API/principal layer and an
independent object-backup pipeline. It is rejected for v1 because its Team-tier
cost floor is materially higher, Storage backups require a second system,
issued signed URLs are not individually revocable, and its identity defaults
need compensating controls to guarantee explicit linking. Its advantages are
excellent local development, native magic links, and faster initial delivery.

### Supabase Pro + Vercel

Rejected as non-equivalent. It is inexpensive and productive, but omits the
platform audit evidence required by the approved design, has only seven-day
database backups, and database backup still excludes stored objects. Adding
only application logs does not establish exceptional operator-access evidence.

### Reusing private CloudKit backup

Rejected. The existing private custom zone and full-project CKAsset are an
explicit backup action for one Apple account. They do not implement workspace
roles, canonical principals, expected-head writes, cross-platform access,
publication, billing, audited feedback, or bounded shared-lineage retention.
Changing that meaning would violate the approved local/hosted boundary.

### A single live project object as the hosted source of truth

Rejected. Last-writer-wins objects cannot atomically coordinate an expected
head with immutable lineage and make stale branches easy to overwrite. The
database coordinates lineage; object storage stores validated immutable bytes.

## Consequences and follow-up proof

- AWS gives the team more control over lifecycle and audit evidence, at the
  cost of a larger security and operations surface than Supabase.
- Identity and portal delivery are deliberate pre-production gates. No release
  may describe them as complete from API signatures or unit tests alone.
- A full cross-tenant matrix, conditional-write race, backup restore/expiry
  drill, magic-link attack suite, Stripe retry/order suite, signed-object denial
  suite, and region inventory are required in their owning slices.
- A publication kill switch must deny new snapshot creation, revoke link
  authorization, and leave local capture/export and private project recovery
  available.
- The selected stack can be replaced without changing the v1 contracts defined
  in `RoomScanCore`; vendor types do not cross that module boundary.
