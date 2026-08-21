/** Provider-neutral transport contracts. Values which cross this boundary are
 * deliberately small so vendor SDK types cannot escape into service policy. */
export interface HttpTransport {
  request(input: {
    readonly url: string;
    readonly method: "POST";
    readonly headers: Readonly<Record<string, string>>;
    readonly body: Uint8Array;
    readonly timeoutMs: number;
    readonly maxResponseBytes: number;
    readonly followRedirects: false;
  }): Promise<{ readonly status: number; readonly headers: Readonly<Record<string, string>>; readonly body: Uint8Array }>;
}

export interface SecretValuePort { read(name: string): Promise<string>; }
export interface RandomPort { bytes(length: number): Uint8Array; }

export interface AuditEnvelope {
  readonly action: string;
  readonly result: "accepted" | "rejected" | "failed";
  readonly principalId?: string;
  readonly workspaceId?: string;
  readonly requestId?: string;
}

export interface AllowlistAuditPort { write(event: AuditEnvelope): void; }
