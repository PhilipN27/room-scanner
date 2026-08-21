import assert from "node:assert/strict";
import test from "node:test";

import {
  AuthCapabilityError,
  DataApiApiAuthCompositeRepository,
  DataApiAppleChallengeRepository,
} from "../src/persistence/auth-composites.js";
import type { SqlStatement } from "../src/adapters/data-api.js";

const digest = (byte: number) => Buffer.alloc(32, byte).toString("base64url");

function magicCompletionInput(now: number) {
  return {
    selector: "magicselector000000007", secretDigest: digest(1), completionDigest: digest(8), codeChallenge: "C".repeat(43), purpose: "sign-in" as const,
    deliveryIdentity: "relay@privaterelay.appleid.com", addressDigest: digest(2), networkDigest: digest(3), authoritativeNowMs: now,
    expiresAtMs: now + 600_000, policyVersion: "magic-link-v3", outboxId: "mdl_magic_challenge_0007", keyId: "magic-key-v1",
    sealedSecret: { iv: Buffer.alloc(12, 4), ciphertext: Buffer.alloc(32, 5), authenticationTag: Buffer.alloc(16, 6) },
    ratePolicy: { cooldownSeconds: 60, maxActiveLinks: 2, addressWindowSeconds: 900, maxAddressWindow: 3, addressDaySeconds: 86_400, maxAddressDay: 10, networkWindowSeconds: 900, maxNetworkWindow: 20 },
    maxCompletionFailures: 5, redeemNetworkWindowSeconds: 60, maxRedeemNetworkFailures: 10,
  };
}

function magicCompletionSessionRow() {
  return {
    status: "session_issued", purpose: "sign-in", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: "prn_current_principal",
    family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session", authentication_epoch: 0,
    workspace_id: null, role: null, authorization_version: null, access_expires_at: "2030-01-01T00:05:00.000Z", receipt_expires_at: null,
  };
}

test("API auth composite exposes no revoked v2 magic runtime APIs", () => {
  const repository = new DataApiApiAuthCompositeRepository({
    execute: async () => ({ rows: [] }),
  });

  assert.equal("issuePublicMagicChallenge" in repository, false);
  assert.equal("issueBoundMagicChallenge" in repository, false);
  assert.equal("consumeMagicForSession" in repository, false);
  assert.equal("consumeMagicForReceipt" in repository, false);
});

test("v3 magic completion composites persist only HMACs, require PKCE/transfer proof, and reject DB-invalid configuration before SQL", async () => {
  const statements: SqlStatement[] = [];
  const now = Date.UTC(2030, 0, 1);
  const repository = new DataApiApiAuthCompositeRepository({
    execute: async (statement) => {
      statements.push(statement);
      if (statement.sql.includes("issue_magic_challenge_v3")) {
        return { rows: [{ status: "issued", selector: "magicselector000000007", expires_at: "2030-01-01T00:10:00.000Z" }] };
      }
      if (statement.sql.includes("consume_magic_challenge_v3")) {
        return { rows: [{ status: "confirmed", purpose: "sign-in", confirmed_at: "2030-01-01T00:01:00.000Z", expires_at: "2030-01-01T00:10:00.000Z" }] };
      }
      if (statement.sql.includes("redeem_magic_completion_v3")) {
        return { rows: [magicCompletionSessionRow()] };
      }
      throw new Error("unexpected SQL");
    },
  });
  const input = magicCompletionInput(now);
  assert.deepEqual(await repository.issuePublicMagicCompletionChallenge(input), {
    status: "issued", selector: "magicselector000000007", expiresAtMs: Date.UTC(2030, 0, 1, 0, 10),
  });
  assert.equal(statements[0]?.sql.includes("issue_magic_challenge_v3"), true);
  assert.deepEqual(statements[0]?.parameters?.find((parameter) => parameter.name === "initiating_access_token_hash")?.value, { kind: "null" });
  assert.equal(statements[0]?.parameters?.find((parameter) => parameter.name === "completion_hmac")?.value.kind, "blob");
  assert.deepEqual(await repository.consumeMagicCompletionChallenge({
    selector: input.selector, secretDigest: input.secretDigest, expectedPurpose: "sign-in", authoritativeNowMs: now, transferCodeDigest: digest(9),
  }), { status: "confirmed", purpose: "sign-in", confirmedAtMs: now + 60_000, expiresAtMs: now + 600_000 });
  const redeemed = await repository.redeemMagicCompletion({
    completionDigest: input.completionDigest, codeChallenge: input.codeChallenge, transferCodeDigest: digest(9), expectedPurpose: "sign-in", networkDigest: input.networkDigest,
    authoritativeNowMs: now, familyPublicId: "fam_current_session", accessTokenDigest: digest(10), refreshTokenDigest: digest(11),
    accessExpiresAtMs: now + 300_000, inactivityExpiresAtMs: now + 600_000, absoluteExpiresAtMs: now + 600_000, sessionPolicyVersion: "session-v1",
  });
  assert.equal(redeemed.status, "session_issued");
  assert.equal(statements[2]?.sql.includes("redeem_magic_completion_v3"), true);
  await assert.rejects(
    repository.issuePublicMagicCompletionChallenge({ ...input, maxCompletionFailures: 11 }),
    AuthCapabilityError,
  );
  assert.equal(statements.length, 3, "out-of-range DB configuration must fail before a provider/Data API call");
});

