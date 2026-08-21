import assert from "node:assert/strict";
import test from "node:test";

import {
  createSlice4DataApiApiHandler,
  createSlice4LambdaComposition,
  StatelessAppleCustomChallengePort,
  StripeCurrentSubscriptionHttpAdapter,
} from "../src/composition/index.js";
import { SLICE4_ROUTE_MANIFEST, type SealedRoute } from "../src/contracts/route-manifest.js";
import type { HttpApiV2Response } from "../src/http/http-api-v2.js";

const ok: HttpApiV2Response = Object.freeze({
  statusCode: 200,
  headers: Object.freeze({ "cache-control": "no-store", "content-type": "application/json" }),
  body: "{}",
});

test("composition package barrel exports the service-owned API, Cognito, and Stripe factories", () => {
  assert.equal(typeof createSlice4DataApiApiHandler, "function");
  assert.equal(typeof StatelessAppleCustomChallengePort, "function");
  assert.equal(typeof StripeCurrentSubscriptionHttpAdapter, "function");
});

test("single Lambda composition exposes only the sealed API, authorizer, Cognito, Stripe, and role-bound SQS root shapes", async () => {
  const calls: string[] = [];
  const composition = createSlice4LambdaComposition({
    api: {
      operations: { run: async (_input, operation) => operation({ principalPublicId: "prn_composition", transactionMarker: Symbol("composition"), repositories: { contract: "roomscan-transaction-repositories-v1", transactionMarker: Symbol("unreachable") } }) },
      handlers: Object.fromEntries(SLICE4_ROUTE_MANIFEST.map((route) => [route.id, async () => responseFor(route)])),
    },
    authorizer: {
      preflight: { authorizeBearer: async (token) => { calls.push(`authorizer:${token}`); return token === accessToken; } },
    },
    cognito: {
      customChallenge: {
        define: (event) => { calls.push("define"); event.response.issueTokens = false; event.response.failAuthentication = true; return event; },
        create: async (event) => { calls.push("create"); event.response.challengeMetadata = "safe"; return event; },
        verify: async (event) => { calls.push("verify"); event.response.answerCorrect = true; return event; },
      },
    },
    stripe: {
      ingress: { handle: async () => { calls.push("stripe:committed"); return ok; } },
      wake: { notify: async () => { calls.push("stripe:wake"); throw new Error("optional wake unavailable"); } },
    },
    reconciliation: {
      worker: { runOnce: async () => ({ status: "applied", generation: 1, needsAnotherGeneration: false } as const) },
    },
    auditExporter: {
      worker: { handleRecord: async (record) => { calls.push(`audit:${record.messageId}`); return record.messageId !== "retry"; } },
    },
    magicDelivery: {
      worker: { handleRecord: async (record) => { calls.push(`magic:${record.messageId}`); return record.messageId !== "magic-retry"; } },
    },
  });

  const health = await composition.api({
    version: "2.0",
    rawPath: "/health",
    rawQueryString: "",
    requestContext: { http: { method: "GET" } },
  });
  assert.equal(health.statusCode, 200);

  assert.deepEqual(await composition.authorizer({ headers: { authorization: `Bearer ${accessToken}` } }), {
    isAuthorized: true,
    context: { decision: "allow" },
  });
  assert.deepEqual(await composition.authorizer({ headers: { authorization: "Bearer malformed" } }), {
    isAuthorized: false,
    context: { decision: "deny" },
  });

  const cognito = await composition.cognito({
    triggerSource: "VerifyAuthChallengeResponse_Authentication",
    request: { privateChallengeParameters: {}, challengeAnswer: "answer" },
    response: { answerCorrect: false },
  });
  assert.equal(cognito.triggerSource, "VerifyAuthChallengeResponse_Authentication");
  if (cognito.triggerSource !== "VerifyAuthChallengeResponse_Authentication") throw new Error("unexpected trigger");
  assert.equal(cognito.response.answerCorrect, true);

  assert.equal((await composition.stripe({ body: "{}", isBase64Encoded: false, headers: { "content-type": "application/json" } })).statusCode, 200);
  assert.deepEqual(await composition.reconciliation({ Records: [{ messageId: "reconcile-ok" }, { messageId: "reconcile-ok-2" }] }), { batchItemFailures: [] });
  assert.deepEqual(await composition.auditExporter({ Records: [{ messageId: "ok" }, { messageId: "retry" }] }), { batchItemFailures: [{ itemIdentifier: "retry" }] });
  assert.deepEqual(await composition.magicDelivery({ Records: [{ messageId: "magic-ok" }, { messageId: "magic-retry" }] }), { batchItemFailures: [{ itemIdentifier: "magic-retry" }] });
  assert.deepEqual(calls, ["authorizer:" + accessToken, "verify", "stripe:committed", "stripe:wake", "audit:ok", "audit:retry", "magic:magic-ok", "magic:magic-retry"]);
});

function responseFor(route: SealedRoute): HttpApiV2Response {
  if (route.responseKind === "scanner-html") {
    return {
      statusCode: 200,
      headers: {
        "cache-control": "no-store",
        "content-security-policy": "default-src 'none'",
        "content-type": "text/html; charset=utf-8",
        "referrer-policy": "no-referrer",
      },
      body: "<!doctype html><title>Continue</title>",
    };
  }
  return ok;
}

const accessToken = Buffer.alloc(32, 0x43).toString("base64url");
