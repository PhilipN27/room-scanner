import assert from "node:assert/strict";
import test from "node:test";

import {
  DataApiApiPolicyCapabilityRepository,
  DataApiProviderAuditAcceptanceRepository,
  DataApiProviderAuditExportCapabilityRepository,
  DataApiStripeReconciliationCapabilityRepository,
  DataApiStripeIngressCapabilityRepository,
  PolicyCapabilityError,
} from "../src/persistence/policy-composites.js";
import type { SqlStatement } from "../src/adapters/data-api.js";

const digest = (byte: number) => Buffer.alloc(32, byte).toString("base64url");
const access = Buffer.alloc(32, 9);

test("provider-audit acceptance rejects a lane/event-code mismatch before SQL", async () => {
  let calls = 0;
  const repository = new DataApiProviderAuditAcceptanceRepository({
    execute: async () => { calls += 1; return { rows: [{ accepted: true }] }; },
  });

  await assert.rejects(
    repository.accept({
      id: "paud_abcdefghijklmnopqrstuv",
      lane: "stripe",
      eventCode: "email.delivery.accepted",
      boundedReference: "stripe_evt_abcdefghijklmnopqrstuv",
      occurredAtMs: Date.UTC(2030, 0, 1),
    }),
    PolicyCapabilityError,
  );
  assert.equal(calls, 0);
});

test("API policy composite derives quota scope from its bound access digest and carries an exact original grant", async () => {
  const statements: SqlStatement[] = [];
  const repository = new DataApiApiPolicyCapabilityRepository({
    execute: async (statement) => {
      statements.push(statement);
      return {
        rows: [{
          workspace_id: "11111111-1111-4111-8111-111111111111",
          period_key: "roomscan-period-v1:lifetime",
          idempotency_key: "reserve-0007",
          metric: "project_count",
          authorization_action: "project.create",
          resource_kind: null,
          resource_id: null,
          requested_amount: 2,
          policy_version: 3,
          expires_at: "2030-01-01T00:10:00.000Z",
          state: "reserved",
          finalized_amount: null,
          finalized_at: null,
          released_at: null,
          release_reason: null,
          created_at: "2030-01-01T00:00:00.000Z",
        }],
      };
    },
  }, { boundAccessDigest: access });

  const result = await repository.reserveQuota({
    authoritativeNowMs: Date.UTC(2030, 0, 1),
    metric: "project_count",
    periodKey: "roomscan-period-v1:lifetime",
    authorizationAction: "project.create",
    amount: 2,
    idempotencyKey: "reserve-0007",
    policyVersion: 3,
    expiresAtMs: Date.UTC(2030, 0, 1, 0, 10),
    hostedGrant: {
      hostedGlobalVersion: 7,
      hostedWorkspaceVersion: 9,
    },
  });

  assert.equal(result.workspaceInternalId, "11111111-1111-4111-8111-111111111111");
  assert.equal(result.authorizationAction, "project.create");
  assert.equal(statements.length, 1);
  const statement = statements[0]!;
  assert.match(statement.sql, /roomscan\.reserve_quota_v2/u);
  assert.match(statement.sql, /\(:authoritative_now\)::timestamptz/u);
  assert.match(statement.sql, /\(:expires_at\)::timestamptz/u);
  assert.match(statement.sql, /\(:metric\)::roomscan\.quota_metric/u);
  assert.doesNotMatch(statement.sql, /:metric::roomscan/u);
  assert.equal(statement.parameters?.some((parameter) => parameter.name === "workspace_id"), false);
  assert.deepEqual(statement.parameters?.find((parameter) => parameter.name === "access_token_hash")?.value, {
    kind: "blob", bytes: Uint8Array.from(access),
  });
  assert.deepEqual(statement.parameters?.find((parameter) => parameter.name === "publication_global_version")?.value, { kind: "null" });
  assert.deepEqual(statement.parameters?.find((parameter) => parameter.name === "publication_workspace_version")?.value, { kind: "null" });
});

