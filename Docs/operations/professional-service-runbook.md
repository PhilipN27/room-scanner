# Professional service operations runbook

- Status: pre-provisioning runbook; no live environment exists
- Region: application data plane `us-east-1`
- Scope: Slice 4 authentication, membership, entitlement/quota, billing ingress,
  audit, and fail-closed control plane

This runbook is an operator contract, not evidence that an AWS or provider
environment has been created. Every live step requires a separately authorized
environment, named operator, approved change/ticket, cost review, credentials,
rollback, and verification plan.

## Ownership

| Signal or operation | Primary owner | Required escalation |
| --- | --- | --- |
| API/Lambda/Aurora/S3 availability, latency, errors, capacity | Platform on-call | Security for suspicious authorization or data access; product for customer impact |
| Authentication, Cognito, Apple, magic-link delivery | Identity on-call | Security for replay/takeover indicators; privacy for email/identity incidents |
| Stripe ingress/reconciliation and entitlement drift | Billing on-call | Platform for queue/database failure; product/finance for customer corrections |
| CloudTrail, audit export, KMS, secret use, break glass | Security on-call | Incident commander and privacy owner |
| SES bounces/complaints and configuration-set delivery | Identity on-call | Privacy/product for messaging incidents |
| Publication flag or future protected-link traffic | Security on-call | Product/platform; Slice 6 owner before any publication enablement |

Production paging destinations and named rotations are required configuration;
offline templates intentionally fail when operator ownership is absent.

## Fail-closed operational switches

The authoritative server flags are:

| Flag | Missing/unreadable value | Effect when false |
| --- | --- | --- |
| `professional_sign_in_enabled` | false | Deny new sign-in/session issuance. Existing local guest use is unaffected. |
| `hosted_operations_enabled` | false | Deny hosted mutations and allocations. Permitted reads/exports remain available; existing data is not deleted or degraded. |
| `publication_enabled` | false | Deny every reserved publication action and future protected-asset authorization. Slice 4 leaves it false. |

Flag mutation is system/operator-only, versioned, audited, and cannot be gated
by the flag it is meant to restore. A stale or disable-then-reenable grant is
invalid. The iOS guest launch never fetches these flags; it constructs the
professional environment only after explicit professional entry.

### Incident actions

1. Authentication compromise or provider uncertainty: set
   `professional_sign_in_enabled=false`. If session integrity is uncertain,
   also disable hosted operations and revoke affected app session families.
2. Authorization, tenant isolation, database, or storage uncertainty: set
   `hosted_operations_enabled=false` and `publication_enabled=false`; stop
   affected workers without deleting queues or records.
3. Publication/link incident: set `publication_enabled=false`. Slice 4 has no
   publication endpoint, but this remains the future server-side response.
4. Billing/provider incident: leave exact raw webhook ingestion available only
   when it can still durably verify and accept receipts; pause reconciliation or
   entitlement application visibly. Never authorize from an event delta.
5. Record the flag version, actor, ticket, reason code, timestamps, affected
   environment, and verification result in the protected audit trail. Do not
   put request bodies, tokens, email, URLs, or room data in the record.

## Rollback

For a bad service release, shift the Lambda aliases to the last approved
immutable versions and disable sign-in, hosted operations, and publication
until health and authorization checks pass. Forward-only database migrations
are not rolled back destructively. If a migration is incompatible, keep the
service disabled, deploy a reviewed forward repair, rerun real-role/RLS and
pool-isolation tests, then re-enable one environment at a time.

Rollback must preserve all local packages and the local AI Room Package,
Concept Set, legacy export, and Share Sheet paths. It must not require remote
configuration during guest launch. Stripe receipts, audit events, and queued
work remain durable; do not discard or replay them manually without an
idempotency/reconciliation plan.

Re-enable order after an incident is: audit/monitoring health, database
capability and RLS proof, read-only API checks, professional sign-in, hosted
mutations, then publication only after the later Slice 6 release gate. Each
step uses a same-tenant positive control and a cross-tenant denial.

## Alarms and response

