import assert from "node:assert/strict";
import test from "node:test";

import {
  CognitoAppleCustomAuthAdminAdapter,
  StatelessAppleCustomChallengePort,
  encodeAppleSessionChallengeAnswer,
  type AppleBridgeConsumer,
} from "../src/composition/cognito-apple-challenge.js";
import type { CognitoAppleSessionChallenge } from "../src/adapters/cognito-custom-auth.js";

test("stateless Apple custom challenge accepts only a canonical HMAC-bound answer and consumes the bridge once", async () => {
  const consumed: CognitoAppleSessionChallenge[] = [];
  const bridge: AppleBridgeConsumer = {
    consumeAndIssue: async (challenge) => {
      consumed.push(challenge);
      return { principalCanonicalId: "prn_abcdefghijklmnopqrstuv", familyPublicId: challenge.familyPublicId };
    },
  };
  const key = Buffer.alloc(32, 7);
  const port = new StatelessAppleCustomChallengePort({
    bridge, sharedHmacKey: key, random: { bytes: () => Buffer.alloc(16, 3) },
  });
  const bound = await port.createKnown();
  assert.match(bound.selector, /^[A-Za-z0-9_-]{22}$/u);
  assert.match(bound.proof, /^[A-Za-z0-9_-]{43}$/u);
  assert.equal(bound.synthetic, false);
  const challenge = appleSessionChallenge();
  const answer = encodeAppleSessionChallengeAnswer({ selector: bound.selector, challenge, sharedHmacKey: key });

  assert.equal(await port.verify({ ...bound, answer, synthetic: false }), true);
  assert.deepEqual(consumed, [challenge]);
  assert.equal(await port.verify({ ...bound, answer: `${answer}x`, synthetic: false }), false);
  assert.equal(await port.verify({ ...bound, answer, synthetic: true }), false);
  assert.equal(consumed.length, 1);
});

test("synthetic Cognito challenge remains indistinguishable in shape but cannot consume an Apple bridge", async () => {
  let consumed = false;
  const port = new StatelessAppleCustomChallengePort({
    bridge: { consumeAndIssue: async () => { consumed = true; return { principalCanonicalId: "prn_abcdefghijklmnopqrstuv", familyPublicId: "fam_abcdefghijklmnop" }; } },
    sharedHmacKey: Buffer.alloc(32, 8), random: { bytes: () => Buffer.alloc(16, 4) },
  });
  const synthetic = await port.createSyntheticWithoutDelivery();
  assert.match(synthetic.selector, /^[A-Za-z0-9_-]{22}$/u);
  assert.match(synthetic.proof, /^[A-Za-z0-9_-]{43}$/u);
  assert.equal(synthetic.synthetic, true);
  assert.equal(await port.verify({ ...synthetic, answer: "x".repeat(43), synthetic: true }), false);
  assert.equal(consumed, false);
});

test("API-side Cognito adapter uses the secretless server custom-auth client, opaque HMAC username, and discards provider tokens", async () => {
  const key = Buffer.alloc(32, 9);
  const bridge: AppleBridgeConsumer = {
    consumeAndIssue: async (challenge) => ({ principalCanonicalId: "prn_abcdefghijklmnopqrstuv", familyPublicId: challenge.familyPublicId }),
  };
  const challengePort = new StatelessAppleCustomChallengePort({ bridge, sharedHmacKey: key, random: { bytes: () => Buffer.alloc(16, 10) } });
  const calls: Array<Readonly<Record<string, string>>> = [];
  let privateState: Awaited<ReturnType<typeof challengePort.createKnown>> | undefined;
  const admin = new CognitoAppleCustomAuthAdminAdapter({
    clientId: "roomscan-server-custom-auth", sharedHmacKey: key,
    transport: {
      ensureExistingUser: async (input) => { calls.push({ kind: "ensure", ...input }); },
      initiateCustomAuth: async (input) => {
        calls.push({ kind: "initiate", ...input });
        privateState = await challengePort.createKnown();
        return { session: "server-cognito-session", selector: privateState.selector };
      },
      respondToCustomAuthChallenge: async (input) => {
        calls.push({ kind: "respond", username: input.username, clientId: input.clientId, session: input.session, answer: input.answer });
        const correct = privateState === undefined ? false : await challengePort.verify({ ...privateState, answer: input.answer, synthetic: false });
        if (!correct) throw new Error("challenge rejected");
        return { outcome: "authenticated" as const };
      },
      linkFederatedIdentity: async (input) => { calls.push({ kind: "link", ...input }); },
    },
  });
  const challenge = appleSessionChallenge();
  assert.deepEqual(await admin.adminAuthenticate({ issuer: "https://appleid.apple.com", subject: "apple-subject", attemptId: challenge.attemptId, purpose: "sign-in", challenge }), { outcome: "authenticated" });
  assert.equal(calls.some((call) => "clientMetadata" in call || "secretHash" in call), false);
  assert.equal(calls[0]?.username?.includes("apple-subject"), false);
});

function appleSessionChallenge(): CognitoAppleSessionChallenge {
  return {
    kind: "roomscan-apple-session-v1", attemptId: "apple_attempt_abcdefghijklmnop", purpose: "sign-in", bridgeProof: Buffer.alloc(32, 1).toString("base64url"),
    familyPublicId: "fam_abcdefghijklmnop", accessTokenHash: Buffer.alloc(32, 2).toString("base64url"), refreshTokenHash: Buffer.alloc(32, 3).toString("base64url"),
    authenticatedAt: "2030-01-01T00:00:00.000Z", issuedAt: "2030-01-01T00:00:00.000Z", accessExpiresAt: "2030-01-01T00:05:00.000Z",
    inactivityExpiresAt: "2030-01-08T00:00:00.000Z", absoluteExpiresAt: "2030-01-31T00:00:00.000Z", policyVersion: "session-v1",
  };
}
