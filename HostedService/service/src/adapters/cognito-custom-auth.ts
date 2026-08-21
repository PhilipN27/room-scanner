export interface CognitoChallengeSessionEntry { readonly challengeName?: string; readonly challengeResult?: boolean; readonly challengeMetadata?: string; }
interface CognitoBaseRequest { readonly userNotFound?: boolean; readonly session?: readonly CognitoChallengeSessionEntry[]; readonly userAttributes?: Readonly<Record<string, string>>; }
export interface DefineAuthChallengeEvent { readonly triggerSource: "DefineAuthChallenge_Authentication"; readonly request: CognitoBaseRequest; response: { challengeName?: "CUSTOM_CHALLENGE"; issueTokens: boolean; failAuthentication: boolean }; }
export interface CreateAuthChallengeEvent { readonly triggerSource: "CreateAuthChallenge_Authentication"; readonly request: CognitoBaseRequest & { readonly challengeName: "CUSTOM_CHALLENGE" }; response: { publicChallengeParameters?: Readonly<Record<string, string>>; privateChallengeParameters?: Readonly<Record<string, string>>; challengeMetadata?: string }; }
export interface VerifyAuthChallengeEvent { readonly triggerSource: "VerifyAuthChallengeResponse_Authentication"; readonly request: CognitoBaseRequest & { readonly privateChallengeParameters: Readonly<Record<string, string>>; readonly challengeAnswer?: string }; response: { answerCorrect: boolean }; }
export interface BoundCustomChallenge { readonly attemptId: string; readonly purpose: "sign-in" | "link-identity" | "unlink-identity" | "reauthenticate"; readonly selector: string; readonly proof: string; readonly synthetic: boolean; }
export interface CustomChallengePort { createKnown(): Promise<BoundCustomChallenge>; createSyntheticWithoutDelivery(): Promise<BoundCustomChallenge>; verify(input: { readonly attemptId: string; readonly purpose: BoundCustomChallenge["purpose"]; readonly selector: string; readonly proof: string; readonly answer: string; readonly synthetic: boolean }): Promise<boolean>; }

export class CognitoCustomChallengeAdapter {
  constructor(private readonly challenges: CustomChallengePort) {}
  define(event: DefineAuthChallengeEvent): DefineAuthChallengeEvent {
    const session = event.request.session ?? [];
    const passed = session.at(-1)?.challengeName === "CUSTOM_CHALLENGE" && session.at(-1)?.challengeResult === true;
    const failures = session.filter((item) => item.challengeName === "CUSTOM_CHALLENGE" && item.challengeResult !== true).length;
    event.response.issueTokens = passed;
    event.response.failAuthentication = !passed && failures >= 3;
    if (!passed && failures < 3) event.response.challengeName = "CUSTOM_CHALLENGE";
    return event;
  }
  async create(event: CreateAuthChallengeEvent): Promise<CreateAuthChallengeEvent> {
    const challenge = event.request.userNotFound === true ? await this.challenges.createSyntheticWithoutDelivery() : await this.challenges.createKnown();
    event.response.publicChallengeParameters = { selector: challenge.selector };
    event.response.privateChallengeParameters = { attemptId: challenge.attemptId, purpose: challenge.purpose, selector: challenge.selector, proof: challenge.proof, synthetic: challenge.synthetic ? "true" : "false" };
    event.response.challengeMetadata = `ROOMSCAN_CUSTOM_V1:${challenge.attemptId}`;
    return event;
  }
  async verify(event: VerifyAuthChallengeEvent): Promise<VerifyAuthChallengeEvent> {
    const p = event.request.privateChallengeParameters;
    let correct = false;
    if (validPurpose(p.purpose) && bounded(p.attemptId) && bounded(p.selector) && bounded(p.proof) && bounded(event.request.challengeAnswer)) {
      try { correct = await this.challenges.verify({ attemptId: p.attemptId, purpose: p.purpose, selector: p.selector, proof: p.proof, answer: event.request.challengeAnswer, synthetic: p.synthetic === "true" }); } catch { correct = false; }
    }
    event.response.answerCorrect = correct;
    return event;
  }
}

