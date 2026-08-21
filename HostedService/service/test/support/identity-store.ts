import type {
  CandidateIdentityProof,
  CandidateProofClaim,
  ExternalIdentityRecord,
  IdentityAuditEvent,
  IdentityStore,
  IdentityTransaction,
  PrincipalRecord,
  SecurityNotificationOutboxRecord,
  VerifiedAuthenticationReceipt,
  VerifiedAuthenticationReceiptClaim,
} from "../../identity-linking.js";

export class FlowIdentityStore implements IdentityStore, IdentityTransaction {
  readonly principals: PrincipalRecord[] = [];
  readonly identities: ExternalIdentityRecord[] = [];
  readonly proofs: CandidateIdentityProof[] = [];
  readonly revokedFamilies: Array<{ principalId: string; exceptFamilyId: string }> = [];
  readonly auditEvents: IdentityAuditEvent[] = [];
  readonly notificationOutbox: SecurityNotificationOutboxRecord[] = [];
  private tail: Promise<void> = Promise.resolve();

  constructor(
    readonly verifiedAuthenticationReceipts: VerifiedAuthenticationReceipt[] = [],
  ) {}

  async transaction<T>(work: (transaction: IdentityTransaction) => Promise<T>): Promise<T> {
    const previous = this.tail;
    let release = (): void => undefined;
    this.tail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    const snapshot = structuredClone({
      principals: this.principals,
      identities: this.identities,
      proofs: this.proofs,
      verifiedAuthenticationReceipts: this.verifiedAuthenticationReceipts,
      revokedFamilies: this.revokedFamilies,
      auditEvents: this.auditEvents,
      notificationOutbox: this.notificationOutbox,
    });
    try {
      return await work(this);
    } catch (error) {
      this.principals.splice(0, this.principals.length, ...snapshot.principals);
      this.identities.splice(0, this.identities.length, ...snapshot.identities);
      this.proofs.splice(0, this.proofs.length, ...snapshot.proofs);
      this.verifiedAuthenticationReceipts.splice(
        0,
        this.verifiedAuthenticationReceipts.length,
        ...snapshot.verifiedAuthenticationReceipts,
      );
      this.revokedFamilies.splice(0, this.revokedFamilies.length, ...snapshot.revokedFamilies);
      this.auditEvents.splice(0, this.auditEvents.length, ...snapshot.auditEvents);
      this.notificationOutbox.splice(0, this.notificationOutbox.length, ...snapshot.notificationOutbox);
      throw error;
    } finally {
      release();
    }
  }

  async findPrincipal(principalId: string): Promise<PrincipalRecord | undefined> {
    return this.principals.find((principal) => principal.id === principalId);
  }

  async insertPrincipal(principal: PrincipalRecord): Promise<void> { this.principals.push(structuredClone(principal)); }

  async findIdentity(issuer: string, subject: string): Promise<ExternalIdentityRecord | undefined> {
    return this.identities.find((identity) => identity.issuer === issuer && identity.subject === subject);
  }

  async identitiesForPrincipal(principalId: string): Promise<ExternalIdentityRecord[]> {
    return this.identities.filter((identity) => identity.principalId === principalId);
  }

  async insertIdentity(identity: ExternalIdentityRecord): Promise<void> {
    if (await this.findIdentity(identity.issuer, identity.subject) !== undefined) throw new Error("identity already owned");
    this.identities.push(structuredClone(identity));
  }

  async removeIdentity(issuer: string, subject: string): Promise<void> {
    const index = this.identities.findIndex((identity) => identity.issuer === issuer && identity.subject === subject);
    if (index >= 0) this.identities.splice(index, 1);
  }

  async insertCandidateProof(proof: CandidateIdentityProof): Promise<void> { this.proofs.push(structuredClone(proof)); }

  async insertVerifiedAuthenticationReceipt(
    receipt: VerifiedAuthenticationReceipt,
  ): Promise<void> {
    this.verifiedAuthenticationReceipts.push(structuredClone(receipt));
  }

