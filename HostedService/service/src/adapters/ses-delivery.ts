export interface SesV2Port { send(input: { readonly fromEmailAddress: string; readonly fromEmailAddressIdentityArn: string; readonly configurationSetName: string; readonly destination: readonly string[]; readonly templateName: string; readonly templateData: string; readonly tags: readonly { name: string; value: string }[] }): Promise<void>; }
export interface AuditOutboxLeaseRecord { readonly id: string; readonly idempotencyKey: string; readonly action: "email.delivery"; readonly result: "pending" | "accepted" | "failed"; readonly leaseId?: string; }
/** Lifecycle seam only. A persistent implementation remains blocked on the
 * versioned audit-outbox migration; this interface does not claim durability. */
export interface AuditOutboxLeasePort {
  accept(input: { readonly idempotencyKey: string; readonly action: "email.delivery" }): Promise<void>;
  claim(input: { readonly idempotencyKey: string; readonly leaseId: string; readonly nowMs: number; readonly leaseExpiresAtMs: number }): Promise<AuditOutboxLeaseRecord | undefined>;
  complete(input: { readonly idempotencyKey: string; readonly leaseId: string; readonly result: "accepted"; readonly completedAtMs: number }): Promise<boolean>;
  release(input: { readonly idempotencyKey: string; readonly leaseId: string; readonly failedAtMs: number }): Promise<boolean>;
}
export class SesDeliveryAdapter {
  constructor(private readonly d: { readonly client: SesV2Port; readonly fromEmailAddress: string; readonly fromEmailAddressIdentityArn: string; readonly configurationSetName: string; readonly auditOutbox: AuditOutboxLeasePort; readonly clock: { nowMs(): number }; readonly random: { bytes(length: number): Uint8Array }; readonly leaseMs: number }) { if (!email(d.fromEmailAddress) || !/^arn:aws[a-z-]*:ses:[a-z0-9-]+:\d{12}:identity\/.{1,256}$/.test(d.fromEmailAddressIdentityArn) || !token(d.configurationSetName, 64) || !Number.isSafeInteger(d.leaseMs) || d.leaseMs <= 0) throw new Error("delivery_configuration_invalid"); }
  async send(input: { readonly destination: string; readonly templateName: string; readonly templateData: Readonly<Record<string, string>>; readonly idempotencyKey: string; readonly purpose: "magic_link" | "security_notice" }): Promise<void> {
    const encoded = JSON.stringify(input.templateData); if (!email(input.destination) || !token(input.templateName, 128) || !token(input.idempotencyKey, 128) || encoded.length > 8_192 || Object.entries(input.templateData).length > 16 || Object.entries(input.templateData).some(([key, value]) => !token(key, 64) || value.length > 2_048)) throw new Error("delivery_rejected");
    await this.d.auditOutbox.accept({ idempotencyKey: input.idempotencyKey, action: "email.delivery" });
    const nowMs = this.d.clock.nowMs(); const leaseId = Buffer.from(this.d.random.bytes(16)).toString("base64url");
    const claim = await this.d.auditOutbox.claim({ idempotencyKey: input.idempotencyKey, leaseId, nowMs, leaseExpiresAtMs: nowMs + this.d.leaseMs });
    if (claim === undefined) throw new Error("delivery_unavailable");
    try {
      await this.d.client.send({ fromEmailAddress: this.d.fromEmailAddress, fromEmailAddressIdentityArn: this.d.fromEmailAddressIdentityArn, configurationSetName: this.d.configurationSetName, destination: [input.destination], templateName: input.templateName, templateData: encoded, tags: [{ name: "purpose", value: input.purpose }, { name: "idempotency", value: input.idempotencyKey }] });
      if (!await this.d.auditOutbox.complete({ idempotencyKey: input.idempotencyKey, leaseId, result: "accepted", completedAtMs: this.d.clock.nowMs() })) throw new Error("audit_completion_failed");
    } catch (error) { await this.d.auditOutbox.release({ idempotencyKey: input.idempotencyKey, leaseId, failedAtMs: this.d.clock.nowMs() }).catch(() => false); throw error; }
  }
}
function email(value: string): boolean { return /^[^\s@]{1,128}@[^\s@]{1,253}$/.test(value); }
function token(value: string, max: number): boolean { return value.length <= max && /^[A-Za-z0-9._:-]+$/.test(value); }