export interface CognitoAppleSessionChallenge {
  readonly kind: "roomscan-apple-session-v1";
  readonly attemptId: string;
  readonly purpose: "sign-in";
  readonly bridgeProof: string;
  readonly familyPublicId: string;
  readonly accessTokenHash: string;
  readonly refreshTokenHash: string;
  readonly authenticatedAt: string;
  readonly issuedAt: string;
  readonly accessExpiresAt: string;
  readonly inactivityExpiresAt: string;
  readonly absoluteExpiresAt: string;
  readonly policyVersion: string;
}
export interface CognitoAdminPort {
  /** API-side provider initiation only. Implementations carry `challenge`
   * through the server-side custom-auth exchange and reduce any provider
   * response to this boolean outcome. Cognito tokens must not cross this port. */
  adminAuthenticate(input: { readonly issuer: string; readonly subject: string; readonly attemptId: string; readonly purpose: "sign-in"; readonly challenge: CognitoAppleSessionChallenge }): Promise<{ readonly outcome: "authenticated" }>;
  adminLink(input: { readonly sourceIssuer: string; readonly sourceSubject: string; readonly destinationPrincipalId: string; readonly attemptId: string; readonly purpose: "link-identity" }): Promise<void>;
}
export interface AppOwnedSessionMaterial {
  readonly familyPublicId: string;
  readonly accessToken: string;
  readonly accessTokenHash: Uint8Array;
  readonly refreshToken: string;
  readonly refreshTokenHash: Uint8Array;
  readonly authenticatedAt: Date;
  readonly issuedAt: Date;
  readonly accessExpiresAt: Date;
  readonly inactivityExpiresAt: Date;
  readonly absoluteExpiresAt: Date;
  readonly policyVersion: string;
}
export interface AppOwnedSessionMaterialPort { mint(): Promise<AppOwnedSessionMaterial>; }
export interface AppleBridgeSessionIssuancePort {
  consumeAppleBridgeAndIssueSession(input: {
    readonly bridgeProof: string;
    readonly familyPublicId: string;
    readonly accessTokenHash: Uint8Array;
    readonly refreshTokenHash: Uint8Array;
    readonly authenticatedAt: Date;
    readonly issuedAt: Date;
    readonly accessExpiresAt: Date;
    readonly inactivityExpiresAt: Date;
    readonly absoluteExpiresAt: Date;
    readonly policyVersion: string;
  }): Promise<
    | { readonly status: "issued"; readonly principalInternalId: string; readonly principalCanonicalId: string; readonly familyInternalId: string; readonly familyPublicId: string; readonly authenticationEpoch: number; readonly authenticatedAt: string }
    | { readonly status: "unavailable" | "professional_sign_in_disabled" }
  >;
}
export interface IssuedAppSessionResolverPort {
  resolveIssuedAccess(input: { readonly accessTokenHash: Uint8Array; readonly authoritativeNow: Date }): Promise<{ readonly principalCanonicalId: string; readonly familyPublicId: string } | undefined>;
}
export interface AppOwnedLinkAuthorizationPort { confirmAppOwnedLink(input: { readonly issuer: string; readonly subject: string; readonly principalId: string; readonly attemptId: string }): Promise<boolean>; }
export class CognitoBridgeError extends Error { constructor(readonly code: "invalid_bridge_proof" | "invalid_bridge_result" | "link_not_authorized") { super(code); this.name = "CognitoBridgeError"; } }

/** Auth-challenge-Lambda side of the Apple bridge. This is the only service
 * adapter allowed to consume the proof. Its persistence port maps to the
 * atomic `consume_apple_bridge_and_issue_session` capability. */
export class CognitoAuthChallengeBridge {
  constructor(private readonly sessions: AppleBridgeSessionIssuancePort) {}
  async consumeAndIssue(input: CognitoAppleSessionChallenge): Promise<{ readonly principalCanonicalId: string; readonly familyPublicId: string }> {
    const issuance = parseChallenge(input);
    if (issuance === undefined) throw new CognitoBridgeError("invalid_bridge_proof");
    let result: Awaited<ReturnType<AppleBridgeSessionIssuancePort["consumeAppleBridgeAndIssueSession"]>>;
    try { result = await this.sessions.consumeAppleBridgeAndIssueSession(issuance); } catch { throw new CognitoBridgeError("invalid_bridge_proof"); }
    if (result.status !== "issued") throw new CognitoBridgeError("invalid_bridge_proof");
    if (!uuid(result.principalInternalId) || !uuid(result.familyInternalId) || !identifier(result.principalCanonicalId, 1, 128) || !identifier(result.familyPublicId, 16, 128) || result.familyPublicId !== input.familyPublicId || !Number.isSafeInteger(result.authenticationEpoch) || result.authenticationEpoch < 0 || canonicalDate(result.authenticatedAt) === undefined) throw new CognitoBridgeError("invalid_bridge_result");
    return Object.freeze({ principalCanonicalId: result.principalCanonicalId, familyPublicId: result.familyPublicId });
  }
}

