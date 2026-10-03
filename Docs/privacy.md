# Privacy and permissions

RoomScanStudio has two deliberately separate data boundaries: account-free
local room work and an optional, default-off professional service. Local
capture, save, viewing/editing, legacy export, AI Room Package construction,
disclosure review, Concept Set import/comparison/archive/delete, and Share
Sheet preparation do not require an account or hosted initialization. The
professional client is constructed only after explicit entry. Private CloudKit
backup remains a separate explicit private-backup feature and is not
professional synchronization.

## Local collection and outbound actions

The app requests camera access only after **Prepare capture**, and when-in-use
location only after **Request GPS**. Location denial never blocks manual
location or local Save. The deterministic fixture makes no camera, AR, GPS, or
physical-biometric claim.

AI-ready structurally excludes raw RGB/depth/confidence/diagnostics, world maps,
and precise GPS. Complete still excludes world maps and precise GPS and may
include available raw evidence only after exact review and explicit approval.
Selected JPEG/PNG media is decoded and re-encoded with non-allowlisted metadata
removed; ambiguous, active, polyglot, mislabeled, or trailing-payload input is
rejected. Sensitive-content analysis is advisory and is not automatic
redaction. Concept imports are bounded, link-free, validated local inputs.

The system Share Sheet is a user-directed outbound boundary. The user reviews
the package profile, selected images/metadata, artifact inventory, warnings,
size estimate, precise-GPS exclusion, and external-provider notice before the
sheet appears. The owned temporary archive is retained only for the activity
and the local flow cleans it after completion, cancellation, error, or
dismissal fallback. Physical share targets and their provider terms remain a
device/release-owner gate.

## Optional professional-service data

When a user explicitly enters the professional service, the app-owned service
may process these categories:

- canonical principal identifiers and external identity issuer/subject
  bindings; verified-email delivery state is hash-addressed and email equality
  never links identities;
- verified-email completion IDs, transfer codes, link secrets, app sessions,
  and identity receipts only as keyed digests; S256 completion challenges and
  bounded expiry/rate state; and a narrow encrypted email-delivery envelope
  decrypted only by the dedicated mail worker immediately before send;
- app-owned access/refresh session hashes, family state, authentication time,
  revocation/reuse state, and recent-server-authentication state;
- workspace membership, role, authorization version, invitations, and bounded
  public workspace/member identifiers;
- Stripe account/customer/subscription references mapped to app-owned
  subscription and entitlement state;
- five quota dimensions—projects, members, working bytes, raw-archive bytes,
  and portal-traffic bytes—plus reservations, warnings, periods, and policy
  versions;
- privacy-bounded audit/operational records containing allowlisted event,
  action, result, correlation and pseudonymous principal/workspace identifiers,
  counters, and durations;
- future professional room resources only in the slice that explicitly adds
  them. Slice 4 does not upload/synchronize projects or publish portals.

Canonical identity, membership, subscription/quota, and audit state is designed
for PostgreSQL in the disclosed `us-east-1` application region. Private,
versioned object boundaries use server-owned tenant scope. Object storage never
authorizes and clients receive no database, AWS, service-role, or Cognito
credential/token.

## Service providers and geography

The selected service boundary uses AWS API Gateway, Lambda, Aurora PostgreSQL,
S3, KMS, CloudWatch/CloudTrail, Cognito, and SES; Apple supplies Sign in with
Apple identity/JWKS and relay-email behavior; Stripe supplies billing webhook
and subscription state. DNS, email delivery, identity, payments, CDN, and AWS
management/control planes can use global systems and subprocessors. The
accurate claim is one disclosed U.S. application data region, not that all
processing occurs in the United States.

Managed operators may be technically capable of plaintext access under
controlled roles. RoomScanStudio v1 makes no end-to-end-encryption,
zero-knowledge, operator-inaccessible, or all-processing-in-U.S. claim. There
is no standing tenant-data access; exceptional access follows the two-person,
ticketed, alerted, at-most-60-minute break-glass procedure in the
[professional-service runbook](operations/professional-service-runbook.md).

## Device authentication boundary

Face ID/device passcode protects local professional-session material and
sensitive-action confirmation. Biometric material and LocalAuthentication
domain state remain on the device, never enter server identity or audit data,
and never satisfy server recent-authentication requirements. Backgrounding
clears plaintext professional state and the local proof. Simulator/unit/build
evidence does not establish physical Face ID, lockout, passcode fallback,
no-passcode, lifecycle, or enrollment-change behavior.

## Logging, retention, and deletion limits

