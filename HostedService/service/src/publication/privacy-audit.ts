import { PrivacyLogger, type RandomSource, type StructuredLogSink } from "../../privacy-logger.js";

/** Slice 6 deliberately owns a separate, tiny audit vocabulary. It cannot
 * widen the frozen Slice 4/5 allowlists, and its event type cannot carry a
 * bearer, PIN, email, comment, archive/object identity, or free-form text. */
export type PublicationAuditAction =
  | "publication.snapshot.complete"
  | "publication.link.create"
  | "publication.link.update"
  | "publication.link.revoke"
  | "publication.portal.exchange"
  | "publication.portal.pin"
  | "publication.portal.snapshot"
  | "publication.portal.asset"
  | "publication.feedback.create";
export type PublicationAuditResult = "accepted" | "rejected" | "delivered" | "unavailable";

export interface PublicationAuditEvent {
  readonly action: PublicationAuditAction;
  readonly result: PublicationAuditResult;
  readonly bytes?: number;
}

export interface PublicationPrivacyAuditPort {
  record(event: PublicationAuditEvent): void;
}

export class PublicationPrivacyAudit implements PublicationPrivacyAuditPort {
  readonly #logger: PrivacyLogger;
  constructor(input: { readonly sink: StructuredLogSink; readonly random: RandomSource; readonly pseudonymHmacKey: Uint8Array; readonly identifierHmacKey: Uint8Array }) {
    if (input === null || typeof input !== "object" || input.sink === null || typeof input.sink.write !== "function" || input.random === null || typeof input.random.bytes !== "function" || !(input.pseudonymHmacKey instanceof Uint8Array) || input.pseudonymHmacKey.byteLength < 32 || !(input.identifierHmacKey instanceof Uint8Array) || input.identifierHmacKey.byteLength < 32) throw new PublicationPrivacyAuditError();
    this.#logger = new PrivacyLogger({
      sink: input.sink,
      random: input.random,
      pseudonymHmacKey: Uint8Array.from(input.pseudonymHmacKey),
      identifierHmacKey: Uint8Array.from(input.identifierHmacKey),
      allowedEventCodes: new Set(PUBLICATION_AUDIT_ACTIONS),
      allowedResults: new Set(PUBLICATION_AUDIT_RESULTS),
    });
  }
  record(event: PublicationAuditEvent): void {
    const raw = event as unknown as Record<string, unknown>;
    if (event === null || typeof event !== "object" || Object.getOwnPropertySymbols(event).length !== 0 || Object.keys(raw).some((key) => key !== "action" && key !== "result" && key !== "bytes") || !PUBLICATION_AUDIT_ACTIONS.has(event.action) || !PUBLICATION_AUDIT_RESULTS.has(event.result) || (event.bytes !== undefined && (!Number.isSafeInteger(event.bytes) || event.bytes < 1 || event.bytes > 4_194_304))) throw new PublicationPrivacyAuditError();
    this.#logger.emit(event.action, {
      result: event.result,
      ...(event.bytes === undefined ? {} : { counters: { delivered_bytes: event.bytes } }),
    });
  }
}

export class PublicationPrivacyAuditError extends Error {
  constructor() { super("unsafe_publication_audit"); this.name = "PublicationPrivacyAuditError"; }
}

const PUBLICATION_AUDIT_ACTIONS = new Set<PublicationAuditAction>([
  "publication.snapshot.complete", "publication.link.create", "publication.link.update", "publication.link.revoke",
  "publication.portal.exchange", "publication.portal.pin", "publication.portal.snapshot", "publication.portal.asset", "publication.feedback.create",
]);
const PUBLICATION_AUDIT_RESULTS = new Set<PublicationAuditResult>(["accepted", "rejected", "delivered", "unavailable"]);