export interface AppOwnedIssuedSession {
  readonly principalCanonicalId: string;
  readonly familyPublicId: string;
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly accessExpiresAt: string;
  readonly refreshInactivityExpiresAt: string;
  readonly refreshAbsoluteExpiresAt: string;
}

/** API-side orchestrator. It mints the opaque app session material, asks
 * Cognito to run the challenge Lambda, then resolves its own access hash.
 * It has no proof-consumer capability and never returns Cognito tokens. */
export class CognitoServerBridge {
  constructor(private readonly dependencies: { readonly admin: CognitoAdminPort; readonly sessionMaterials: AppOwnedSessionMaterialPort; readonly issuedSessions: IssuedAppSessionResolverPort; readonly clock: { now(): Date }; readonly linkAuthorization?: AppOwnedLinkAuthorizationPort }) {}
  async authenticate(input: { readonly issuer: string; readonly subject: string; readonly internalProof: string; readonly attemptId: string; readonly purpose: "sign-in" }): Promise<AppOwnedIssuedSession> {
    if (!bounded(input.issuer) || !bounded(input.subject) || !opaque(input.internalProof) || !identifier(input.attemptId, 16, 128) || input.purpose !== "sign-in") throw new CognitoBridgeError("invalid_bridge_proof");
    let material: AppOwnedSessionMaterial;
    try { material = await this.dependencies.sessionMaterials.mint(); } catch { throw new CognitoBridgeError("invalid_bridge_result"); }
    const challenge = challengeFor(input, material);
    if (challenge === undefined) throw new CognitoBridgeError("invalid_bridge_result");
    let adminResult: { readonly outcome: "authenticated" };
    try { adminResult = await this.dependencies.admin.adminAuthenticate({ issuer: input.issuer, subject: input.subject, attemptId: input.attemptId, purpose: input.purpose, challenge }); } catch { throw new CognitoBridgeError("invalid_bridge_proof"); }
    if (adminResult?.outcome !== "authenticated") throw new CognitoBridgeError("invalid_bridge_result");
    const authoritativeNow = this.dependencies.clock.now();
    if (!validDate(authoritativeNow)) throw new CognitoBridgeError("invalid_bridge_result");
    let resolved: Awaited<ReturnType<IssuedAppSessionResolverPort["resolveIssuedAccess"]>>;
    try { resolved = await this.dependencies.issuedSessions.resolveIssuedAccess({ accessTokenHash: Uint8Array.from(material.accessTokenHash), authoritativeNow }); } catch { throw new CognitoBridgeError("invalid_bridge_result"); }
    if (resolved === undefined || !identifier(resolved.principalCanonicalId, 1, 128) || resolved.familyPublicId !== material.familyPublicId) throw new CognitoBridgeError("invalid_bridge_result");
    return Object.freeze({ principalCanonicalId: resolved.principalCanonicalId, familyPublicId: resolved.familyPublicId, accessToken: material.accessToken, refreshToken: material.refreshToken, accessExpiresAt: material.accessExpiresAt.toISOString(), refreshInactivityExpiresAt: material.inactivityExpiresAt.toISOString(), refreshAbsoluteExpiresAt: material.absoluteExpiresAt.toISOString() });
  }
  async link(input: { readonly issuer: string; readonly subject: string; readonly principalId: string; readonly attemptId: string; readonly purpose: "link-identity" }): Promise<void> {
    if (!bounded(input.issuer) || !bounded(input.subject) || !bounded(input.principalId) || !bounded(input.attemptId) || input.purpose !== "link-identity" || this.dependencies.linkAuthorization === undefined || !await this.dependencies.linkAuthorization.confirmAppOwnedLink({ issuer: input.issuer, subject: input.subject, principalId: input.principalId, attemptId: input.attemptId })) throw new CognitoBridgeError("link_not_authorized");
    await this.dependencies.admin.adminLink({ sourceIssuer: input.issuer, sourceSubject: input.subject, destinationPrincipalId: input.principalId, attemptId: input.attemptId, purpose: input.purpose });
  }
}
function bounded(value: unknown): value is string { return typeof value === "string" && value.length >= 1 && value.length <= 512; }
function validPurpose(value: unknown): value is BoundCustomChallenge["purpose"] { return value === "sign-in" || value === "link-identity" || value === "unlink-identity" || value === "reauthenticate"; }
function challengeFor(input: { readonly internalProof: string; readonly attemptId: string; readonly purpose: "sign-in" }, material: AppOwnedSessionMaterial): CognitoAppleSessionChallenge | undefined {
  if (!validMaterial(material)) return undefined;
  return Object.freeze({ kind: "roomscan-apple-session-v1", attemptId: input.attemptId, purpose: input.purpose, bridgeProof: input.internalProof, familyPublicId: material.familyPublicId, accessTokenHash: Buffer.from(material.accessTokenHash).toString("base64url"), refreshTokenHash: Buffer.from(material.refreshTokenHash).toString("base64url"), authenticatedAt: material.authenticatedAt.toISOString(), issuedAt: material.issuedAt.toISOString(), accessExpiresAt: material.accessExpiresAt.toISOString(), inactivityExpiresAt: material.inactivityExpiresAt.toISOString(), absoluteExpiresAt: material.absoluteExpiresAt.toISOString(), policyVersion: material.policyVersion });
}
function parseChallenge(input: CognitoAppleSessionChallenge): Parameters<AppleBridgeSessionIssuancePort["consumeAppleBridgeAndIssueSession"]>[0] | undefined {
  if (input.kind !== "roomscan-apple-session-v1" || input.purpose !== "sign-in" || !identifier(input.attemptId, 16, 128) || !opaque(input.bridgeProof) || !identifier(input.familyPublicId, 16, 128) || !digest(input.accessTokenHash) || !digest(input.refreshTokenHash) || !identifier(input.policyVersion, 1, 64)) return undefined;
  const authenticatedAt = canonicalDate(input.authenticatedAt); const issuedAt = canonicalDate(input.issuedAt); const accessExpiresAt = canonicalDate(input.accessExpiresAt); const inactivityExpiresAt = canonicalDate(input.inactivityExpiresAt); const absoluteExpiresAt = canonicalDate(input.absoluteExpiresAt);
  if (authenticatedAt === undefined || issuedAt === undefined || accessExpiresAt === undefined || inactivityExpiresAt === undefined || absoluteExpiresAt === undefined || authenticatedAt.getTime() > issuedAt.getTime() || issuedAt.getTime() >= accessExpiresAt.getTime() || issuedAt.getTime() >= inactivityExpiresAt.getTime() || inactivityExpiresAt.getTime() > absoluteExpiresAt.getTime()) return undefined;
  return Object.freeze({ bridgeProof: input.bridgeProof, familyPublicId: input.familyPublicId, accessTokenHash: Uint8Array.from(Buffer.from(input.accessTokenHash, "base64url")), refreshTokenHash: Uint8Array.from(Buffer.from(input.refreshTokenHash, "base64url")), authenticatedAt, issuedAt, accessExpiresAt, inactivityExpiresAt, absoluteExpiresAt, policyVersion: input.policyVersion });
}
function validMaterial(value: AppOwnedSessionMaterial): boolean { return identifier(value.familyPublicId, 16, 128) && opaque(value.accessToken) && opaque(value.refreshToken) && value.accessTokenHash.length === 32 && value.refreshTokenHash.length === 32 && validDate(value.authenticatedAt) && validDate(value.issuedAt) && validDate(value.accessExpiresAt) && validDate(value.inactivityExpiresAt) && validDate(value.absoluteExpiresAt) && value.authenticatedAt.getTime() <= value.issuedAt.getTime() && value.issuedAt.getTime() < value.accessExpiresAt.getTime() && value.issuedAt.getTime() < value.inactivityExpiresAt.getTime() && value.inactivityExpiresAt.getTime() <= value.absoluteExpiresAt.getTime() && identifier(value.policyVersion, 1, 64); }
function identifier(value: unknown, minimum: number, maximum: number): value is string { return typeof value === "string" && value.length >= minimum && value.length <= maximum && /^[A-Za-z0-9_-]+$/u.test(value); }
function opaque(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/u.test(value); }
function digest(value: unknown): value is string { return opaque(value) && Buffer.from(value, "base64url").length === 32 && Buffer.from(Buffer.from(value, "base64url")).toString("base64url") === value; }
function validDate(value: unknown): value is Date { return value instanceof Date && Number.isFinite(value.getTime()); }
function canonicalDate(value: unknown): Date | undefined { if (typeof value !== "string") return undefined; const date = new Date(value); return validDate(date) && date.toISOString() === value ? date : undefined; }
function uuid(value: unknown): value is string { return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value); }
