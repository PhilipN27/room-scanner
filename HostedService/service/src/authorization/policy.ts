export const WORKSPACE_ROLES = ["owner", "admin", "editor", "viewer"] as const;
export type WorkspaceRole = (typeof WORKSPACE_ROLES)[number];

export const AUTHORIZATION_ACTIONS = [
  "workspace.read",
  "member.read",
  "project.read",
  "private.download",
  "quota.warning.read",
  "workspace.profile.update",
  "security.read",
  "access_history.read",
  "audit.read",
  "audit.export",
  "workspace.security.change",
  "ownership.transfer",
  "workspace.permanent_delete",
  "member.invite.viewer",
  "member.revoke.viewer",
  "member.change.viewer",
  "member.remove.viewer",
  "member.invite.editor",
  "member.revoke.editor",
  "member.change.editor",
  "member.remove.editor",
  "member.invite.admin",
  "member.change.admin",
  "member.remove.admin",
  "member.add.owner",
  "member.change.owner",
  "member.remove.owner",
  "subscription.read",
  "usage.read",
  "limit.read",
  "subscription.manage",
  "billing.manage",
  "project.create",
  "project.revise",
  "concept.import",
  "concept.edit",
  "concept.archive",
  "comment.create",
  "concept.approve",
  "project.archive",
  "project.restore",
  "project.permanent_delete",
  "raw_archive.configure",
  "raw_archive.allocate",
  "publication.record.read",
  "publication.policy.change",
  "publication.create",
  "publication.update",
  "publication.revoke",
  "system.quota_policy.change",
  "system.stripe.reconcile",
  "system.audit.write",
  "system.break_glass",
  "system.kill_switch.mutate",
] as const;

export type AuthorizationAction = (typeof AUTHORIZATION_ACTIONS)[number];

export interface RolePermission {
  readonly allowed: boolean;
  readonly requiresRecentAuthentication: boolean;
  readonly requiresEditorPublishingAllowed: boolean;
}

const DENY = Object.freeze<RolePermission>({
  allowed: false,
  requiresRecentAuthentication: false,
  requiresEditorPublishingAllowed: false,
});
const ALLOW = Object.freeze<RolePermission>({
  allowed: true,
  requiresRecentAuthentication: false,
  requiresEditorPublishingAllowed: false,
});
const RECENT = Object.freeze<RolePermission>({
  allowed: true,
  requiresRecentAuthentication: true,
  requiresEditorPublishingAllowed: false,
});
const RECENT_EDITOR_PUBLISHING = Object.freeze<RolePermission>({
  allowed: true,
  requiresRecentAuthentication: true,
  requiresEditorPublishingAllowed: true,
});

type PermissionRow = Readonly<Record<WorkspaceRole, RolePermission>>;

function row(
  owner: RolePermission,
  admin: RolePermission,
  editor: RolePermission,
  viewer: RolePermission,
): PermissionRow {
  return Object.freeze({ owner, admin, editor, viewer });
}

const ALL_READ = row(ALLOW, ALLOW, ALLOW, ALLOW);
const OWNER_ADMIN = row(ALLOW, ALLOW, DENY, DENY);
const OWNER_RECENT = row(RECENT, DENY, DENY, DENY);
const OWNER_ADMIN_RECENT = row(RECENT, RECENT, DENY, DENY);
const OWNER_ADMIN_EDITOR = row(ALLOW, ALLOW, ALLOW, DENY);
const OWNER_ADMIN_PROJECT = row(ALLOW, ALLOW, DENY, DENY);
const PUBLICATION_MUTATION = row(RECENT, RECENT, RECENT_EDITOR_PUBLISHING, DENY);
const SYSTEM_ONLY = row(DENY, DENY, DENY, DENY);

