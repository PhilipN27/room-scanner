import { createHash } from 'node:crypto';

export const ids = Object.freeze({
  principalA: '10000000-0000-4000-8000-000000000001',
  principalB: '10000000-0000-4000-8000-000000000002',
  principalMember: '10000000-0000-4000-8000-000000000003',
  principalInvitee: '10000000-0000-4000-8000-000000000004',
  principalExtraOwner: '10000000-0000-4000-8000-000000000005',
  workspaceA: '20000000-0000-4000-8000-000000000001',
  workspaceB: '20000000-0000-4000-8000-000000000002',
  projectA: '30000000-0000-4000-8000-000000000001',
  projectB: '30000000-0000-4000-8000-000000000002',
  invitationA: '40000000-0000-4000-8000-000000000001',
  invitationB: '40000000-0000-4000-8000-000000000002',
});

export function hash32(value) {
  return createHash('sha256').update(value).digest();
}

export async function seedCoreFixtures(pool) {
  await pool.query(
    `INSERT INTO roomscan.principals (id, normalized_email)
     VALUES
       ($1, 'owner-a@example.invalid'),
       ($2, 'owner-b@example.invalid'),
       ($3, 'member-a@example.invalid'),
       ($4, 'invitee@example.invalid'),
       ($5, 'second-owner@example.invalid')`,
    [
      ids.principalA,
      ids.principalB,
      ids.principalMember,
      ids.principalInvitee,
      ids.principalExtraOwner,
    ],
  );
  await pool.query(
    `INSERT INTO roomscan.workspaces (id, slug, display_name)
     VALUES ($1, 'workspace-a', 'Workspace A'), ($2, 'workspace-b', 'Workspace B')`,
    [ids.workspaceA, ids.workspaceB],
  );
  await pool.query(
    `INSERT INTO roomscan.memberships (workspace_id, principal_id, role, state)
     VALUES
       ($1, $3, 'owner', 'active'),
       ($2, $4, 'owner', 'active'),
       ($1, $5, 'editor', 'active')`,
    [ids.workspaceA, ids.workspaceB, ids.principalA, ids.principalB, ids.principalMember],
  );
  await pool.query(
    `INSERT INTO roomscan.projects (id, workspace_id, slug, title)
     VALUES ($1, $3, 'project-a', 'Project A'), ($2, $4, 'project-b', 'Project B')`,
    [ids.projectA, ids.projectB, ids.workspaceA, ids.workspaceB],
  );
  await pool.query(
    `INSERT INTO roomscan.invitations (
       id, workspace_id, token_hash, invited_email, invited_role, expires_at, created_by_principal_id
     ) VALUES
       ($1, $3, $5, 'invitee@example.invalid', 'editor', clock_timestamp() + interval '1 hour', $6),
       ($2, $4, $7, 'other@example.invalid', 'viewer', clock_timestamp() + interval '1 hour', $8)`,
    [
      ids.invitationA,
      ids.invitationB,
      ids.workspaceA,
      ids.workspaceB,
      hash32('invitation-a'),
      ids.principalA,
      hash32('invitation-b'),
      ids.principalB,
    ],
  );
  await pool.query(
    `INSERT INTO roomscan.subscription_states (workspace_id, plan_key, status)
     VALUES ($1, 'starter', 'active'), ($2, 'starter', 'active')`,
    [ids.workspaceA, ids.workspaceB],
  );
  await pool.query(
    `INSERT INTO roomscan.audit_states (workspace_id)
     VALUES ($1), ($2)`,
    [ids.workspaceA, ids.workspaceB],
  );
  await pool.query(
    `INSERT INTO roomscan.audit_events (workspace_id, sequence, actor_principal_id, action, subject_kind, subject_id)
     VALUES
       ($1, 1, $3, 'project.created', 'project', $4),
       ($2, 1, $5, 'project.created', 'project', $6)`,
    [ids.workspaceA, ids.workspaceB, ids.principalA, ids.projectA, ids.principalB, ids.projectB],
  );
  await pool.query(
    `INSERT INTO roomscan.operational_flags (workspace_id, flag_key, enabled, reason)
     VALUES
       ($1, 'publication.enabled', true, 'fixture'),
       ($2, 'publication.enabled', false, 'fixture')`,
    [ids.workspaceA, ids.workspaceB],
  );
}

export function appPoolConfig(cluster, max = 4) {
  return {
    host: cluster.socketDir,
    port: cluster.port,
    user: 'roomscan_app',
    database: 'postgres',
    max,
  };
}