  async claimVerifiedAuthenticationReceipt(
    claim: VerifiedAuthenticationReceiptClaim,
  ): Promise<VerifiedAuthenticationReceipt | undefined> {
    const receipt = this.verifiedAuthenticationReceipts.find((candidate) =>
      candidate.tokenHash === claim.tokenHash &&
      candidate.state === "active" &&
      candidate.issuer === claim.expectedIssuer &&
      candidate.purpose === claim.expectedPurpose &&
      candidate.initiatingPrincipalId === claim.initiatingPrincipalId &&
      candidate.initiatingFamilyId === claim.initiatingFamilyId &&
      candidate.expiresAtMs > claim.nowMs,
    );
    if (receipt === undefined) return undefined;
    receipt.state = "consumed";
    receipt.consumedAtMs = claim.nowMs;
    return structuredClone(receipt);
  }

  async claimCandidateProof(claim: CandidateProofClaim): Promise<CandidateIdentityProof | undefined> {
    const proof = this.proofs.find((candidate) =>
      candidate.tokenHash === claim.tokenHash &&
      candidate.state === "active" &&
      candidate.purpose === claim.purpose &&
      candidate.initiatingPrincipalId === claim.initiatingPrincipalId &&
      candidate.initiatingFamilyId === claim.initiatingFamilyId &&
      candidate.expiresAtMs > claim.nowMs,
    );
    if (proof === undefined) return undefined;
    proof.state = "consumed";
    proof.consumedAtMs = claim.nowMs;
    return structuredClone(proof);
  }

  async bumpAuthenticationEpoch(principalId: string): Promise<number> {
    const principal = await this.findPrincipal(principalId);
    if (principal === undefined) throw new Error("principal missing");
    principal.authenticationEpoch += 1;
    return principal.authenticationEpoch;
  }

  async revokeOtherSessionFamilies(principalId: string, exceptFamilyId: string): Promise<void> {
    this.revokedFamilies.push({ principalId, exceptFamilyId });
  }

  async insertAuditEvent(event: IdentityAuditEvent): Promise<void> { this.auditEvents.push(structuredClone(event)); }
  async insertSecurityNotification(record: SecurityNotificationOutboxRecord): Promise<void> { this.notificationOutbox.push(structuredClone(record)); }
  async availableSecurityNotifications(nowMs: number, limit: number): Promise<SecurityNotificationOutboxRecord[]> {
    return this.notificationOutbox
      .filter((record) =>
        record.state === "pending" ||
        (record.state === "leased" && (record.leaseExpiresAtMs ?? 0) <= nowMs),
      )
      .slice(0, limit)
      .map((record) => structuredClone(record));
  }
  async claimSecurityNotificationLease(
    id: string,
    leaseId: string,
    nowMs: number,
    leaseExpiresAtMs: number,
  ): Promise<SecurityNotificationOutboxRecord | undefined> {
    const record = this.notificationOutbox.find((candidate) =>
      candidate.id === id &&
      (candidate.state === "pending" ||
        (candidate.state === "leased" && (candidate.leaseExpiresAtMs ?? 0) <= nowMs)),
    );
    if (record === undefined) return undefined;
    record.state = "leased";
    record.leaseId = leaseId;
    record.leaseExpiresAtMs = leaseExpiresAtMs;
    record.deliveryAttempts += 1;
    return structuredClone(record);
  }
  async completeSecurityNotificationLease(id: string, leaseId: string, deliveredAtMs: number): Promise<boolean> {
    const record = this.notificationOutbox.find((candidate) =>
      candidate.id === id && candidate.state === "leased" && candidate.leaseId === leaseId,
    );
    if (record === undefined) return false;
    record.state = "delivered";
    record.deliveredAtMs = deliveredAtMs;
    delete record.leaseId;
    delete record.leaseExpiresAtMs;
    return true;
  }
  async releaseSecurityNotificationLease(id: string, leaseId: string): Promise<boolean> {
    const record = this.notificationOutbox.find((candidate) =>
      candidate.id === id && candidate.state === "leased" && candidate.leaseId === leaseId,
    );
    if (record === undefined) return false;
    record.state = "pending";
    delete record.leaseId;
    delete record.leaseExpiresAtMs;
    return true;
  }
}

export function seedFlowPrincipal(
  store: FlowIdentityStore,
  nowMs: number,
  identities: ReadonlyArray<{ readonly issuer: string; readonly subject: string }>,
): void {
  store.principals.push({ id: "principal-a", authenticationEpoch: 0, createdAtMs: nowMs });
  for (const identity of identities) {
    store.identities.push({ ...identity, principalId: "principal-a", linkedAtMs: nowMs });
  }
}