Operational logs have a 30-day target. Protected, privacy-bounded audit
evidence has an at-most-400-day design across current/noncurrent versions; this
is not an Object Lock/WORM or legal-retention claim. Logs and audit must never
contain room bytes, filenames, arbitrary request bodies, email addresses,
access/refresh/magic-link/Apple/Cognito tokens, Stripe signatures or raw bodies,
completion verifiers or transfer codes, presigned URLs, credentials, private
keys, GPS, biometrics/domain state, or free-form user content.

Production deletion/restore lifecycle evidence is Slice 7, not a Slice 4
claim. Immediate portal-link revocation belongs to Slice 6. Quota downgrade or
hosted rollback warns and denies new allocations as applicable; it never
silently deletes, compresses, or degrades existing data. Production prices and
quota numbers remain unapproved; checked-in small values are test-only.

## Release disclosures

The in-app Privacy Policy route reads the operator-owned
`ROOMSCANSTUDIO_PRIVACY_POLICY_URL` build setting. It accepts only an absolute
HTTPS URL without credentials, fragments, control characters, or an unresolved
build token. Blank/invalid configuration visibly says the policy is not
configured. `PrivacyInfo.xcprivacy` currently declares tracking false, no
tracking domains, and File Timestamp (`C617.1`) and User Defaults (`CA92.1`)
required-reason APIs.

Before distribution, the Account Holder must reassess App Store disclosures
for local Share Sheet/Concept import plus professional identity, contact,
billing, usage, diagnostics/audit, environment scanning, photos/video, and
other user content. The owner must validate the App Store Connect answers,
policy metadata and in-app URL, built privacy report, provider terms,
retention/deletion wording, and Linked/Tracking determinations. This document
is not legal approval and does not assert that an empty collected-data list is
still correct.

Primary Apple references: [privacy manifests](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests) and [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/).

## Slice 4 evidence reconciliation — 2026-08-21

The newer local service/database/infrastructure results do not change this
privacy boundary. Guest launch and local work remain independent of hosted/auth
initialization; the professional boundary remains optional and default-off; no
Slice 5 project synchronization or Slice 7 resource was added. Accepted service
proof records pre-resolution context clearing, and the local database proof uses
seven least-privilege runtime roles, but neither result is evidence that any
provider received data.

This reconciliation used no real customer, room, biometric, GPS, email or
billing data and performed no AWS, Apple, Cognito, SES, Stripe, DNS, hosting,
email or CloudKit action. Local implementation is complete: the hosted
umbrella, Core, complete iPhone/iPad schemes, focused selectors, artifact
inspection, scoped static controls and bounded Terra reviews are recorded. The
controller retains only a final diff/docs/cleanup handoff audit. Authorized
non-production provider evidence and the physical Face ID/
passcode worksheet remain open; production privacy decisions, provisioning and
release approval remain pending by design. The repository is not
production-ready or legally/release approved.

## Slice 5 storage and synchronization addendum — 2026-08-29

The Slice 4 reconciliation above is historical. Slice 5 now supports explicit
professional project migration and synchronization, but guest use remains
offline/account-free and the existing private CloudKit backup remains a
separate opt-in system. Professional transport is still constructed only after
explicit professional entry; there is no upload observer on app launch, local
save, foregrounding, or network restoration.

The default recoverable professional working set may contain the raw-redacted
room package, immutable local revisions, semantic documents, native USDZ/raw
mesh already in the supported package, redesign/orientation state, Concept Sets
and attachments, and exact canonical AI-ready provenance manifests required by
included automatic mappings. It does not contain capture-bundle enumeration,
frame RGB, depth, confidence, diagnostics, a world map, AI artifact payloads,
or precise GPS. Tests first inject a forbidden raw artifact to prove the
detector reaches the archive and then require the ordinary working object to be
clean.

Full capture evidence is a separate default-off raw archive. Enabling it
requires an owner/recent-auth size and privacy review bound to the exact
revision, selected ledger, and SHA-256 digest. Its bytes use a separate object
tier, quota reservation, audit action, and manifest; attachment never changes
the canonical project head. Approval does not retroactively authorize scanning
or background enumeration of local capture sidecars.

Client journals contain public hosted mappings, acknowledged/local draft heads,
stable idempotency state, conflict public IDs, and recovery phase only. They do
not persist room bytes, tokens, signed URLs, object keys/versions, database IDs,
or lease plaintext. Ordinary logs likewise exclude request bodies, filenames,
free-form project content, precise GPS, room/raw bytes, credentials, and storage
coordinates.

