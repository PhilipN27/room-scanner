import assert from "node:assert/strict";
import { test } from "node:test";

import * as appleAuth from "../apple-auth.js";
import {
  CandidateIdentityProofService,
  type IdentityTransaction,
} from "../identity-linking.js";
import type { AppleAuthTransaction } from "../apple-auth.js";
import type { MagicLinkTransaction } from "../magic-links.js";
import type { SessionTransaction } from "../sessions.js";

type EveryOperationIsAsync<T> = Exclude<{
  [Key in keyof T]: T[Key] extends (...arguments_: never[]) => infer Result
    ? Result extends Promise<unknown>
      ? never
      : Key
    : never;
}[keyof T], undefined> extends never
  ? true
  : false;

type AssertTrue<Value extends true> = Value;

const asyncContractProof: readonly [
  AssertTrue<EveryOperationIsAsync<SessionTransaction>>,
  AssertTrue<EveryOperationIsAsync<MagicLinkTransaction>>,
  AssertTrue<EveryOperationIsAsync<AppleAuthTransaction>>,
  AssertTrue<EveryOperationIsAsync<IdentityTransaction>>,
] = [true, true, true, true];

test("all SQL-shaped transaction operations expose asynchronous adapter contracts", () => {
  assert.deepEqual(asyncContractProof, [true, true, true, true]);
});

test("service modules do not expose caller-forgeable raw proof minting methods", () => {
  assert.equal(
    "issueFromAuthenticatedIdentity" in CandidateIdentityProofService.prototype,
    false,
  );
  assert.equal("AppleBridgeProofService" in appleAuth, false);
});
