# AI redesign platform threat model

- Version: 1.1
- Date: 2026-08-17
- Applies to: approved RoomScanStudio AI redesign platform design and local
  Slice 0–3 contracts/implementation
- Does not assert: production deployment, penetration testing, legal
  compliance, physical-device behavior, or vendor configuration

## Security and privacy invariants

1. The validated local package is immutable capture truth. A hosted service
   coordinates shared lineage; it does not rewrite capture truth or silently
   merge spatial conflicts.
2. Guest launch, local capture, local view/edit, export/share, AI package
   construction, and Concept Set import work offline without an account.
3. Private CloudKit backup remains an explicit private backup action and is not
   professional sync.
4. Default sync contains only the recoverable working set. Raw RGB, depth,
   confidence, diagnostic bundles, and similar capture evidence remain local
   unless an owner explicitly enables raw archive after size/privacy review.
5. Precise GPS is excluded from AI packages and published snapshots. A
   separately reviewed display address or approximate location is different
   data and must have explicit provenance.
6. A published snapshot is a new immutable allowlisted object graph. It is
   never a private project/package with fields removed.
7. Authorization is evaluated from an authenticated canonical principal,
   workspace membership, role, resource state, recent authentication where
   required, and link capability state. Object storage never decides access.
8. Every stale expected-head write preserves the submitted immutable candidate
   as a noncanonical branch or returns it safely to the client; it never drops,
   overwrites, or automatically merges either branch.
9. Biometric material never leaves the device. Face ID/passcode establishes a
   local sensitive-action gate, not server identity.
10. Deletion state is truthful: logical trash, active-copy purge, and backup
    expiry are separate observable events.
11. Every AI share and portal publication requires an approved disclosure
    review bound to the exact immutable source revision and exact outbound
    artifact-set/manifest digest. Changing either invalidates the approval.

## Assets and trust boundaries

High-value assets include room geometry and dimensions, posed images, textures,
raw depth/confidence, diagnostics, precise location, design intent, Concept
Sets, comments/approvals, workspace membership, identity-link records, bearer
links/PIN verifiers, session and magic-link tokens, billing entitlement,
encryption keys, audit events, and deletion/backup state.

The relevant boundaries are:

- local package and sidecar evidence on an iOS device;
- untrusted external AI/provider output entering local Concept Set staging;
- the explicit outbound disclosure/export boundary;
- iOS/web clients to the hosted API;
- hosted API to the tenant database, quarantine/active/published object stores,
  multipart-upload state, worker queues/dead-letter queues, audit/log sinks,
  identity provider, mail provider, CDN, and Stripe;
- professional workspace to accountless portal clients;
- active data to separately inventoried backups;
- ordinary service roles to exceptional operator/break-glass access.

No client crosses one of these boundaries merely because it knows a project ID,
object key, email address, or other user's opaque identifier.

Slice 3 concretely enforces the local outbound/inbound boundaries. AI-ready
cannot plan raw capture slots; both profiles exclude world maps and precise GPS;
Complete raw inclusion must exactly match a single-use source/plan/selection-
bound approval. Selected outbound images are decoded/re-encoded and advisory
sensitive-content flags never claim perfect detection. Every built archive is
independently extracted for canonical manifest and exact entry/digest closure
before sharing.

Concept import uses bounded link-free staging outside the room package, strict
archive/media/source validation, a second image re-encode, same-root atomic
promotion, and ownership-checked cleanup. Automatic view mapping requires an
authenticated finalized-package binding (the exact local canonical
manifest/ledger evidence, not account authentication); otherwise it is manual
or unmatched. The production AIRedesign path has no provider/model/auth/direct
HTTP-client dependency, and the static detector includes an injected-client
positive control. This does not describe the target's separately scoped private
CloudKit backup transport. The completed local/Simulator matrix also exercised
AI-ready/Complete deterministic extraction closure and one-shot Share Sheet
lease cleanup. These local controls do not establish physical Share Sheet/import
behavior, provider behavior/terms, or any future hosted
authorization/deployment control.

## Threats, controls, and proof obligations