test("API policy composite rejects an unknown reservation enum rather than accepting a quota allocation", async () => {
  const repository = new DataApiApiPolicyCapabilityRepository({
    execute: async () => ({ rows: [{ state: "forged" }] }),
  }, { boundAccessDigest: access });
  await assert.rejects(
    repository.reserveQuota({
      authoritativeNowMs: Date.UTC(2030, 0, 1),
      metric: "project_count", periodKey: "roomscan-period-v1:lifetime", authorizationAction: "project.create",
      amount: 1, idempotencyKey: "reserve-0007", policyVersion: 1, expiresAtMs: Date.UTC(2030, 0, 1, 0, 1),
      hostedGrant: { hostedGlobalVersion: 1, hostedWorkspaceVersion: 1 },
    }),
    PolicyCapabilityError,
  );
});

test("API quota overview reads exactly the five server-selected metrics without a caller period", async () => {
  const statements: SqlStatement[] = [];
  const metrics = ["project_count", "member_count", "working_bytes", "raw_bytes", "portal_bytes"] as const;
  const repository = new DataApiApiPolicyCapabilityRepository({
    execute: async (statement) => {
      statements.push(statement);
      return {
        rows: metrics.map((metric) => ({
          workspace_id: "11111111-1111-4111-8111-111111111111",
          metric,
          period_key: metric === "portal_bytes" ? "roomscan-period-v1:2026-08" : "roomscan-period-v1:lifetime",
          policy_version: 3,
          used: 1,
          reserved: 0,
          limit_value: 3,
          warning_threshold_percent: 80,
          reconciliation_generation: 0,
          updated_at: "2030-01-01T00:00:00.000Z",
        })),
      };
    },
  }, { boundAccessDigest: access });

  const overview = await repository.readQuotaOverview({ authoritativeNowMs: Date.UTC(2030, 0, 1) });

  assert.deepEqual(overview.map((entry) => entry.metric), metrics);
  assert.match(statements[0]!.sql, /roomscan\.read_quota_overview_v2/u);
  assert.match(statements[0]!.sql, /\(:access_token_hash\)::bytea/u);
  assert.match(statements[0]!.sql, /\(:authoritative_now\)::timestamptz/u);
  assert.equal(statements[0]!.parameters?.some((parameter) => parameter.name === "period_key"), false);
  assert.equal(statements[0]!.parameters?.some((parameter) => parameter.name === "workspace_id"), false);
});

test("API workspace activation scopes an unscoped recent session from only its bound access digest and public slug", async () => {
  const statements: SqlStatement[] = [];
  const repository = new DataApiApiPolicyCapabilityRepository({
    execute: async (statement) => {
      statements.push(statement);
      return { rows: [{
        workspace_id: "11111111-1111-4111-8111-111111111111",
        workspace_slug: "current-room",
        principal_id: "22222222-2222-4222-8222-222222222222",
        principal_canonical_id: "prn_abcdefghijklmnopqrstuv",
        family_id: "33333333-3333-4333-8333-333333333333",
        family_public_id: "fam_abcdefghijklmnop",
        role: "editor",
        authorization_version: 7,
      }] };
    },
  }, { boundAccessDigest: access });

  const activation = await (repository as unknown as {
    scopeSessionWorkspace(input: { readonly authoritativeNowMs: number; readonly slug: string }): Promise<{
      readonly workspaceInternalId: string; readonly workspaceSlug: string; readonly principalCanonicalId: string;
      readonly familyPublicId: string; readonly role: string; readonly authorizationVersion: number;
    }>;
  }).scopeSessionWorkspace({ authoritativeNowMs: Date.UTC(2030, 0, 1), slug: "current-room" });

  assert.equal(activation.workspaceInternalId, "11111111-1111-4111-8111-111111111111");
  assert.equal(activation.workspaceSlug, "current-room");
  assert.equal(activation.principalCanonicalId, "prn_abcdefghijklmnopqrstuv");
  assert.equal(activation.familyPublicId, "fam_abcdefghijklmnop");
  assert.equal(activation.role, "editor");
  assert.equal(activation.authorizationVersion, 7);
  assert.equal(statements.length, 1);
  assert.match(statements[0]!.sql, /roomscan\.scope_session_workspace_v2/u);
  assert.match(statements[0]!.sql, /\(:access_token_hash\)::bytea/u);
  assert.match(statements[0]!.sql, /\(:authoritative_now\)::timestamptz/u);
  assert.deepEqual(statements[0]!.parameters?.find((parameter) => parameter.name === "access_token_hash")?.value, {
    kind: "blob", bytes: Uint8Array.from(access),
  });
  assert.deepEqual(statements[0]!.parameters?.find((parameter) => parameter.name === "slug")?.value, {
    kind: "string", value: "current-room",
  });
  assert.equal(statements[0]!.parameters?.some((parameter) => parameter.name === "workspace_id" || parameter.name === "family_id" || parameter.name === "role"), false);
});

