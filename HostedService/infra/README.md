# RoomScan hosted-service infrastructure

This package synthesizes the Slice 4 AWS control/data-plane definitions. It has
no bootstrap, diff, deploy, account-creation, DNS, quota, or production-pricing
command. Lambda integration handlers intentionally fail closed until the
corresponding service behavior is wired and verified.

## Required synthesis inputs

Every input is required; there are no ambient-account or region defaults.

- `ROOMSCAN_ACCOUNT_ID`
- `ROOMSCAN_STAGE` (`dev`, `staging`, or `production`)
- `ROOMSCAN_REGION` (only `us-east-1`)
- `ROOMSCAN_AVAILABILITY_ZONES` (two explicit, distinct `us-east-1` zones)
- `ROOMSCAN_ACCOUNT_TOPOLOGY_FILE`
- `ROOMSCAN_OPERATOR_OWNER`
- `ROOMSCAN_NOTIFICATION_EMAIL`
- `ROOMSCAN_SERVICE_DOMAIN`
- `ROOMSCAN_COGNITO_DOMAIN_PREFIX` (an available AWS-managed Cognito domain
  prefix; lowercase letters, digits, and internal hyphens only)
- `ROOMSCAN_APPLE_CLIENT_ID`, `ROOMSCAN_APPLE_TEAM_ID`, and
  `ROOMSCAN_APPLE_KEY_ID`
- `ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN`
- `ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN`
- `ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN` and
  `ROOMSCAN_STRIPE_API_SECRET_ARN`
- `ROOMSCAN_SES_IDENTITY_ARN` and
  `ROOMSCAN_SES_CONFIGURATION_SET_NAME`
- `ROOMSCAN_AURORA_MIN_ACU`, `ROOMSCAN_AURORA_MAX_ACU`, and
  `ROOMSCAN_AURORA_BACKUP_RETENTION_DAYS`

The account topology file must contain exactly the six keys shown in
`config/account-topology.example.json`; that example and all test identifiers
are intentionally non-production placeholders.

External ARN inputs are exact, complete references: Secrets Manager ARNs must
name a secret and include its six-character generated suffix, the provider KMS
ARN must use the immutable `key/<UUID>` resource rather than an alias, and the
SES ARN must contain a non-empty bounded `identity/<domain-or-address>` resource.
Partition, service, region, and account must match exactly. The same validation
runs in both the environment loader and the stack constructor.

## Offline proof

After supplying explicit dummy or operator-approved inputs:

```sh
npm run verify
```

The command performs strict type checking, 56 behavioral/policy assertions,
16 mutation controls, offline CDK synthesis, and bundle/template inspection.
Generated evidence is under `evidence/`; the synthesized assembly is under
`cdk.out/`. Both directories are intentionally ignored because they are
reproducible local artifacts.

## Security boundaries carried by this slice

The AWS-managed Cognito domain exists only as the server-side Apple federation
and redirect substrate. Apple is registered with the generated
`/oauth2/idpresponse` callback, while the authorization-code client redirects
only to the app-owned API callback. Cognito-hosted cookies are not an
app-authoritative session. Managed login advertises Apple only—never native
`COGNITO` local users—and the client enables neither implicit nor password/SRP
authentication flows. The SDK/API custom-auth substrate remains available for
the service to exchange successful challenges for its own opaque app session.

The CloudTrail status monitor runs every five minutes. It calls
`GetTrailStatus`, treats delivery or digest errors and stale timestamps as
unhealthy, and emits bounded `TrailDeliveryHealthy` and
`TrailStatusHeartbeat` metrics in `RoomScan/CloudTrail`. Missing custom metrics
breach their alarms; there is no dependency on the unsupported
`AWS/CloudTrail` `DeliveryErrors` metric tuple.

The audit bucket retains current versions for 200 days and noncurrent versions
for another 200 days, bounding a version's effective lifecycle to at most 400
days. App and operator principals are denied direct object/version deletion,
the bucket is retained if the stack is removed, and lifecycle expiry remains
AWS-managed. This definition does not claim Object Lock or WORM compliance;
live retention and recovery proof remains an operator gate.

All private buckets use their assigned customer-managed key by default. Their
policies allow requests with no encryption override, while denying a present
non-KMS algorithm, `aws:kms` without a key ID, and a present wrong KMS key ID.

The Task 6 SES adapter must include
`ROOMSCAN_SES_CONFIGURATION_SET_NAME` on every send request. Live SES identity,
sandbox/production-access, event-destination delivery, and configuration-set
attachment remain Task 6 gates; this package creates only the configuration and
event boundary.