| Threat | Abuse case and impact | Required controls | Proof before release |
| --- | --- | --- | --- |
| Cross-tenant IDOR or confused deputy | An authenticated member substitutes another workspace/project/asset ID, a pooled database connection retains another tenant's context, or a background job acts under the wrong tenant. | Central authorization derives tenant from canonical principal and membership; forced RLS on every tenant table; the server alone sets principal/tenant context transactionally and transaction completion clears it; caller-controlled session context and unreviewed security-definer functions are forbidden; object keys include server-owned tenant scope; job payloads are signed/scoped; ordinary roles cannot bypass RLS. | Enumerate every read/mutation/job/signed-asset path. Interleave tenant A/B requests on reused connections and attempt to forge context. Each wrong-tenant denial has a positive same-tenant control proving the path was reached. |
| Role escalation | Viewer publishes, Editor manages members, Admin transfers ownership, or a stale role continues after removal. | One server role/action matrix; owner-only operations explicit; transactionally version membership; short session authorization cache; revoke/refresh on membership change. | Complete role/action matrix plus removed-member, last-owner, invite-replay, and stale-cache tests. |
| Expected-head race or silent merge | Two editors append from one base and one silently overwrites the other. | Insert immutable candidate and compare-and-set head in one transaction; typed `409` stale result; stable idempotency key; conflict policy `preserveBranchesRequireUserResolution`. | Concurrent two-client control yields exactly one canonical append and one stale conflict, both immutable candidates recoverable, no partial canonical asset. |
| Bearer-link leakage | A link appears in referrers, logs, screenshots, browser history, analytics, chat previews, or forwarded email. | Random high-entropy unguessable token stored only as a hash; token in URL fragment or otherwise excluded from referrers where feasible; `Referrer-Policy: no-referrer`; no third-party analytics on protected pages; redacted logs; 30-day default expiry; owner-visible revoke/history; publication kill switch. | Leak canary checks for logs/referrers/analytics; expired, revoked, wrong-snapshot, and killed-publication denials with pre-revocation positive controls. |
| PIN guessing or disclosure | A short PIN is brute-forced online, logged, reused, or mistaken for encryption. | PIN is optional second gate, never the bearer secret or encryption key; memory-hard salted verifier; attempt throttling by link/account/network risk; uniform errors; lock/cooldown without enabling denial-of-service; never log or return PIN. | Controlled-clock brute-force/rate-limit suite, correct-PIN control, log scan, reset/revoke test, and distributed-attempt review. |
| Residual signed-asset access | Portal is revoked but an issued storage URL still works. | Do not equate URL expiry with immediate revocation. Use revocation-aware authorization for each protected asset request; short bearer lifetime is defense in depth. Never expose private bucket keys. | Already-established session and asset request fail immediately after revoke. If any issued URL remains usable, publication does not meet the approved guarantee. |
| Session theft/replay | A stolen refresh/access token mutates projects or performs a destructive action after logout. | Secure OS/browser storage, TLS, short access tokens, refresh rotation/reuse detection, server-side session family revocation, recent reauthentication for sensitive actions, CSRF defenses for cookie clients, no tokens in URLs/logs. | Stolen-old-token, rotated-refresh replay, logout, removed-member, expiry, CSRF, and recent-reauth tests with valid-session controls. |
| Magic-link interception, replay, scanner consumption, or landing-page leakage | Forwarded mail or an automated scanner signs in; errors enumerate accounts; the token enters access logs, referrers, history, analytics, subresource requests, or crash reports. | Random single-use token stored hashed; short TTL; atomic consumption; uniform request response; per-address/network rate limits; scanner-safe GET confirmation followed by deliberate POST; universal-link state binding; no third-party landing resources; `Referrer-Policy: no-referrer`; request/log/crash redaction; history replacement after a fragment/opaque transaction exchange where applicable; revoke prior outstanding tokens as policy requires. | Expiry, replay, concurrent consume, scanner GET, cross-device, enumeration, rate-limit, and Apple relay email tests. A token canary appears in no access/error/analytics log, referrer, crash payload, third-party request, or retained browser history, while deliberate POST consumption has a valid control. |
| Sign in with Apple token substitution or replay | A client supplies a token/code for another app, reuses a code or nonce, forges an email claim, or exploits stale signing keys/state to become the wrong canonical principal. | Server-side authorization-code exchange; validate Apple issuer, audience/client, signature and rotating key chain, timestamps, nonce, state, and PKCE; single-use code/nonce replay store; derive identity claims only from the validated response; bind the resulting provider subject to an app-owned canonical principal. | Wrong issuer/audience/client, bad signature, stale/future token, reused code/nonce, missing/mismatched state or PKCE, forged client email, and key-rotation cases fail; a valid control succeeds. |
| Identity-link takeover | Attacker with an email matching an Apple relay/changed address captures another principal. | App-owned canonical principal; never link solely on email equality; recent independent auth of both identities; explicit confirmation; reject already-owned provider identity; audit and notify linking/unlinking. | Matching-email negative cases, relay address, provider reassignment, session theft, one-side-only auth, duplicate link, and valid dual-verification control. |
| Malicious or cross-tenant upload | Attacker uploads executable/polyglot content, lies about digest/type/tenant, overwrites an object, or publishes before validation. | Server allocates immutable quarantine key and limits; checksum/length/content-type agreement; malware/content policy where applicable; parse with bounded real validator; tenant/revision binding; server-chosen active key; promote only after closure succeeds; no overwrite. | Wrong digest/length/type/tenant/revision, duplicate key, interrupted upload, polyglot, valid control, and inspection that quarantine never serves as active/public. |
| Archive traversal or decompression denial | ZIP paths escape staging, collide by case/Unicode, use symlinks, nested bombs, huge entries, or excess files. | Reuse validate-stage-promote limits: relative canonical paths only, no symlink/hardlink/device entry, duplicate/case/Unicode collision rejection, entry/count/total/ratio/depth bounds, streaming digest/CRC, bounded scratch space, cancellation cleanup. | Positive independent extraction plus traversal, absolute path, backslash, `..`, symlink, duplicate/case alias, ZIP bomb, nesting, corrupt CRC, and scratch-cleanup controls. |
| Malicious external Concept Set import | Provider output traverses paths, follows remote/external references, exhausts local storage, exploits a media parser, overwrites immutable source-package truth, or leaves partial promoted state. | Treat import as an untrusted inbound boundary on-device. Stage outside the package; apply the same bounded archive/path/digest/closure rules plus allowlisted media parsing/re-encoding; forbid network-followed and absolute references; bind the result to an existing immutable source revision; promote a new non-destructive Concept Set atomically and clean staging on every failure/cancel. | Malicious traversal/bomb/polyglot/external-reference/wrong-revision/collision fixtures cannot escape staging, contact a network, overwrite the source, or leave partial promoted state; a safe offline Concept Set control imports successfully. |
| Raw evidence uploaded by default | A sync client or future schema accidentally sends frame RGB/depth/confidence/diagnostics. | Separate working-sync and raw-archive contracts; raw classes absent from default schema path; raw archive requires owner opt-in, explicit asset policy, size/privacy review, and distinct audit event. | Default-object inventory contains no raw classes with injected-raw negative and explicit-opt-in positive controls. |
| GPS or sensitive disclosure | AI package or snapshot includes precise GPS, people/documents/screens, private notes, or unintended images; a stale review is replayed after the revision or selected assets change. | GPS has no outbound schema field; every outbound share/publication requires an approved review bound to source-revision and artifact-set/manifest digests; advisory flags never claim perfection; per-image exclusion/replacement; snapshot allowlist; strict unknown-key rejection; provenance for display address. | Pending/rejected, wrong-revision, changed-selection, and replayed-review cases fail. Inject every forbidden class and prove rejection, with exact approved-review and allowed selected-image/display-address controls. Manually inspect representative packages/snapshots. |
| Sensitive-byte smuggling | EXIF/XMP, auxiliary image data, embedded attachments, active SVG/HTML, polyglots, or a generically named download carries GPS, raw evidence, private notes, or executable content through an allowed field. | Do not trust extension, media type, or schema shape as byte safety. Decode and safely re-encode supported public media while stripping non-allowlisted metadata; reject trailing/embedded payloads and ambiguous/polyglot formats; build downloadable derivatives independently. An AI-ready download binds an exact manifest entry/source/plan/selection and must pass bounded actual-archive extraction, entry closure, and per-entry digest/size validation before serving. | EXIF-GPS, private XMP, auxiliary/trailing payload, SVG/HTML, polyglot, mislabeled private archive, renamed Complete/raw manifest, and hidden unledgered archive-entry controls are rejected or deterministically sanitized; safe re-encoded media and each allowed derivative have positive controls. |
| Snapshot confused with private package | Portal builder starts from full project/package and misses a sensitive field when subtracting. | Builder starts from empty snapshot schema and copies only enumerated fields/assets after validation and approval; separate bucket/prefix/principal; immutable snapshot digest; no access from portal role to private project storage. | Closure/allowlist test and object inventory prove raw/world map/diagnostics/GPS/private notes/history absent; mutation controls show the probe catches each injected field. |
| Stored browser-content injection | A comment, brief, design request, concept/brand value, filename, metadata value, or uploaded active document executes in a professional or portal browser and steals a session/link or performs an authorized action. | Contextual output encoding and no raw HTML; strict allowlist sanitizer only where formatted content is approved; restrictive CSP and Trusted Types where supported; no third-party script on protected pages; isolate untrusted media on a non-credentialed origin; serve active formats as attachments rather than inline. | Persist attack canaries in every rendered free-form field and in SVG/HTML filenames/metadata/attachments. The real workspace and portal renderers neither execute nor exfiltrate them; benign formatted-text controls still render. |
| Feedback mutates truth | Accountless Approve/Request Changes/comment endpoint edits geometry, concepts, membership, or revisions. | Feedback is an append-only audited resource scoped to a link/snapshot; service layer exposes no project mutation capability; verified email state is scoped and expiry-bound. | Capability-level test proves feedback role cannot call any project mutation; valid feedback and invalid cross-link controls. |
| Operator or support abuse | Privileged staff browse room images, export secrets, or alter deletion/audit state without attribution. | Least-privilege separated roles; no standing production data access; time-bound approval/break-glass; reason and ticket; alerting; protected immutable audit; privacy-aware support tooling; periodic review. | Access review, assumed-role attribution, denied ordinary-role controls, break-glass alert drill, audit tamper test, and log-content scan. |
| Deletion illusion or resurrection | UI says deleted while current/noncurrent objects, replicas, quarantine/staging, incomplete multipart uploads, worker/job/DLQ payloads, derived snapshots, CDN/browser caches, email artifacts, logs, audit identifiers, or restorable backups remain; a retry resurrects content. | Explicit deletion state machine; immediate link authorization and cache denial; idempotent per-store purge inventory covering DB, all object versions, quarantine/orphans/multipart state, queues/DLQs, derivatives, caches, and mail artifacts; bounded privacy-aware log/audit retention with a disclosed finite exception where deletion would undermine required audit integrity; backup recovery-point expiry; tombstone/idempotency rules; no indefinite manual snapshots. | Controlled-clock 30-day trash/permanent-delete, active customer-content purge <=7 days, cache/mail/queue/log/audit inventory, restore before backup expiry, non-restorable after <=30 days, retry and orphan inventory tests. |
| Publication kill-switch failure | Incident response disables UI but existing/new links and asset grants continue. | Server-side kill state checked for snapshot creation, link authorization, feedback, downloads, and every protected asset request; separately revocable tenant/global scopes; local workflows independent. | Enable during active sessions and concurrent publication; all public grants fail while private export/recovery and offline local flows remain usable. |
| Billing webhook forgery/order bugs | Forged, duplicated, delayed, or out-of-order Stripe events grant/strip access or delete data. | Verify signature over raw body; persist event ID; idempotent order-independent reducer; fetch authoritative subscription when ambiguous; billing changes entitlements, never deletes silently; cancellation grace is explicit. | Forged signature, duplicate, retry, out-of-order, stale snapshot, valid control, and 30-day read-only export grace tests. |
| Secret or privacy data in telemetry | Tokens, URLs, room bytes, GPS, emails, or free-form requests enter logs/crash reports/traces. | Structured allowlisted logging; identifier hashing/pseudonymization where useful; parameter redaction at ingress; no request/archive bodies; bounded retention/access; synthetic secret canaries. | Automated canary scan of app/API/worker/audit logs and crash payloads with a positive detector control. |
| Resource exhaustion and cost abuse | Huge uploads, repeated derivatives, portal scraping, link guessing, or comment spam exhaust compute/storage/egress. | Declared and enforced quotas; upload size/count/time bounds; per-principal/link/network rate limits; asynchronous bounded workers; derivative caching by immutable digest; spend alarms and publication kill switch; warnings, never silent deletion. | Boundary/load tests for small/median/large rooms, retry storms, portal traffic, and quota messages; reconcile measured usage to billing. |
| Cross-parser or path-identity differential | Duplicate JSON members select different values in Swift and the hosted service, escaped key spellings bypass duplicate checks, or case/Unicode-equivalent paths collide on materialization. | Reject decoded duplicate member names before object materialization; decode typed models only from the same validated tree; use portable ASCII v1 paths and case-folded collision identity; revalidate the completed tree. | Top-level/nested/escaped duplicate keys, case aliases, and NFC/NFD-style non-ASCII paths fail, while distinct safe controls pass in every implementation. |
| Supply-chain or deployment compromise | Dependency/update or CI credential alters validator, publication allowlist, or production code. | Pinned dependencies, lockfile verification, read-only CI by default, reviewed provenance, least-privilege deployment identity, separated environments, artifact/SBOM scanning, protected production promotion. | Lockfile and built-artifact inspection, dependency/license scan, unauthorized-deploy denial, and rollback drill. |
| Hosted bootstrap couples or observes guest workflows | Startup authentication, remote configuration, telemetry, entitlement lookup, or hosted SDK initialization blocks or emits data during guest/local capture, export, AI-package construction, Concept Set import, or Share Sheet preparation. | Keep local workflow dependencies below a network-free boundary; do not require a hosted client, account, remote flag, or telemetry startup for guest paths; make hosted adapters explicit opt-in dependencies after account entry. | Bootstrap the real test environment and complete simulated capture/save, local load/edit, legacy export, AI-package construction, disclosure, lease cleanup, and Concept import; independently reject production HTTP/auth clients with a source oracle whose injected `URLSession` control must fail. Physical Share Sheet/import transport remains a device gate. |

