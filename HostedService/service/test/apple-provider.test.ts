import assert from "node:assert/strict";
import {
  createHmac,
  generateKeyPairSync,
  sign,
  verify,
} from "node:crypto";
import test from "node:test";

import {
  AppleProviderError,
  AppleStrictIdTokenVerifier,
  GeneratedAppleClientSecretReader,
} from "../src/composition/apple-provider.js";

test("generated Apple client secret is a bounded ES256 JWT rather than the raw .p8 secret", async () => {
  const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const pem = pair.privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const reader = new GeneratedAppleClientSecretReader({
    privateKeySecrets: { read: async (name) => name === "apple-p8" ? pem : "" },
    privateKeySecretName: "apple-p8",
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    clientId: "com.roomscan.test",
    lifetimeSeconds: 300,
    clock: { nowMs: () => Date.UTC(2030, 0, 1) },
  });

  const jwt = await reader.read("roomscan-generated-apple-client-secret");
  const [encodedHeader, encodedPayload, encodedSignature] = jwt.split(".");
  assert.equal(typeof encodedHeader, "string");
  assert.equal(typeof encodedPayload, "string");
  assert.equal(typeof encodedSignature, "string");
  assert.notEqual(jwt, pem);
  const header = JSON.parse(Buffer.from(encodedHeader!, "base64url").toString("utf8")) as Record<string, unknown>;
  const payload = JSON.parse(Buffer.from(encodedPayload!, "base64url").toString("utf8")) as Record<string, unknown>;
  assert.deepEqual(header, { alg: "ES256", kid: "KEY1234567", typ: "JWT" });
  assert.deepEqual(payload, { iss: "TEAM123456", iat: 1_893_456_000, exp: 1_893_456_300, aud: "https://appleid.apple.com", sub: "com.roomscan.test" });
  assert.equal(verify("sha256", Buffer.from(`${encodedHeader}.${encodedPayload}`), { key: pair.publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(encodedSignature!, "base64url")), true);
});

test("strict verifier refreshes Apple JWKS once for an unknown key and fails a malformed provider identity", async () => {
  const other = generateKeyPairSync("rsa", { modulusLength: 2048 }).publicKey.export({ format: "jwk" });
  let refreshes = 0;
  const verifier = new AppleStrictIdTokenVerifier({
    jwks: {
      fetch: async ({ forceRefresh }) => {
        if (forceRefresh) {
          refreshes++;
          return [];
        }
        return [{ ...other, kid: "different", use: "sig", alg: "RS256" }];
      },
    },
    nonceHmacKey: Buffer.alloc(32, 9),
    clock: { nowMs: () => Date.UTC(2030, 0, 1) },
    clockSkewMs: 30_000,
    maxTokenAgeMs: 300_000,
    cacheTtlMs: 60_000,
  });
  await assert.rejects(
    verifier.verify({
      idToken: `eyJhbGciOiJSUzI1NiIsImtpZCI6Im1pc3NpbmcifQ.eyJpc3MiOiJodHRwczovL2FwcGxlaWQuYXBwbGUuY29tIn0.${Buffer.alloc(256, 1).toString("base64url")}`,
      expectedIssuer: "https://appleid.apple.com",
      expectedAudience: "com.roomscan.test",
      expectedNonceDigest: Buffer.alloc(32, 1).toString("base64url"),
      authoritativeNowMs: Date.UTC(2030, 0, 1),
    }),
    AppleProviderError,
  );
  assert.equal(refreshes, 1);
});

test("strict verifier rechecks authoritative time after delayed JWKS retrieval", async () => {
  const issuedAt = Date.UTC(2030, 0, 1);
  let now = issuedAt;
  const pair = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const jwk = pair.publicKey.export({ format: "jwk" });
  const nonce = "apple-delayed-jwks-nonce";
  const nonceHmacKey = Buffer.alloc(32, 7);
  const verifier = new AppleStrictIdTokenVerifier({
    jwks: { fetch: async () => { now += 2_000; return [{ ...jwk, kid: "apple-key", use: "sig", alg: "RS256" }]; } },
    nonceHmacKey,
    clockSkewMs: 0,
    maxTokenAgeMs: 300_000,
    cacheTtlMs: 60_000,
    clock: { nowMs: () => now },
  });
  const token = signedIdToken(pair.privateKey, {
    iss: "https://appleid.apple.com",
    aud: "com.roomscan.test",
    sub: "apple-subject",
    nonce,
    iat: issuedAt / 1_000,
    exp: issuedAt / 1_000 + 1,
  });
  await assert.rejects(
    verifier.verify({
      idToken: token,
      expectedIssuer: "https://appleid.apple.com",
      expectedAudience: "com.roomscan.test",
      expectedNonceDigest: createHmac("sha256", nonceHmacKey).update(`nonce:${nonce}`).digest("base64url"),
      authoritativeNowMs: issuedAt,
    }),
    AppleProviderError,
  );
});

function signedIdToken(
  privateKey: ReturnType<typeof generateKeyPairSync>["privateKey"],
  claims: Readonly<Record<string, string | number>>,
): string {
  const header = Buffer.from(JSON.stringify({ alg: "RS256", kid: "apple-key", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const signingInput = `${header}.${payload}`;
  return `${signingInput}.${sign("RSA-SHA256", Buffer.from(signingInput), privateKey).toString("base64url")}`;
}