test("Stripe ingress composite accepts only canonical billing hashes and maps the server-owned receipt result", async () => {
  const statements: SqlStatement[] = [];
  const repository = new DataApiStripeIngressCapabilityRepository({
    execute: async (statement) => {
      statements.push(statement);
      return { rows: [{ status: "accepted", workspace_id: "11111111-1111-4111-8111-111111111111", generation: 1 }] };
    },
  });
  const result = await repository.acceptVerifiedWebhook({
    accountMode: "platform",
    accountId: "acct_serverowned0007",
    customerId: "cus_serverowned0007",
    subscriptionId: "sub_serverowned0007",
    eventId: "evt_000007",
    eventType: "customer.subscription.updated",
    objectId: "sub_serverowned0007",
    payloadSha256: "a".repeat(64),
    providerOccurredAtMs: Date.UTC(2030, 0, 1),
    receivedAtMs: Date.UTC(2030, 0, 1, 0, 1),
  });
  assert.deepEqual(result, {
    status: "accepted",
    workspaceId: "11111111-1111-4111-8111-111111111111",
    generation: 1,
  });
  assert.match(statements[0]!.sql, /roomscan\.accept_stripe_event_v2/u);
  assert.match(statements[0]!.sql, /\(:provider_occurred_at\)::timestamptz/u);
  assert.deepEqual(statements[0]!.parameters?.find((parameter) => parameter.name === "payload_sha256")?.value, {
    kind: "blob", bytes: Uint8Array.from(Buffer.from("a".repeat(64), "hex")),
  });
  await assert.rejects(
    repository.acceptVerifiedWebhook({
      accountMode: "platform", accountId: "acct_serverowned0007", customerId: "cus_serverowned0007", subscriptionId: "sub_serverowned0007", eventId: "evt_000007", eventType: "customer.subscription.updated", objectId: "sub_serverowned0007",
      payloadSha256: digest(1), providerOccurredAtMs: Date.UTC(2030, 0, 1), receivedAtMs: Date.UTC(2030, 0, 1),
    }),
    PolicyCapabilityError,
  );
});

test("Stripe ingress persists an exact signed account/customer/subscription scope and rejects an object substitution", async () => {
  const statements: SqlStatement[] = [];
  const repository = new DataApiStripeIngressCapabilityRepository({
    execute: async (statement) => {
      statements.push(statement);
      return { rows: [{ status: "accepted", workspace_id: "11111111-1111-4111-8111-111111111111", generation: 1 }] };
    },
  });

  await repository.acceptVerifiedWebhook({
    accountMode: "platform",
    accountId: "acct_platform0007",
    customerId: "cus_exactcustomer0007",
    subscriptionId: "sub_exactsubscription0007",
    eventId: "evt_exactscope0007",
    eventType: "customer.subscription.updated",
    objectId: "sub_exactsubscription0007",
    payloadSha256: "a".repeat(64),
    providerOccurredAtMs: Date.UTC(2030, 0, 1),
    receivedAtMs: Date.UTC(2030, 0, 1, 0, 1),
  } as never);

  assert.deepEqual(statements[0]?.parameters?.map((parameter) => parameter.name), [
    "account_mode", "provider_account_id", "billing_customer_id", "subscription_id",
    "event_id", "event_type", "object_id", "payload_sha256", "provider_occurred_at", "received_at",
  ]);
  await assert.rejects(repository.acceptVerifiedWebhook({
    accountMode: "platform",
    accountId: "acct_platform0007",
    customerId: "cus_exactcustomer0007",
    subscriptionId: "sub_exactsubscription0007",
    eventId: "evt_substitution0007",
    eventType: "customer.subscription.updated",
    objectId: "sub_other0007",
    payloadSha256: "a".repeat(64),
    providerOccurredAtMs: Date.UTC(2030, 0, 1),
    receivedAtMs: Date.UTC(2030, 0, 1, 0, 1),
  } as never), PolicyCapabilityError);
});

