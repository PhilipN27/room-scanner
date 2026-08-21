export class TenantContextError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'TenantContextError';
    this.code = code;
  }
}

export class AccessContextError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'AccessContextError';
    this.code = code;
  }
}

function validateAccessContextRequest(context) {
  if (!context || typeof context !== 'object') {
    throw new AccessContextError(
      'INVALID_CONTEXT_REQUEST',
      'an access-token hash and authoritative time are required',
    );
  }
  const allowedKeys = new Set(['accessTokenHash', 'authoritativeNow']);
  const unexpectedKeys = Object.keys(context).filter((key) => !allowedKeys.has(key));
  if (unexpectedKeys.length > 0) {
    throw new AccessContextError(
      'CALLER_CONTEXT_REJECTED',
      `caller cannot set access context keys: ${unexpectedKeys.join(', ')}`,
    );
  }
  if (!(context.accessTokenHash instanceof Uint8Array) || context.accessTokenHash.byteLength !== 32) {
    throw new AccessContextError(
      'INVALID_CONTEXT_REQUEST',
      'a 32-byte access-token hash is required',
    );
  }
  if (!(context.authoritativeNow instanceof Date) || !Number.isFinite(context.authoritativeNow.getTime())) {
    throw new AccessContextError(
      'INVALID_CONTEXT_REQUEST',
      'a valid authoritative time is required',
    );
  }
}

function exactSafeInteger(value, field) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) {
    throw new AccessContextError('INVALID_RESOLVED_CONTEXT', `invalid ${field}`);
  }
  return number;
}

async function rollbackFailureForRelease(client, began) {
  if (!began) {
    return undefined;
  }
  try {
    await client.query('ROLLBACK');
    return undefined;
  } catch (rollbackError) {
    return rollbackError;
  }
}

function releaseTransactionClient(client, rollbackFailure) {
  if (rollbackFailure === undefined) {
    client.release();
    return;
  }
  // node-postgres destroys a checked-out client when release receives an
  // error. A failed ROLLBACK leaves transaction state unknowable, so that
  // connection must never be made available to another request.
  client.release(rollbackFailure);
}

export async function withResolvedAccessTransaction(pool, context, operation) {
  if (!pool || typeof pool.connect !== 'function') {
    throw new TypeError('withResolvedAccessTransaction requires a PostgreSQL pool');
  }
  if (typeof operation !== 'function') {
    throw new TypeError('withResolvedAccessTransaction requires an operation callback');
  }
  validateAccessContextRequest(context);

  const client = await pool.connect();
  let began = false;
  let rollbackFailure;
  try {
    await client.query('BEGIN');
    began = true;
    // Transaction-local empty values shadow any unexpected session-local
    // residue before the token resolver runs. The resolver itself reads no
    // request context and accepts no workspace argument.
    await client.query(
      `SELECT set_config('app.principal_id', '', true),
              set_config('app.tenant_id', '', true),
              set_config('app.authorization_version', '', true)`,
    );
    const { rows } = await client.query(
      `SELECT *
       FROM roomscan.resolve_access_context($1::bytea, $2::timestamptz)`,
      [Buffer.from(context.accessTokenHash), context.authoritativeNow],
    );
    if (rows.length !== 1) {
      throw new AccessContextError(
        'AUTHENTICATION_REQUIRED',
        'the access credential did not resolve an active server context',
      );
    }

    const row = rows[0];
    const authorizationVersion = row.authorization_version === null
      ? undefined
      : exactSafeInteger(row.authorization_version, 'authorization version');
    const resolved = {
      principalId: row.principal_id,
      canonicalPrincipalId: row.canonical_principal_id,
      familyId: row.family_id,
      familyPublicId: row.family_public_id,
      authenticationEpoch: exactSafeInteger(row.authentication_epoch, 'authentication epoch'),
      authenticatedAt: row.authenticated_at,
      recentAuthentication: row.recent_authentication === true,
      ...(row.workspace_id === null
        ? {}
        : {
            workspaceId: row.workspace_id,
            role: row.role,
            authorizationVersion,
          }),
    };
    if (
      typeof resolved.principalId !== 'string'
      || typeof resolved.familyId !== 'string'
      || (row.workspace_id !== null && authorizationVersion === undefined)
    ) {
      throw new AccessContextError(
        'INVALID_RESOLVED_CONTEXT',
        'the database returned an incomplete access context',
      );
    }

    await client.query(
      `SELECT set_config('app.principal_id', $1, true),
              set_config('app.tenant_id', $2, true),
              set_config('app.authorization_version', $3, true)`,
      [
        resolved.principalId,
        resolved.workspaceId ?? '',
        resolved.authorizationVersion === undefined
          ? ''
          : String(resolved.authorizationVersion),
      ],
    );
    const result = await operation(client, resolved);
    await client.query('COMMIT');
    began = false;
    return result;
  } catch (error) {
    rollbackFailure = await rollbackFailureForRelease(client, began);
    throw error;
  } finally {
    releaseTransactionClient(client, rollbackFailure);
  }
}

