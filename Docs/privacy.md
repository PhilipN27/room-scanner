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
