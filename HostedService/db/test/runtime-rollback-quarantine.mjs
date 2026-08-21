import assert from 'node:assert/strict';
import {
  withPrincipalTransaction,
  withResolvedAccessTransaction,
  withTenantTransaction,
} from '../runtime.mjs';

const principalId = '10000000-0000-4000-8000-000000000001';
const workspaceId = '20000000-0000-4000-8000-000000000001';
const familyId = '30000000-0000-4000-8000-000000000001';

class RollbackProbeClient {
  constructor({ rollbackError }) {
    this.rollbackError = rollbackError;
    this.queries = [];
    this.releaseArguments = [];
  }

  async query(text) {
    this.queries.push(text);
    if (text === 'ROLLBACK' && this.rollbackError !== undefined) {
      throw this.rollbackError;
    }
    if (text.includes('FROM roomscan.resolve_access_context')) {
      return {
        rows: [{
          principal_id: principalId,
          canonical_principal_id: 'prn_ABCDEFGHIJKLMNOPQRSTUV',
          family_id: familyId,
          family_public_id: 'fam_ABCDEFGHIJKLMNOP',
          workspace_id: null,
          role: null,
          authorization_version: null,
          authentication_epoch: '0',
          authenticated_at: new Date('2026-08-19T12:00:00.000Z'),
          recent_authentication: true,
        }],
      };
    }
    if (text.includes('FROM roomscan.memberships')) {
      return { rows: [{ workspace_id: workspaceId, authorization_version: '1' }] };
    }
    return { rows: [] };
  }

  release(...args) {
    this.releaseArguments.push(args);
  }
}

const helpers = [
  {
    name: 'resolved-access',
    run(pool, operation) {
      return withResolvedAccessTransaction(pool, {
        accessTokenHash: Buffer.alloc(32, 7),
        authoritativeNow: new Date('2026-08-19T12:00:01.000Z'),
      }, operation);
    },
  },
  {
    name: 'tenant',
    run(pool, operation) {
      return withTenantTransaction(pool, {
        principalId,
        requestedWorkspaceId: workspaceId,
        expectedAuthorizationVersion: 1,
      }, operation);
    },
  },
  {
    name: 'principal',
    run(pool, operation) {
      return withPrincipalTransaction(pool, { principalId }, operation);
    },
  },
];

let rollbackFailureEvictions = 0;
let rollbackSuccessControls = 0;
let originalErrorsPreserved = 0;

for (const helper of helpers) {
  for (const rollbackFails of [true, false]) {
    const operationError = new Error(`OPERATION_SENTINEL:${helper.name}:${rollbackFails}`);
    const rollbackError = rollbackFails
      ? new Error(`ROLLBACK_SENTINEL:${helper.name}`)
      : undefined;
    const client = new RollbackProbeClient({ rollbackError });
    const pool = { async connect() { return client; } };

    let surfaced;
    try {
      await helper.run(pool, async () => {
        throw operationError;
      });
    } catch (error) {
      surfaced = error;
    }

    assert.equal(surfaced, operationError, `${helper.name} replaced the operation error`);
    originalErrorsPreserved += 1;
    assert.equal(
      client.queries.filter((query) => query === 'ROLLBACK').length,
      1,
      `${helper.name} did not attempt exactly one rollback`,
    );
    assert.equal(client.releaseArguments.length, 1, `${helper.name} released more than once`);
    if (rollbackFails) {
      assert.deepEqual(
        client.releaseArguments[0],
        [rollbackError],
        `${helper.name} returned uncertain transaction state to the pool`,
      );
      rollbackFailureEvictions += 1;
    } else {
      assert.deepEqual(
        client.releaseArguments[0],
        [],
        `${helper.name} evicted a client after a successful rollback`,
      );
      rollbackSuccessControls += 1;
    }
  }
}

console.log(
  `RUNTIME_ROLLBACK_QUARANTINE_SUMMARY helpers=${helpers.length}`
  + ` rollback_failure_evictions=${rollbackFailureEvictions}`
  + ` rollback_success_controls=${rollbackSuccessControls}`
  + ` original_errors_preserved=${originalErrorsPreserved} status=pass`,
);