test("membership and identity reducers require only server-derived access scope and exact grant/proof arguments", async () => {
  const statements: SqlStatement[] = [];
  const repository = new DataApiApiPolicyCapabilityRepository({
    execute: async (statement) => {
      statements.push(statement);
      if (statement.sql.includes("create_invitation_v2")) {
        return { rows: [{
          id: "11111111-1111-4111-8111-111111111111", workspace_id: "22222222-2222-4222-8222-222222222222",
          public_id: "inv_abcdefghijklmnop", token_hash: Buffer.alloc(32, 1), invited_email: null,
          invited_role: "editor", state: "active", version: 1, expires_at: "2030-01-01T00:10:00.000Z",
          created_by_principal_id: "33333333-3333-4333-8333-333333333333", created_at: "2030-01-01T00:00:00.000Z",
          consumed_at: null, consumed_by_principal_id: null, revoked_at: null, updated_at: "2030-01-01T00:00:00.000Z",
        }] };
      }
      if (statement.sql.includes("mint_candidate_identity_proof_v2")) {
        return { rows: [{
          status: "minted", principal_id: "33333333-3333-4333-8333-333333333333", principal_canonical_id: "prn_abcdefghijklmnopqrstuv",
          family_id: "44444444-4444-4444-8444-444444444444", family_public_id: "fam_abcdefghijklmnop", proof_expires_at: "2030-01-01T00:05:00.000Z",
        }] };
      }
      return { rows: [] };
    },
  }, { boundAccessDigest: access });
  const invitation = await repository.createInvitation({
    authoritativeNowMs: Date.UTC(2030, 0, 1), publicId: "inv_abcdefghijklmnop", tokenDigest: digest(1),
    role: "editor", expiresAtMs: Date.UTC(2030, 0, 1, 0, 10), auditEventId: "aud_abcdefghijklmnop",
    hostedGrant: { hostedGlobalVersion: 1, hostedWorkspaceVersion: 1 },
  });
  assert.equal(invitation.publicId, "inv_abcdefghijklmnop");
  const proof = await repository.mintCandidateIdentityProof({
    authoritativeNowMs: Date.UTC(2030, 0, 1), verifiedReceiptDigest: digest(2), issuer: "https://appleid.apple.com",
    purpose: "link-identity", candidateProofDigest: digest(3), expiresAtMs: Date.UTC(2030, 0, 1, 0, 5), policyVersion: "identity-v1",
  });
  assert.equal(proof.status, "minted");
  assert.equal(statements.some((statement) => statement.parameters?.some((parameter) => parameter.name === "workspace_id")), false);
  assert.match(statements[0]!.sql, /roomscan\.create_invitation_v2/u);
  assert.match(statements[1]!.sql, /roomscan\.mint_candidate_identity_proof_v2/u);
});

test("identity mutation maps the database final-auth-method denial without translating it into an invalid result", async () => {
  const statements: SqlStatement[] = [];
  const repository = new DataApiApiPolicyCapabilityRepository({
    execute: async (statement) => {
      statements.push(statement);
      return { rows: [{
        status: "final_auth_method",
        principal_id: "33333333-3333-4333-8333-333333333333",
        principal_canonical_id: "prn_abcdefghijklmnopqrstuv",
        family_id: "44444444-4444-4444-8444-444444444444",
        family_public_id: "fam_abcdefghijklmnop",
        authentication_epoch: null,
      }] };
    },
  }, { boundAccessDigest: access });

  const result = await repository.mutateIdentity({
    authoritativeNowMs: Date.UTC(2030, 0, 1),
    candidateProofDigest: digest(3),
    purpose: "unlink-identity",
    deliberateConfirmation: true,
    auditEventId: "aud_abcdefghijklmnop",
    notificationId: "notify_abcdefghijklmnop",
    identityReference: "id_abcdefghijklmnop",
    policyVersion: "identity-v1",
  });

  assert.equal(result.status, "final_auth_method");
  assert.equal(result.principalCanonicalId, "prn_abcdefghijklmnopqrstuv");
  assert.match(statements[0]!.sql, /roomscan\.mutate_identity_v2/u);
  assert.equal(statements[0]!.parameters?.some((parameter) => parameter.name === "workspace_id" || parameter.name === "principal_id"), false);
});