Recovery downloads enter an owned scratch area, validate exact outer and
manifest digests and all package/companion bytes, then use the existing local
prepare/commit recovery boundary. Corrupt or interrupted input does not mutate
the live project. Canonical and stale branches remain separately recoverable;
conflict handling does not infer geometry. Rollback disables new hosted writes
without deleting remote immutable versions or local packages/drafts.

No real customer, room, biometric, GPS, identity, billing, or raw-capture data
was used for local Slice 5 verification. No AWS, CloudKit, Apple, Cognito, SES,
Stripe, DNS, email, hosting, deployment, or account mutation is claimed.
Physical-device, live-provider, production retention/quota, legal disclosure,
and release approval remain external gates.

## Slice 6 published-snapshot and portal addendum — 2026-08-31

Publication creates a new privacy-minimized immutable snapshot from an empty
versioned allowlist. It may contain web-optimized geometry/textures, semantic
layout, selected sanitized images, floor plan, dimensions, bounded warnings,
approved comparisons, constrained business/contact/accent branding, explicit
downloads, and required RoomScanStudio attribution/disclaimers. It cannot
represent raw RGB/depth/confidence, diagnostics, world maps, precise GPS,
private notes, revision history, private packages, or unapproved working
material. Property portals disclose that rooms are independent and do not
claim shared coordinates or reconstruction.

Disclosure approval is bound to the exact hosted source revision and exact
source/selection/approval digests. Changing a source or selected public fact
requires a new review. Native recovery persists only bounded public identifiers,
digests, idempotency keys, byte count, and operation phase; it does not persist
the link secret, PIN, share/signed URL, object identity, private path, archive
bytes, or free-form content.

Portal link secrets are high-entropy fragments stored only as keyed hashes.
The browser scrubs the fragment before exchange and uses no third-party
analytics. Optional PIN material is ephemeral in native and memory-hard at the
service boundary. Feedback stores a scoped immutable action/comment plus a
keyed verified-email pseudonym; raw delivery addresses are limited to the
encrypted, short-lived email lane. Access history stores an hourly bucket,
bounded outcome/client family, and keyed network-risk digest—not raw IP, user
agent, URL, token, PIN, email, content, archive path, object key, or version.

Protected assets are private, range-bounded, and reauthorized after the exact
object read before bytes leave the service. Revocation or the publication kill
switch therefore denies the next request from an already-open session. Browser
free-form injection canaries are rendered only as text under a strict
request-independent CSP. No real customer, room, biometric, GPS, identity,
billing, email, or provider data was used in local verification, and no AWS,
CDN, domain, email, credential, deployment, legal, retention-cleanup, or release
claim is made.

## Slice 7 local deletion and personal release addendum — 2026-10-01

**Trash.** Moving a room to Trash records a `trashedAt` date in the local
package. A trashed room stays on the device for a 30-day Trash period and can
be restored at any time during it. While in Trash it cannot be edited,
exported, backed up, sent to AI redesign, or used as a professional working
copy.

**Permanent deletion.** After the 30-day period, a foreground reaper deletes
the room automatically the next time the app is active. "Delete now" in Trash
is an explicit bypass that deletes the room before the period ends. Permanent
deletion removes the local package with its revision history and its local
companions: redesign state, Concept Sets, property membership, the
professional sync journal record, and the local search index entry. Unsafe or
unowned companion files are preserved and reported rather than followed.

**Private iCloud backup deletion.** Local deletion does not touch iCloud
unless the user chooses it. The Delete-now dialog offers "Delete now and remove
iCloud backup" or "Delete now, keep iCloud backup", and individual backups can
be deleted from the backup list after confirmation. Backup deletion removes
the backup records from the user's private CloudKit database. Apple completes
erasure on its servers later, and this app cannot verify physical erasure.
Until a deletion succeeds, the request is kept in a local journal and the room
is listed as "Backup still in iCloud". The app never runs these deletions at
launch or from the automatic reaper; the reaper may only record a request,
which waits for the user to tap Retry or "Delete pending backups".

**Release scope.** Slice 7 is a personal TestFlight (internal) scope for the
operator's own devices. There is no App Store listing, so App Store privacy
disclosures and nutrition labels are deferred. No TestFlight upload has been
performed by this documentation update.

**Privacy manifest.** `RoomScanStudio/Resources/PrivacyInfo.xcprivacy` is
unchanged: tracking is false, and the declared required-reason APIs remain
`C617.1` and `CA92.1`. Private CloudKit backup data lives in the user's own
private database and is not accessible to the developer, so it is not
developer collection, and no hosted collection ships in this release.
