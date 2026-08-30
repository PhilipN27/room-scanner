import { SendMessageCommand } from "@aws-sdk/client-sqs";

import type { AwsCommandSender } from "./runtime-clients.js";

export const PROJECT_SYNC_VALIDATION_WAKE_BODY = "roomscan-project-validation-wake-v1" as const;

/** A targetless wake is deliberately not a work-item protocol. PostgreSQL
 * remains authoritative for selection, leases, retry, and finalization. */
export class AwsProjectSyncValidationWakePort {
  readonly #sender: AwsCommandSender;
  readonly #queueUrl: string;

  constructor(input: Readonly<{ readonly sender: AwsCommandSender; readonly queueUrl: string }>) {
    if (!sender(input?.sender) || !queueUrl(input.queueUrl)) {
      throw new ProjectSyncValidationWakeError("project_sync_validation_wake_invalid_configuration");
    }
    this.#sender = input.sender;
    this.#queueUrl = input.queueUrl;
  }

  async notifyValidationWake(): Promise<void> {
    const response = await this.#sender.send(new SendMessageCommand({
      QueueUrl: this.#queueUrl,
      MessageBody: PROJECT_SYNC_VALIDATION_WAKE_BODY,
    }));
    const messageId = response !== null && typeof response === "object"
      ? (response as Readonly<{ readonly MessageId?: unknown }>).MessageId
      : undefined;
    if (typeof messageId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/u.test(messageId)) {
      throw new ProjectSyncValidationWakeError("project_sync_validation_wake_invalid_response");
    }
  }
}

export class ProjectSyncValidationWakeError extends Error {
  constructor(readonly code: "project_sync_validation_wake_invalid_configuration" | "project_sync_validation_wake_invalid_response") {
    super(code);
    this.name = "ProjectSyncValidationWakeError";
  }
}

function sender(value: unknown): value is AwsCommandSender {
  return value !== null && typeof value === "object" && typeof (value as AwsCommandSender).send === "function";
}

function queueUrl(value: unknown): value is string {
  return typeof value === "string"
    && /^https:\/\/sqs\.us-east-1\.amazonaws\.com\/\d{12}\/roomscan-(?:dev|staging|production)-project-sync-validation$/u.test(value);
}
