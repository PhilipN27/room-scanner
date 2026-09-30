# PostgreSQL contracts

Applies to this tree; inherit both parent guides.

## Exact commands

From the repository root:

```sh
npm --prefix HostedService/db ci
npm --prefix HostedService/db test
npm --prefix HostedService/db run test:staged-upgrade
npm --prefix HostedService/db run test:integration-0008-project-sync
npm --prefix HostedService/db run test:integration-0008-project-sync-security
npm --prefix HostedService/db run test:integration-0009-publication
npm --prefix HostedService/db run test:integration-0009b-idempotency-outbox
npm --prefix HostedService/db run test:integration-0009-portal-security
npm --prefix HostedService/db run test:mutations-0009-publication
```

Choose focused scripts by the real `package.json` names, then run the full matrix
for schema/role/reducer changes. The separate composed system-chain oracle and
its expected-failure control are in the hosted-verification skill.

## Disposable database only

- `test/pg-cluster.mjs` discovers PostgreSQL 16 at its explicit Homebrew/Linux
  candidates and creates a fresh `rss-pg16-*` temporary cluster. It listens only
  on an owned Unix socket, with no TCP listener, and verifies the exact postmaster
  image/PID before cleanup. Use this harness, not a shared database URL.
- Run as an unprivileged test operator. Do not stop an existing system database,
  rewrite its roles, supply production credentials or manually kill guessed PIDs.
- Verify the harness's shutdown/root-removal evidence. A failed cleanup is an
  unresolved test failure, not permission for broad deletion.

## Migration and authorization rules

- `migrations/0001` through `0009` are the accepted forward-only set.
  `migrate.mjs` binds filenames/checksums and holds a dedicated session advisory
  lock before discovery/DDL. No down/reset migrations.
- Do not casually edit accepted SQL or catalogue/digest baselines. A schema
  change needs a reviewed forward-migration/contract plan and coordinated
  manifest, staged-upgrade, catalogue and consumer tests. The current manifest
  generator deliberately rejects additional migrations until that plan updates it.
- Preserve forced RLS and credential-authenticated, non-owner/non-`BYPASSRLS`
  runtime lanes. Tenant context is server-derived and transaction-local.
- Keep fixed-search-path, least-privilege security-definer capability reducers,
  correct NULL/boolean guards, expected-head locks and immutable outbox/retry state.
  Never loosen grants or a pinned catalogue merely to satisfy a test.
- Update derived infrastructure hashes using
  `npm --prefix HostedService/infra run generate:migration-manifest`, not hand edits.