test("identity mutation maps the database not-linked denial without translating it into an invalid result", async () => {
  const repository = new DataApiApiPolicyCapabilityRepository({
    execute: async () => ({ rows: [{
      status: "not_linked",
      principal_id: "33333333-3333-4333-8333-333333333333",
      principal_canonical_id: "prn_abcdefghijklmnopqrstuv",
      family_id: "44444444-4444-4444-8444-444444444444",
      family_public_id: "fam_abcdefghijklmnop",
      authentication_epoch: null,
    }] }),
  }, { boundAccessDigest: access });

  const result = await repository.mutateIdentity({
    authoritativeNowMs: Date.UTC(2030, 0, 1),
    candidateProofDigest: digest(3),
    purpose: "unlink-identity",
    deliberateConfirmation: true,
    auditEventId: "aud_abcdefghijklmnop",
    notificationId: "notify_abcdefghijklmnop",
    identityReference: "id_abcdefghijklmnop",
    policyVersion: "identity-v1",
  });

  assert.equal(result.status, "not_linked");
});

test("Stripe reconciliation and durable audit export use lane-specific lease composites and fail unknown completion enums closed", async () => {
  const reconciliation = new DataApiStripeReconciliationCapabilityRepository({
    execute: async (statement) => {
      if (statement.sql.includes("claim_stripe_reconciliation_v2")) {
        return { rows: [{
          workspace_id: "11111111-1111-4111-8111-111111111111", account_mode: "platform", provider_account_id: "acct_serverowned0007", billing_customer_id: "cus_serverowned0007", subscription_id: "sub_serverowned0007", generation: 1,
          lease_id: "lease_0007", last_event_type: null, last_object_id: null, hosted_global_version: 2, hosted_workspace_version: 3,
        }] };
      }
      if (statement.sql.includes("complete_stripe_reconciliation_v2")) {
        return { rows: [{ status: "applied", needs_another_generation: false }] };
      }
      return { rows: [{ released: true }] };
    },
  });
  const claim = await reconciliation.claimReconciliation("lease_0007", Date.UTC(2030, 0, 1), Date.UTC(2030, 0, 1, 0, 1));
  assert.equal(claim?.generation, 1);
  assert.equal(claim?.hostedGlobalVersion, 2);
  assert.equal(claim?.hostedWorkspaceVersion, 3);
  const completed = await reconciliation.completeReconciliation({
    claim: claim!, snapshot: { observedAtMs: Date.UTC(2030, 0, 1), status: "active", planKey: "test-only" },
    appliedAtMs: Date.UTC(2030, 0, 1, 0, 1),
  });
  assert.deepEqual(completed, { status: "applied", needsAnotherGeneration: false });

  const audit = new DataApiProviderAuditExportCapabilityRepository({
    execute: async (statement) => {
      assert.match(statement.sql, /roomscan\.claim_provider_audit_event/u);
      return { rows: [{
        id: "paud_abcdefghijklmnop", provider_lane: "stripe", event_code: "stripe.webhook.accepted",
        bounded_reference: "evt_0007", occurred_at: "2030-01-01T00:00:00.000Z", state: "leased",
        lease_id: "lease_0007", lease_expires_at: "2030-01-01T00:01:00.000Z", delivered_at: null, delivery_attempts: 0,
      }] };
    },
  });
  const event = await audit.claim("lease_0007", Date.UTC(2030, 0, 1), Date.UTC(2030, 0, 1, 0, 1));
  assert.equal(event?.id, "paud_abcdefghijklmnop");
});
