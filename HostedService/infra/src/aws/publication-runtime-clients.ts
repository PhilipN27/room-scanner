import type { PublicationFeedbackDeliveryProviderPort } from "roomscan-studio-hosted-service/persistence";
import type {
  PublicationFeedbackDeliveryWakePort,
  PublicationValidationWakePort,
} from "roomscan-studio-hosted-service/publication";

import {
  AwsRuntimeConfigurationError,
  AwsSqsWakePort,
  type SesV2Port,
} from "./runtime-clients.js";

/** Fixed targetless publication-validation wake. No allocation, project,
 * object key, or tenant coordinate is representable in its API. */
export class AwsPublicationValidationWakePort implements PublicationValidationWakePort {
  readonly #wake: AwsSqsWakePort;
  constructor(input: Readonly<{ readonly wake: AwsSqsWakePort }>) {
    if (!(input?.wake instanceof AwsSqsWakePort)) throw invalid();
    this.#wake = input.wake;
  }
  async notifyPublicationValidationWake(): Promise<void> { await this.#wake.notify(); }
}

/** Fixed targetless feedback-delivery wake. Recipient and code remain solely
 * in the encrypted database outbox claimed by the email runtime. */
export class AwsPublicationFeedbackWakePort implements PublicationFeedbackDeliveryWakePort {
  readonly #wake: AwsSqsWakePort;
  constructor(input: Readonly<{ readonly wake: AwsSqsWakePort }>) {
    if (!(input?.wake instanceof AwsSqsWakePort)) throw invalid();
    this.#wake = input.wake;
  }
  async notifyFeedbackDeliveryWake(): Promise<void> { await this.#wake.notify(); }
}

/** Fixed SES template boundary for verified accountless feedback. The
 * provider sees a destination and one short-lived code only after the worker
 * repeats its live revocation/expiry/kill-switch database check. */
export class AwsPublicationFeedbackDeliveryProviderPort implements PublicationFeedbackDeliveryProviderPort {
  constructor(private readonly input: Readonly<{
    readonly ses: SesV2Port;
    readonly fromEmailAddress: string;
    readonly identityArn: string;
    readonly configurationSetName: string;
    readonly templateName: string;
  }>) {
    if (input === null || typeof input !== "object" || input.ses === null || typeof input.ses.send !== "function"
      || !email(input.fromEmailAddress) || !/^arn:aws:ses:us-east-1:\d{12}:identity\/.{1,256}$/u.test(input.identityArn)
      || !identifier(input.configurationSetName, 64) || !identifier(input.templateName, 128)) throw invalid();
  }

  async send(value: Readonly<{ readonly email: string; readonly verificationCode: string; readonly deliveryID: string }>): Promise<void> {
    if (!email(value?.email) || !verificationCode(value.verificationCode) || !/^pfd_[A-Za-z0-9_-]{16,128}$/u.test(value.deliveryID)) throw invalid();
    await this.input.ses.send({
      fromEmailAddress: this.input.fromEmailAddress,
      fromEmailAddressIdentityArn: this.input.identityArn,
      configurationSetName: this.input.configurationSetName,
      destination: [value.email],
      templateName: this.input.templateName,
      templateData: JSON.stringify({ verificationCode: value.verificationCode }),
      tags: [
        { name: "purpose", value: "publication_feedback_verification" },
        { name: "delivery", value: value.deliveryID },
      ],
    });
  }
}

function email(value: unknown): value is string {
  return typeof value === "string" && value.length >= 3 && value.length <= 320
    && !/[\u0000-\u001f\u007f-\u009f]/u.test(value) && /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value);
}

function identifier(value: unknown, maximum: number): value is string {
  return typeof value === "string" && value.length >= 1 && value.length <= maximum
    && /^[A-Za-z0-9_-]+$/u.test(value);
}

function verificationCode(value: unknown): value is string {
  if (typeof value !== "string") return false;
  const match = /^([A-Za-z0-9_-]{43})\.([A-Za-z0-9_-]{43})$/u.exec(value);
  return match?.[1] !== undefined && match[2] !== undefined
    && Buffer.from(match[1], "base64url").byteLength === 32
    && Buffer.from(match[2], "base64url").byteLength === 32;
}

function invalid(): AwsRuntimeConfigurationError {
  return new AwsRuntimeConfigurationError("ses_request_invalid");
}