Required alarms cover API/Lambda errors and throttles, database availability
and capacity, queue age/dead letters, Stripe reconciliation lag, audit-export
lag, SES bounces/complaints/rejects, CloudTrail delivery/digest status and
heartbeat, KMS denial, and unexpected break-glass use. Alarm delivery,
acknowledgement, escalation, and recovery must be proven in an authorized
non-production environment before production. An alarm definition or offline
synth is not notification evidence.

Every page receives an owner, severity, response objective, escalation target,
and runbook link in environment configuration. Missing ownership blocks
deployment. Do not put customer content or secrets in alarm dimensions or
messages.

## Logging, audit, and retention

- Operational Lambda/API/worker logs: 30 days.
- Protected audit evidence: at most 400 days across current and noncurrent
  object versions; retained, versioned, encrypted, and deletion-restricted.
- CloudTrail includes the selected S3 data events and digest validation.
- The 400-day design is not Object Lock/WORM and is not a legal-retention claim.
- Audit/log records may contain bounded event/action/result identifiers,
  pseudonymous principal/workspace IDs, counters, durations, and correlation
  IDs only.
- Never record room bytes, filenames, arbitrary request bodies, email, GPS,
  biometrics/domain state, access/refresh/magic-link/Apple/Cognito tokens,
  completion verifiers or transfer codes, Stripe signatures/bodies, presigned
  URLs, credentials, or private keys.

Run the structured-log canary with its intentionally unsafe positive detector
control before release and after logger/ingress changes. Audit delivery uses a
durable outbox with lease/retry semantics; an in-memory log call is not durable
audit acceptance.

## Secret and key rotation

Maintain a per-environment inventory for database login secrets, application
token-HMAC keys, magic-link sealing keys, Apple client-secret signing material,
Cognito/SES references, Stripe webhook secrets, KMS keys, and deployment roles.
No credential is stored in source, a migration, a Lambda environment value, a
test fixture, a ticket, or a log.

KMS managed rotation is enabled where supported. For database and provider
secrets, establish an owner-approved cadence before production and rotate
immediately after suspected disclosure, operator departure, or material policy
change. The rotation procedure is:

1. obtain two-person change approval and identify the exact environment and
   dependent runtime lane;
2. create/activate the replacement through the provider's secret store without
   exposing its value to application logs or operators who do not need it;
3. update only the purpose-specific runtime reference/credential and prove the
   new credential against a non-customer control;
4. retain old verification/decryption material only for the bounded overlap
   required by already-issued tokens or pending encrypted delivery records;
5. revoke the old credential, prove old-use denial and new-use success, inspect
   CloudTrail/audit/alarms, and close the ticket;
6. on failure, disable the affected operation and restore only the prior secret
   reference when its confidentiality is not in doubt.

Credential initialization, rotation cadence approval, and a complete drill are
open production gates. No password has been created or applied by Slice 4.

## Break glass and support access

There is no standing tenant-data access. Ordinary support and deployment roles
cannot browse room content or assume owner/policy roles. Exceptional access
requires:

1. a declared incident and ticket with bounded purpose and affected environment;
2. approval by two separate authorized people, including the security on-call;
3. a purpose-specific role/session with a maximum lifetime of 60 minutes and no
   renewal by default;
4. immediate alerting, assumed-role attribution, commands/actions captured as
   bounded audit events, and no export to personal tools;
5. explicit termination, credential/session revocation, evidence review, and a
   post-incident access review.

If the task can be completed with aggregate state, metadata, synthetic data, or
customer-directed export, tenant-content access is not authorized. Break glass
does not override deletion, retention, audit-protection, or privacy rules.

## Incident handling

Classify identity takeover, cross-tenant access, secret disclosure, unauthorized
operator access, audit impairment, billing entitlement drift, and unexpected
data retention as security incidents. Preserve bounded logs/audit evidence;
do not copy room data into incident systems. Contain using the narrowest flag,
session revocation, queue pause, alias rollback, or credential rotation. Verify
containment with a positive same-tenant control and the corresponding denial.