export const ROLE_ACTION_MATRIX = Object.freeze({
  "workspace.read": ALL_READ,
  "member.read": ALL_READ,
  "project.read": ALL_READ,
  "private.download": ALL_READ,
  "quota.warning.read": ALL_READ,
  "workspace.profile.update": OWNER_ADMIN,
  "security.read": OWNER_ADMIN,
  "access_history.read": OWNER_ADMIN,
  "audit.read": OWNER_ADMIN,
  "audit.export": OWNER_RECENT,
  "workspace.security.change": OWNER_RECENT,
  "ownership.transfer": OWNER_RECENT,
  "workspace.permanent_delete": OWNER_RECENT,
  "member.invite.viewer": OWNER_ADMIN_RECENT,
  "member.revoke.viewer": OWNER_ADMIN_RECENT,
  "member.change.viewer": OWNER_ADMIN_RECENT,
  "member.remove.viewer": OWNER_ADMIN_RECENT,
  "member.invite.editor": OWNER_ADMIN_RECENT,
  "member.revoke.editor": OWNER_ADMIN_RECENT,
  "member.change.editor": OWNER_ADMIN_RECENT,
  "member.remove.editor": OWNER_ADMIN_RECENT,
  "member.invite.admin": OWNER_RECENT,
  "member.change.admin": OWNER_RECENT,
  "member.remove.admin": OWNER_RECENT,
  "member.add.owner": OWNER_RECENT,
  "member.change.owner": OWNER_RECENT,
  "member.remove.owner": OWNER_RECENT,
  "subscription.read": OWNER_ADMIN,
  "usage.read": OWNER_ADMIN,
  "limit.read": OWNER_ADMIN,
  "subscription.manage": OWNER_RECENT,
  "billing.manage": OWNER_RECENT,
  "project.create": OWNER_ADMIN_EDITOR,
  "project.revise": OWNER_ADMIN_EDITOR,
  "concept.import": OWNER_ADMIN_EDITOR,
  "concept.edit": OWNER_ADMIN_EDITOR,
  "concept.archive": OWNER_ADMIN_EDITOR,
  "comment.create": OWNER_ADMIN_EDITOR,
  "concept.approve": OWNER_ADMIN_EDITOR,
  "project.archive": OWNER_ADMIN_PROJECT,
  "project.restore": OWNER_ADMIN_PROJECT,
  "project.permanent_delete": OWNER_RECENT,
  "raw_archive.configure": OWNER_RECENT,
  "raw_archive.allocate": OWNER_ADMIN_EDITOR,
  "publication.record.read": ALL_READ,
  "publication.policy.change": OWNER_ADMIN_RECENT,
  "publication.create": PUBLICATION_MUTATION,
  "publication.update": PUBLICATION_MUTATION,
  "publication.revoke": PUBLICATION_MUTATION,
  "system.quota_policy.change": SYSTEM_ONLY,
  "system.stripe.reconcile": SYSTEM_ONLY,
  "system.audit.write": SYSTEM_ONLY,
  "system.break_glass": SYSTEM_ONLY,
  "system.kill_switch.mutate": SYSTEM_ONLY,
} satisfies Readonly<Record<AuthorizationAction, PermissionRow>>);

export const SYSTEM_ONLY_ACTIONS = [
  "system.quota_policy.change",
  "system.stripe.reconcile",
  "system.audit.write",
  "system.break_glass",
  "system.kill_switch.mutate",
] as const satisfies readonly AuthorizationAction[];

export const RESOURCE_SCOPED_ACTIONS = [
  "member.read",
  "project.read",
  "private.download",
  "project.revise",
  "concept.import",
  "concept.edit",
  "concept.archive",
  "comment.create",
  "concept.approve",
  "project.archive",
  "project.restore",
  "project.permanent_delete",
  "raw_archive.configure",
  "raw_archive.allocate",
  "publication.record.read",
  "publication.policy.change",
  "publication.create",
  "publication.update",
  "publication.revoke",
] as const satisfies readonly AuthorizationAction[];

export const HOSTED_MUTATION_ACTIONS = [
  "workspace.profile.update",
  "workspace.security.change",
  "ownership.transfer",
  "workspace.permanent_delete",
  "member.invite.viewer",
  "member.revoke.viewer",
  "member.change.viewer",
  "member.remove.viewer",
  "member.invite.editor",
  "member.revoke.editor",
  "member.change.editor",
  "member.remove.editor",
  "member.invite.admin",
  "member.change.admin",
  "member.remove.admin",
  "member.add.owner",
  "member.change.owner",
  "member.remove.owner",
  "subscription.manage",
  "billing.manage",
  "project.create",
  "project.revise",
  "concept.import",
  "concept.edit",
  "concept.archive",
  "comment.create",
  "concept.approve",
  "project.archive",
  "project.restore",
  "project.permanent_delete",
  "raw_archive.configure",
  "raw_archive.allocate",
  "publication.policy.change",
  "publication.create",
  "publication.update",
  "publication.revoke",
] as const satisfies readonly AuthorizationAction[];

export const PUBLICATION_ACTIONS = [
  "publication.record.read",
  "publication.policy.change",
  "publication.create",
  "publication.update",
  "publication.revoke",
] as const satisfies readonly AuthorizationAction[];

const actionSet = new Set<string>(AUTHORIZATION_ACTIONS);
const roleSet = new Set<string>(WORKSPACE_ROLES);
const resourceActionSet = new Set<string>(RESOURCE_SCOPED_ACTIONS);
const hostedMutationActionSet = new Set<string>(HOSTED_MUTATION_ACTIONS);
const publicationActionSet = new Set<string>(PUBLICATION_ACTIONS);

export function permissionFor(role: unknown, action: unknown): RolePermission {
  if (typeof role !== "string" || !roleSet.has(role)) return DENY;
  if (typeof action !== "string" || !actionSet.has(action)) return DENY;
  return ROLE_ACTION_MATRIX[action as AuthorizationAction][role as WorkspaceRole];
}

export function requiresResourceTenant(action: unknown): boolean {
  return typeof action === "string" && resourceActionSet.has(action);
}

export function isHostedMutationAction(action: unknown): boolean {
  return typeof action === "string" && hostedMutationActionSet.has(action);
}

export function isPublicationAction(action: unknown): boolean {
  return typeof action === "string" && publicationActionSet.has(action);
}