## Device-only security claims

Installed SDK declarations establish APIs, not physical behavior. Before the
owning slices ship:

- RoomPlan/ARKit/LiDAR tests must exercise supported physical iPhone and iPad
  capture, pose/intrinsic conventions, mesh availability, depth/confidence,
  two-phase configuration, poor tracking, and real cleanup.
- Face ID tests must exercise success, cancellation, failure, lockout, passcode
  fallback, enrollment/domain-state changes, backgrounding, and MainActor
  handoff. `LAContext` domain state is only a local change signal, never remote
  identity evidence.
- Share Sheet tests must exercise Files/AirDrop/external-app completion,
  cancellation, error, dismissal fallback, and idempotent lease cleanup on
  physical iPhone and iPad. Optional activity type/error data must not be
  overinterpreted beyond the installed SDK contract.

Simulator, type-check, unit tests, and a successful build cannot close these
device gates.

## Residual risks and owners

- Automated sensitive-content detection remains advisory. The user disclosure
  review and structural outbound exclusions are the controlling safeguards.
- External AI providers receive deliberately shared data under their own terms.
  Provider policy and upload-limit claims require fresh official-source review
  before release.
- Managed cloud operators may be technically able to access plaintext under
  controlled roles. V1 does not claim end-to-end or zero-knowledge encryption.
- Email delivery, Apple identity, Stripe, DNS, and CDN control planes have
  subprocessors outside the authoritative U.S. data region. Product and legal
  owners must approve exact disclosures and retention wording.
- Physical security, incident staffing, audit retention, support access policy,
  RPO/RTO, and production quotas require operator approval before provisioning.

## Maintenance

Review this model when a contract version, trust boundary, provider, identity
flow, publication path, retention promise, or new outbound artifact class is
proposed. A schema addition is not automatically safe because it is additive:
new outbound fields require privacy classification, snapshot/AI-package policy,
negative fixtures, and a positive detector control.