Privacy and product owners determine notification and customer communication;
this repository does not make a legal determination. Recovery requires a
reviewed timeline, root cause, affected-data inventory, restoration validation,
and follow-up control/mutation test.

## Open live gates

Before any production enablement, prove in authorized non-production accounts:
API Gateway byte/header behavior, Data API transactions, IAM/KMS policies,
Aurora credentials and rotation, S3 PUT constraints, Cognito custom challenges,
Apple exchange/JWKS rotation, cross-device magic confirmation/redemption and
scanner behavior, SES delivery/bounces, Stripe signatures/exact subscription
reconciliation/retries, CloudTrail/alarms, audit exporter retries, and rollback aliases. Physical
Face ID/passcode evidence is separate. Immediate portal-link revocation belongs
to Slice 6; deletion/restore lifecycle and recovery drills belong to Slice 7.

## 2026-08-21 external-evidence packet contract

Offline infrastructure is locally accepted at 104/104 tests and 17/17 restored
mutations. Inspection found exactly nine declared assets across 28 files,
complete migration/VPC/IAM roots, no orphan or stub markers and no Slice 7
resources. That does **not** close any live gate. Before the first provider
probe, an authorized operator must create this packet outside the source tree:

```text
<approved-evidence-root>/slice4/<YYYY-MM-DD>-<environment>/
  00-authorization.md
  01-environment.json
  02-immutable-inputs.sha256
  03-provider-inventory.json
  04-probes/
    api-gateway.json
    data-api-aurora.json
    iam-kms-s3.json
    cognito-apple-magic.json
    ses.json
    stripe.json
    audit-cloudtrail-alarms.json
  05-redacted-logs/
  06-alarm-receipts/
  07-secret-rotation.md
  08-alias-rollback.md
  09-result.md
  SHA256SUMS
```

`00-authorization.md` must name the approved ticket, synthetic-only data rule,
environment/stage, AWS account and `us-east-1`, start/expiry window, named
operator and on-call owners, operator-approved spend ceiling, allowed actions,
stop conditions and rollback. `01-environment.json` records tool/runtime
versions and non-secret identifiers. `02-immutable-inputs.sha256` binds the
source revision, lockfiles, template/assets/evidence and migration digests.
`03-provider-inventory.json` records account-bound resource ARNs/IDs and status
without any secret value, token, email address, request body or customer data.

Each `04-probes/*.json` must include probe ID, UTC time, actor/role, synthetic
tenant/principal, exact request class, same-tenant positive control, paired
denial/replay/failure control, redacted response/result, correlation ID, and
the retained evidence path. Required coverage is the seven numbered provider
protocol groups in the real-device plan: API Gateway raw bytes and scanner
flow; Data API transactions/RLS/context reuse; IAM/KMS/S3 allow-and-deny;
Cognito/Apple/magic replay and anti-enumeration; SES delivery events; Stripe
signature/duplicate/order/reconciliation; and audit/CloudTrail/alarm delivery.

The packet is incomplete unless alarm delivery is acknowledged, rotation proves
new-use success plus old-use denial, alias rollback preserves guest/local work,
all files are secret-canary scanned, and `SHA256SUMS` closes every retained
artifact. `09-result.md` must separately state pass/fail/not-run for each probe
and list residual risks. Do not substitute console screenshots for machine-
readable results or record current prices in this repository.

No such packet exists yet. External evidence remains pending authorization;
production provisioning and release remain pending by design. No external
action, real data, credential, Slice 5 implementation, Slice 7 resource,
commit, push, PR or deployment is claimed here, and this runbook is not release
approval.

The final offline IAM repair removes unconditional Lambda-role `kms:Decrypt` on
the SecretsKey and guards the remaining path with an exact Secrets Manager
`ViaService` + `SecretARN` synth oracle and mutation. Its focused test was RED
before the fix and GREEN after restoration. Operators must still include live
same-resource allow and wrong-service/wrong-secret denial probes in the
authorized external packet; offline synthesis is not deployed IAM evidence.