function validateRequestContext(context) {
  if (!context || typeof context !== 'object') {
    throw new TypeError('tenant transaction context is required');
  }
  const allowedKeys = new Set([
    'principalId',
    'requestedWorkspaceId',
    'expectedAuthorizationVersion',
  ]);
  const unexpectedKeys = Object.keys(context).filter((key) => !allowedKeys.has(key));
  if (unexpectedKeys.length > 0) {
    throw new TenantContextError(
      'CALLER_CONTEXT_REJECTED',
      `caller cannot set database context keys: ${unexpectedKeys.join(', ')}`,
    );
  }
  if (!context.principalId || !context.requestedWorkspaceId) {
    throw new TenantContextError('INVALID_CONTEXT_REQUEST', 'principal and requested workspace are required');
  }
  if (!Number.isSafeInteger(context.expectedAuthorizationVersion) || context.expectedAuthorizationVersion < 1) {
    throw new TenantContextError(
      'INVALID_CONTEXT_REQUEST',
      'a positive expected authorization version is required',
    );
  }
}

export async function withTenantTransaction(pool, context, operation) {
  if (!pool || typeof pool.connect !== 'function') {
    throw new TypeError('withTenantTransaction requires a PostgreSQL pool');
  }
  if (typeof operation !== 'function') {
    throw new TypeError('withTenantTransaction requires an operation callback');
  }
  validateRequestContext(context);

  const client = await pool.connect();
  let began = false;
  let rollbackFailure;
  try {
    await client.query('BEGIN');
    began = true;
    await client.query(
      "SELECT set_config('app.principal_id', $1, true)",
      [context.principalId],
    );

    const { rows } = await client.query(
      `SELECT workspace_id, authorization_version
       FROM roomscan.memberships
       WHERE principal_id = $1
         AND workspace_id = $2
         AND state = 'active'`,
      [context.principalId, context.requestedWorkspaceId],
    );
    if (rows.length !== 1) {
      throw new TenantContextError(
        'ACTIVE_MEMBERSHIP_REQUIRED',
        'no active membership resolves the requested workspace',
      );
    }

    const resolved = rows[0];
    if (Number(resolved.authorization_version) !== context.expectedAuthorizationVersion) {
      throw new TenantContextError(
        'STALE_AUTHORIZATION',
        'authorization version changed; refresh the authenticated session',
      );
    }

    await client.query(
      `SELECT
         set_config('app.tenant_id', $1, true),
         set_config('app.authorization_version', $2, true)`,
      [resolved.workspace_id, String(resolved.authorization_version)],
    );

    const result = await operation(client, {
      principalId: context.principalId,
      workspaceId: resolved.workspace_id,
      authorizationVersion: Number(resolved.authorization_version),
    });
    await client.query('COMMIT');
    began = false;
    return result;
  } catch (error) {
    rollbackFailure = await rollbackFailureForRelease(client, began);
    throw error;
  } finally {
    releaseTransactionClient(client, rollbackFailure);
  }
}

export async function withPrincipalTransaction(pool, context, operation) {
  if (!pool || typeof pool.connect !== 'function') {
    throw new TypeError('withPrincipalTransaction requires a PostgreSQL pool');
  }
  if (typeof operation !== 'function') {
    throw new TypeError('withPrincipalTransaction requires an operation callback');
  }
  if (!context || typeof context !== 'object' || !context.principalId) {
    throw new TenantContextError('INVALID_CONTEXT_REQUEST', 'authenticated principal is required');
  }
  const unexpectedKeys = Object.keys(context).filter((key) => key !== 'principalId');
  if (unexpectedKeys.length > 0) {
    throw new TenantContextError(
      'CALLER_CONTEXT_REJECTED',
      `caller cannot set database context keys: ${unexpectedKeys.join(', ')}`,
    );
  }

  const client = await pool.connect();
  let began = false;
  let rollbackFailure;
  try {
    await client.query('BEGIN');
    began = true;
    await client.query(
      "SELECT set_config('app.principal_id', $1, true)",
      [context.principalId],
    );
    const result = await operation(client, { principalId: context.principalId });
    await client.query('COMMIT');
    began = false;
    return result;
  } catch (error) {
    rollbackFailure = await rollbackFailureForRelease(client, began);
    throw error;
  } finally {
    releaseTransactionClient(client, rollbackFailure);
  }
}