test("API Apple composite claims only server-stored attempt coordinates then records a sign-in bridge", async () => {
  const statements: SqlStatement[] = [];
  const repository = new DataApiApiAuthCompositeRepository({
    execute: async (statement) => {
      statements.push(statement);
      if (statement.sql.includes("claim_apple_attempt_and_code")) {
        return { rows: [{
          status: "claimed",
          attempt_id: "apple_attempt_composite07",
          attempt_state_hash: Buffer.alloc(32, 1),
          attempt_nonce_hash: Buffer.alloc(32, 2),
          attempt_code_challenge: "A".repeat(43),
          expected_client_id: "com.roomscan.test",
          redirect_uri: "https://example.invalid/apple/callback",
          created_at: "2030-01-01T00:00:00.000Z",
          expires_at: "2030-01-01T00:05:00.000Z",
          policy_version: "apple-v1",
          purpose: "sign-in",
          initiating_principal_id: null,
          initiating_family_id: null,
          initiating_authenticated_at: null,
          claimed_at: "2030-01-01T00:01:00.000Z",
        }] };
      }
      if (statement.sql.includes("claim_apple_nonce")) return { rows: [{ claimed: true }] };
      if (statement.sql.includes("accept_apple_verified_result_v2")) {
        return { rows: [{
          status: "bridge_created",
          attempt_id: "apple_attempt_composite07",
          purpose: "sign-in",
          principal_id: null,
          family_id: null,
          expires_at: "2030-01-01T00:02:00.000Z",
        }] };
      }
      return { rows: [] };
    },
  });
  const claim = await repository.claimAppleAttemptAndCode({
    attemptId: "apple_attempt_composite07",
    stateDigest: digest(1),
    codeChallenge: "A".repeat(43),
    codeDigest: digest(3),
    claimedAtMs: Date.UTC(2030, 0, 1, 0, 1),
  });
  assert.equal(claim.status, "claimed");
  if (claim.status !== "claimed") throw new Error("test fixture");
  assert.equal(await repository.claimAppleNonce({ nonceDigest: digest(2), claimedAtMs: Date.UTC(2030, 0, 1, 0, 1) }), true);
  const accepted = await repository.acceptAppleSignInResult({
    attemptId: claim.attemptId,
    issuer: "https://appleid.apple.com",
    subject: "apple-subject-composite",
    bridgeProofDigest: digest(4),
    authoritativeNowMs: Date.UTC(2030, 0, 1, 0, 1),
    expiresAtMs: Date.UTC(2030, 0, 1, 0, 2),
    policyVersion: claim.policyVersion,
  });
  assert.deepEqual(accepted, { status: "bridge_created", attemptId: "apple_attempt_composite07", expiresAtMs: Date.UTC(2030, 0, 1, 0, 2) });
  assert.equal(statements.some((statement) => statement.sql.includes("consume_apple_bridge_and_issue_session")), false);
});

test("only the challenge repository owns bridge consumption and fails unknown result enums closed", async () => {
  const api = new DataApiApiAuthCompositeRepository({ execute: async () => ({ rows: [] }) });
  assert.equal("consumeAppleBridgeAndIssueSession" in (api as unknown as Record<string, unknown>), false);
  const challenge = new DataApiAppleChallengeRepository({ execute: async () => ({ rows: [{ status: "forged" }] }) });
  await assert.rejects(
    challenge.consumeAppleBridgeAndIssueSession({
      bridgeProofDigest: digest(1),
      familyPublicId: "fam_challenge_only_0007",
      accessTokenDigest: digest(2),
      refreshTokenDigest: digest(3),
      authenticatedAtMs: Date.UTC(2030, 0, 1),
      issuedAtMs: Date.UTC(2030, 0, 1),
      accessExpiresAtMs: Date.UTC(2030, 0, 1, 0, 5),
      inactivityExpiresAtMs: Date.UTC(2030, 0, 8),
      absoluteExpiresAtMs: Date.UTC(2030, 0, 31),
      policyVersion: "session-v1",
    }),
    AuthCapabilityError,
  );
});
