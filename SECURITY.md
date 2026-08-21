# Security policy

## Supported scope

This pre-release repository contains an optional, default-off professional-
service foundation, but no production/shared endpoint, provider account,
credential, customer data, price, quota policy, or deployment is configured.
Guest/local capture, packages, view/edit, legacy export, AI Room Package,
Concept Set, and Share Sheet preparation remain independent of account/hosted
initialization. Security findings may affect local files, that independence
boundary, professional identity/authorization/persistence/infrastructure,
privacy declarations, dependencies, or capture/export code.

Private CloudKit backup is opt-in and operator-configured only; no default
container, public/shared database, background synchronization, or automatic
upload is present. Treat unexpected access before explicit Check/List/Back up/
Recover, unsafe scratch cleanup, malformed archive recovery, permission-copy
errors, or privacy-manifest drift as reportable issues.

Also report authentication replay/takeover, implicit email-based identity
linking, session refresh reuse, recent-authentication bypass, cross-tenant
substitution or pooled-context leakage, role escalation/last-Owner failure,
quota deletion/degradation, forged or reordered Stripe processing, raw webhook
parsing before signature verification, overly broad S3/IAM/database access,
kill-switch bypass, eager guest hosted traffic, secret/token/biometric/GPS data
in logs, audit loss, or unsafe break-glass behavior. Immediate portal-link
revocation and full deletion/restore are future Slice 6/7 gates, not current
implemented claims.

## Reporting

Please do not disclose a suspected vulnerability in a public issue. Use the
repository's private security-advisory feature when it is enabled, or contact
the project maintainers through a verified project channel and include:

- a concise impact statement;
- affected file, version, or commit;
- safe reproduction steps;
- suggested mitigation, if known.

Do not attach real room captures, location data, private photos, email
addresses, tokens, webhook bodies/signatures, presigned URLs, credentials,
biometrics/domain state, or database dumps unless maintainers have explicitly
arranged a lawful, purpose-bounded secure transfer.

## Response expectations

Maintainers should acknowledge a report, assess reproducibility, coordinate a
fix before public disclosure, and document any security-relevant release note.
Release decisions still require independent macOS/device/CloudKit/App Store
privacy validation, final local implementation/umbrella acceptance, separately
authorized non-production AWS/Apple/Cognito/SES/Stripe evidence, physical Face
ID/passcode evidence, alarm/rotation/break-glass drills, and production owner
approval. Source, Simulator, offline synthesis, and local database checks do not
replace those gates.

## Slice 4 security-evidence reconciliation — 2026-08-21

The local PostgreSQL security boundary is now complete for the disposable test
scope: seven `LOGIN NOINHERIT NOBYPASSRLS` runtime roles, 53/53 integration
cases, 14/14 legacy mutations and 46/46 `0007` mutations passed, with `0007`
SHA-256
`c2a3af7db980d3d32933f008c17da6b68e8bdf94408e10c8bc694c5968841030`.
The current service evidence is 277/277 plus typecheck/build, including explicit
pre-resolution context clearing, and route v3 exposes 19 routes. Offline
infrastructure inspection passed 104/104 tests and 17/17 mutations with
complete migration/VPC/IAM roots and no Slice 7 resources.

The final IAM repair removes unconditional Lambda-role `kms:Decrypt` on the
SecretsKey. An exact Secrets Manager `ViaService` + `SecretARN` synth oracle and
mutation now guard that boundary; its focused live control was RED before the
repair and GREEN after restoration. This is offline policy evidence, not live
AWS IAM/KMS evaluation.

That evidence does not authorize or prove a provider environment. The hosted
umbrella, Core, complete iPhone/iPad schemes, focused 32/8 selectors, artifact
inspection and scoped static controls are now recorded; local implementation is
complete, with only the controller's final diff/docs/cleanup handoff audit
remaining. Bounded Terra service/infrastructure and iOS/documentation reviews
ended with no Critical or Important finding after the worksheet's RVI/tcpdump
remediation and re-review; they are not certification or an independent
security audit. AWS/Apple/Cognito/SES/Stripe live behavior remains
authorization-gated; physical Face ID/passcode remains owner-observed; and
production provisioning/release remains pending by design. No external action,
real data, credential, Slice 5
implementation, commit, push, PR or deployment is part of this reconciliation.
The repository is not production-ready or release-approved.
