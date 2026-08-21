import {
  AdminCreateUserCommand,
  AdminGetUserCommand,
  AdminInitiateAuthCommand,
  AdminLinkProviderForUserCommand,
  AdminRespondToAuthChallengeCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import {
  BeginTransactionCommand,
  CommitTransactionCommand,
  ExecuteStatementCommand,
  RollbackTransactionCommand,
  type Field,
  type SqlParameter as AwsSqlParameter,
} from "@aws-sdk/client-rds-data";
import { createHash } from "node:crypto";
import { PutObjectCommand, type S3Client } from "@aws-sdk/client-s3";
import { GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import { SendEmailCommand } from "@aws-sdk/client-sesv2";
import { SendMessageCommand } from "@aws-sdk/client-sqs";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

/** These structural contracts mirror the provider-neutral service ports while
 * keeping the infrastructure package buildable independently. The Lambda
 * composition imports the authoritative service types and TypeScript checks
 * these adapters structurally at that seam. */
export type SqlWireValue =
  | { readonly kind: "blob"; readonly bytes: Uint8Array }
  | { readonly kind: "string"; readonly value: string; readonly typeHint?: "TIMESTAMP" | "UUID" }
  | { readonly kind: "long"; readonly value: number }
  | { readonly kind: "boolean"; readonly value: boolean }
  | { readonly kind: "null" };
export interface SqlParameter { readonly name: string; readonly value: SqlWireValue; }
export type SqlCell = string | number | boolean | Uint8Array | null;
export interface SqlResult { readonly rows: readonly Readonly<Record<string, SqlCell>>[]; }
export interface DataApiClientPort {
  begin(): Promise<{ readonly transactionId: string }>;
  execute(input: { readonly transactionId: string; readonly sql: string; readonly parameters?: readonly SqlParameter[] }): Promise<SqlResult>;
  commit(transactionId: string): Promise<void>;
  rollback(transactionId: string): Promise<void>;
}
export interface SecretValuePort {
  read(name: string): Promise<string>;
}
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
export interface SesV2Port {
  send(input: {
    readonly fromEmailAddress: string;
    readonly fromEmailAddressIdentityArn: string;
    readonly configurationSetName: string;
    readonly destination: readonly string[];
    readonly templateName: string;
    readonly templateData: string;
    readonly tags: readonly { readonly name: string; readonly value: string }[];
  }): Promise<void>;
}
export interface PresignPutPort {
  presignPut(input: {
    readonly key: string;
    readonly contentLength: number;
    readonly checksumSha256: string;
    readonly contentType: string;
    readonly expiresInSeconds: number;
    readonly metadata: Readonly<Record<string, string>>;
    readonly ifNoneMatch: "*";
    readonly encryption: "bucket-default-kms";
  }): Promise<{ readonly url: string; readonly headers: Readonly<Record<string, string>> }>;
}

/** Small injectable seam used only to test the exact AWS command boundary.
 * Production construction passes one role-scoped SDK client per Lambda. */
export interface AwsCommandSender {
  send(command: unknown): Promise<unknown>;
}

export class AwsRuntimeConfigurationError extends Error {
  constructor(readonly code:
    | "data_api_configuration_invalid"
    | "data_api_request_invalid"
    | "data_api_response_invalid"
    | "secret_configuration_invalid"
    | "secret_reference_rejected"
    | "secret_value_invalid"
    | "queue_configuration_invalid"
    | "queue_response_invalid"
    | "ses_request_invalid"
    | "presign_configuration_invalid"
    | "presign_request_invalid"
    | "presign_response_invalid"
    | "cognito_configuration_invalid"
    | "cognito_request_invalid"
    | "cognito_response_invalid"
    | "http_request_rejected"
    | "http_response_too_large") {
    super(code);
    this.name = "AwsRuntimeConfigurationError";
  }
}

/** RDS Data API adapter whose resource ARN, secret ARN, and database are fixed
 * at construction. No method accepts a role, secret, cluster, or database. */
export class AwsDataApiClient implements DataApiClientPort {
  readonly #sender: AwsCommandSender;
  readonly #resourceArn: string;
  readonly #secretArn: string;
  readonly #database: string;

  constructor(input: {
    readonly sender: AwsCommandSender;
    readonly resourceArn: string;
    readonly secretArn: string;
    readonly database: string;
  }) {
    if (!sender(input?.sender)
      || !/^arn:aws:rds:us-east-1:\d{12}:cluster:[A-Za-z0-9-]{1,63}$/u.test(input.resourceArn)
      || !secretArn(input.secretArn)
      || !/^[a-z][a-z0-9_]{0,62}$/u.test(input.database)) {
      throw new AwsRuntimeConfigurationError("data_api_configuration_invalid");
    }
    this.#sender = input.sender;
    this.#resourceArn = input.resourceArn;
    this.#secretArn = input.secretArn;
    this.#database = input.database;
  }

  async begin(): Promise<{ readonly transactionId: string }> {
    const result = await this.#sender.send(new BeginTransactionCommand({
      resourceArn: this.#resourceArn,
      secretArn: this.#secretArn,
      database: this.#database,
    }));
    const transactionId = record(result)?.transactionId;
    if (!transactionIdentifier(transactionId)) {
      throw new AwsRuntimeConfigurationError("data_api_response_invalid");
    }
    return Object.freeze({ transactionId });
  }

  async execute(input: {
    readonly transactionId: string;
    readonly sql: string;
    readonly parameters?: readonly SqlParameter[];
  }): Promise<SqlResult> {
    if (!transactionIdentifier(input?.transactionId)
      || typeof input.sql !== "string"
      || input.sql.length === 0
      || input.sql.length > 65_536
      || (input.parameters !== undefined && (!Array.isArray(input.parameters) || input.parameters.length > 128))) {
      throw new AwsRuntimeConfigurationError("data_api_request_invalid");
    }
    const parameters = input.parameters?.map(toAwsParameter);
    const raw = await this.#sender.send(new ExecuteStatementCommand({
      resourceArn: this.#resourceArn,
      secretArn: this.#secretArn,
      database: this.#database,
      transactionId: input.transactionId,
      sql: input.sql,
      includeResultMetadata: true,
      ...(parameters === undefined ? {} : { parameters }),
    }));
    return decodeSqlResult(raw);
  }

  async commit(transactionId: string): Promise<void> {
    if (!transactionIdentifier(transactionId)) {
      throw new AwsRuntimeConfigurationError("data_api_request_invalid");
    }
    await this.#sender.send(new CommitTransactionCommand({
      resourceArn: this.#resourceArn,
      secretArn: this.#secretArn,
      transactionId,
    }));
  }

  async rollback(transactionId: string): Promise<void> {
    if (!transactionIdentifier(transactionId)) {
      throw new AwsRuntimeConfigurationError("data_api_request_invalid");
    }
    await this.#sender.send(new RollbackTransactionCommand({
      resourceArn: this.#resourceArn,
      secretArn: this.#secretArn,
      transactionId,
    }));
  }
}

/** Exact Secrets Manager JSON-field reader. A service adapter must name the
 * same configured ARN; arbitrary secret lookup and binary fallback are denied. */
export class AwsSecretValuePort implements SecretValuePort {
  readonly #sender: AwsCommandSender;
  readonly #secretArn: string;
  readonly #jsonField: string;

  constructor(input: {
    readonly sender: AwsCommandSender;
    readonly secretArn: string;
    readonly jsonField: string;
  }) {
    if (!sender(input?.sender) || !secretArn(input.secretArn) || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/u.test(input.jsonField)) {
      throw new AwsRuntimeConfigurationError("secret_configuration_invalid");
    }
    this.#sender = input.sender;
    this.#secretArn = input.secretArn;
    this.#jsonField = input.jsonField;
  }

  async read(name: string): Promise<string> {
    if (name !== this.#secretArn) {
      throw new AwsRuntimeConfigurationError("secret_reference_rejected");
    }
    const result = record(await this.#sender.send(new GetSecretValueCommand({
      SecretId: this.#secretArn,
      VersionStage: "AWSCURRENT",
    })));
    if (typeof result?.SecretString !== "string" || result.SecretBinary !== undefined) {
      throw new AwsRuntimeConfigurationError("secret_value_invalid");
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(result.SecretString) as unknown;
    } catch {
      throw new AwsRuntimeConfigurationError("secret_value_invalid");
    }
    const value = record(parsed)?.[this.#jsonField];
    if (typeof value !== "string" || value.length === 0 || value.length > 16_384 || value !== value.trim()) {
      throw new AwsRuntimeConfigurationError("secret_value_invalid");
    }
    return value;
  }
}

/** Owner-operator-only reader for the seven generated database login
 * credentials. The caller may request only an ARN/username pair present in
 * the frozen construction-time map, and the secret payload must contain only
 * the generated credential schema. */
export class AwsRuntimeCredentialSecretReader {
  readonly #sender: AwsCommandSender;
  readonly #allowed: ReadonlyMap<string, string>;

  constructor(input: {
    readonly sender: AwsCommandSender;
    readonly allowed: Readonly<Record<string, string>>;
  }) {
    if (!sender(input?.sender) || input.allowed === null || typeof input.allowed !== "object") {
      throw new AwsRuntimeConfigurationError("secret_configuration_invalid");
    }
    const entries = Object.entries(input.allowed);
    if (entries.length !== 7 || entries.some(([username, arn]) =>
      !/^roomscan_(?:api|authorizer|auth_challenge|stripe_ingress|stripe_reconciliation|audit_export|email_delivery)_runtime$/u.test(username)
      || !secretArn(arn))) {
      throw new AwsRuntimeConfigurationError("secret_configuration_invalid");
    }
    this.#sender = input.sender;
    this.#allowed = new Map(entries.map(([username, arn]) => [arn, username]));
    if (this.#allowed.size !== 7) throw new AwsRuntimeConfigurationError("secret_configuration_invalid");
  }

  async read(input: Readonly<{ readonly secretArn: string; readonly expectedUsername: string }>): Promise<string> {
    if (this.#allowed.get(input?.secretArn) !== input.expectedUsername) {
      throw new AwsRuntimeConfigurationError("secret_reference_rejected");
    }
    const result = record(await this.#sender.send(new GetSecretValueCommand({
      SecretId: input.secretArn,
      VersionStage: "AWSCURRENT",
    })));
    if (typeof result?.SecretString !== "string" || result.SecretBinary !== undefined) {
      throw new AwsRuntimeConfigurationError("secret_value_invalid");
    }
    let parsed: unknown;
    try { parsed = JSON.parse(result.SecretString) as unknown; } catch {
      throw new AwsRuntimeConfigurationError("secret_value_invalid");
    }
    const value = record(parsed);
    if (value === undefined || Object.keys(value).sort().join(",") !== "password,rotationReady,username"
      || value.username !== input.expectedUsername || value.rotationReady !== true
      || typeof value.password !== "string" || value.password.length < 32 || value.password.length > 1_024
      || /[\u0000\r\n]/u.test(value.password)) {
      throw new AwsRuntimeConfigurationError("secret_value_invalid");
    }
    return value.password;
  }
}

/** Fixed-message wake. Database receipts/outboxes remain authoritative. */
export class AwsSqsWakePort {
  readonly #sender: AwsCommandSender;
  readonly #queueUrl: string;
  readonly #body: string;

  constructor(input: {
    readonly sender: AwsCommandSender;
    readonly queueUrl: string;
    readonly messageKind: string;
  }) {
    if (!sender(input?.sender) || !sqsQueueUrl(input.queueUrl) || !/^[a-z][a-z0-9-]{0,63}-v\d+$/u.test(input.messageKind)) {
      throw new AwsRuntimeConfigurationError("queue_configuration_invalid");
    }
    this.#sender = input.sender;
    this.#queueUrl = input.queueUrl;
    this.#body = JSON.stringify({ kind: input.messageKind });
  }

  async notify(): Promise<void> {
    const result = record(await this.#sender.send(new SendMessageCommand({
      QueueUrl: this.#queueUrl,
      MessageBody: this.#body,
    })));
    if (typeof result?.MessageId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/u.test(result.MessageId)) {
      throw new AwsRuntimeConfigurationError("queue_response_invalid");
    }
  }
}

export class AwsSesV2Port implements SesV2Port {
  constructor(private readonly sender: AwsCommandSender) {
    if (!sender || typeof sender.send !== "function") {
      throw new AwsRuntimeConfigurationError("ses_request_invalid");
    }
  }

  async send(input: Parameters<SesV2Port["send"]>[0]): Promise<void> {
    if (!email(input?.fromEmailAddress)
      || !/^arn:aws:ses:us-east-1:\d{12}:identity\/.{1,256}$/u.test(input.fromEmailAddressIdentityArn)
      || !token(input.configurationSetName, 64)
      || !Array.isArray(input.destination)
      || input.destination.length !== 1
      || !email(input.destination[0])
      || !token(input.templateName, 128)
      || typeof input.templateData !== "string"
      || input.templateData.length === 0
      || input.templateData.length > 262_144
      || !Array.isArray(input.tags)
      || input.tags.length > 10
      || input.tags.some((tag) => !token(tag.name, 64) || !token(tag.value, 256))) {
      throw new AwsRuntimeConfigurationError("ses_request_invalid");
    }
    await this.sender.send(new SendEmailCommand({
      FromEmailAddress: input.fromEmailAddress,
      FromEmailAddressIdentityArn: input.fromEmailAddressIdentityArn,
      ConfigurationSetName: input.configurationSetName,
      Destination: { ToAddresses: [...input.destination] },
      Content: { Template: { TemplateName: input.templateName, TemplateData: input.templateData } },
      EmailTags: input.tags.map((tag) => ({ Name: tag.name, Value: tag.value })),
    }));
  }
}

/** SES transport for the dedicated magic-delivery worker. The template,
 * sender, identity, and configuration set are fixed at construction; the
 * worker can supply only the validated destination, scanner-safe URL, and
 * immutable outbox id. */
export class AwsMagicDeliveryProviderPort {
  constructor(private readonly input: Readonly<{
    readonly ses: SesV2Port;
    readonly fromEmailAddress: string;
    readonly identityArn: string;
    readonly configurationSetName: string;
    readonly templateName: string;
  }>) {
    if (input === null || typeof input !== "object" || input.ses === null || typeof input.ses.send !== "function"
      || !email(input.fromEmailAddress) || !/^arn:aws:ses:us-east-1:\d{12}:identity\/.{1,256}$/u.test(input.identityArn)
      || !token(input.configurationSetName, 64) || !token(input.templateName, 128)) {
      throw new AwsRuntimeConfigurationError("ses_request_invalid");
    }
  }

  async send(value: Readonly<{
    readonly destination: string;
    readonly magicLinkUrl: string;
    readonly outboxId: string;
    readonly purpose: "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity";
  }>): Promise<void> {
    if (!email(value?.destination) || !token(value.outboxId, 128)
      || !["sign-in", "reauthenticate", "link-identity", "unlink-identity"].includes(value.purpose)) {
      throw new AwsRuntimeConfigurationError("ses_request_invalid");
    }
    let link: URL;
    try { link = new URL(value.magicLinkUrl); } catch { throw new AwsRuntimeConfigurationError("ses_request_invalid"); }
    if (link.protocol !== "https:" || link.username !== "" || link.password !== "" || link.search !== ""
      || !/^#secret=[A-Za-z0-9_-]{43}$/u.test(link.hash) || !/^\/auth\/magic-link\/[A-Za-z0-9_-]{22}$/u.test(link.pathname)) {
      throw new AwsRuntimeConfigurationError("ses_request_invalid");
    }
    await this.input.ses.send({
      fromEmailAddress: this.input.fromEmailAddress,
      fromEmailAddressIdentityArn: this.input.identityArn,
      configurationSetName: this.input.configurationSetName,
      destination: [value.destination],
      templateName: this.input.templateName,
      templateData: JSON.stringify({ magicLinkUrl: value.magicLinkUrl, purpose: value.purpose }),
      tags: [
        { name: "purpose", value: "magic_link" },
        { name: "outbox", value: value.outboxId },
      ],
    });
  }
}

/** Exact IAM-admin Cognito transport for the secretless CUSTOM_AUTH client.
 * It never accepts ClientMetadata, a client secret, SECRET_HASH, a password,
 * or a refresh token. The API forwards Cognito's Session byte-for-byte and
 * discards the provider tokens after a successful challenge. */
export class AwsCognitoAppleCustomAuthTransport {
  readonly #sender: AwsCommandSender;
  readonly #userPoolId: string;
  readonly #clientId: string;

  constructor(input: {
    readonly sender: AwsCommandSender;
    readonly userPoolId: string;
    readonly clientId: string;
  }) {
    if (!sender(input?.sender)
      || !/^[A-Za-z0-9_-]{1,55}$/u.test(input.userPoolId)
      || !/^[A-Za-z0-9]{3,128}$/u.test(input.clientId)) {
      throw new AwsRuntimeConfigurationError("cognito_configuration_invalid");
    }
    this.#sender = input.sender;
    this.#userPoolId = input.userPoolId;
    this.#clientId = input.clientId;
  }

  async ensureExistingUser(input: { readonly username: string; readonly clientId: string }): Promise<void> {
    this.#assertClientAndUsername(input);
    try {
      await this.#sender.send(new AdminGetUserCommand({
        UserPoolId: this.#userPoolId,
        Username: input.username,
      }));
      return;
    } catch (error) {
      if (!awsErrorNamed(error, "UserNotFoundException")) {
        throw new AwsRuntimeConfigurationError("cognito_response_invalid");
      }
    }
    try {
      await this.#sender.send(new AdminCreateUserCommand({
        UserPoolId: this.#userPoolId,
        Username: input.username,
        MessageAction: "SUPPRESS",
      }));
    } catch (error) {
      if (!awsErrorNamed(error, "UsernameExistsException")) {
        throw new AwsRuntimeConfigurationError("cognito_response_invalid");
      }
    }
  }

  async initiateCustomAuth(input: { readonly username: string; readonly clientId: string }): Promise<Readonly<{
    readonly session: string;
    readonly selector: string;
  }>> {
    this.#assertClientAndUsername(input);
    const result = record(await this.#sender.send(new AdminInitiateAuthCommand({
      UserPoolId: this.#userPoolId,
      ClientId: this.#clientId,
      AuthFlow: "CUSTOM_AUTH",
      AuthParameters: { USERNAME: input.username },
    })));
    const challengeParameters = record(result?.ChallengeParameters);
    if (result?.ChallengeName !== "CUSTOM_CHALLENGE"
      || !cognitoSession(result.Session)
      || !cognitoSelector(challengeParameters?.selector)) {
      throw new AwsRuntimeConfigurationError("cognito_response_invalid");
    }
    return Object.freeze({ session: result.Session, selector: challengeParameters.selector });
  }

  async respondToCustomAuthChallenge(input: {
    readonly username: string;
    readonly clientId: string;
    readonly session: string;
    readonly answer: string;
  }): Promise<Readonly<{ readonly outcome: "authenticated" }>> {
    this.#assertClientAndUsername(input);
    if (!cognitoSession(input.session) || !cognitoAnswer(input.answer)) {
      throw new AwsRuntimeConfigurationError("cognito_request_invalid");
    }
    const result = record(await this.#sender.send(new AdminRespondToAuthChallengeCommand({
      UserPoolId: this.#userPoolId,
      ClientId: this.#clientId,
      ChallengeName: "CUSTOM_CHALLENGE",
      ChallengeResponses: { USERNAME: input.username, ANSWER: input.answer },
      Session: input.session,
    })));
    const authenticationResult = record(result?.AuthenticationResult);
    if (result?.ChallengeName !== undefined || authenticationResult === undefined
      || typeof authenticationResult.AccessToken !== "string") {
      throw new AwsRuntimeConfigurationError("cognito_response_invalid");
    }
    return Object.freeze({ outcome: "authenticated" });
  }

  async linkFederatedIdentity(input: {
    readonly sourceUsername: string;
    readonly sourceIssuer: "https://appleid.apple.com";
    readonly sourceSubject: string;
    readonly destinationPrincipalId: string;
    readonly attemptId: string;
  }): Promise<void> {
    if (!cognitoUsername(input?.sourceUsername)
      || input.sourceIssuer !== "https://appleid.apple.com"
      || !boundedProviderSubject(input.sourceSubject)
      || !/^prn_[A-Za-z0-9_-]{22,64}$/u.test(input.destinationPrincipalId)
      || !/^[A-Za-z0-9_-]{16,128}$/u.test(input.attemptId)) {
      throw new AwsRuntimeConfigurationError("cognito_request_invalid");
    }
    // App-owned principals are the destination substrate users. Creation is
    // suppressed and race-safe; no email/password alias is attached.
    await this.ensureExistingUser({ username: input.destinationPrincipalId, clientId: this.#clientId });
    await this.#sender.send(new AdminLinkProviderForUserCommand({
      UserPoolId: this.#userPoolId,
      DestinationUser: {
        ProviderName: "Cognito",
        ProviderAttributeValue: input.destinationPrincipalId,
      },
      SourceUser: {
        ProviderName: "SignInWithApple",
        ProviderAttributeName: "Cognito_Subject",
        ProviderAttributeValue: input.sourceSubject,
      },
    }));
  }

  #assertClientAndUsername(input: { readonly username: string; readonly clientId: string }): void {
    if (input?.clientId !== this.#clientId || !cognitoUsername(input.username)) {
      throw new AwsRuntimeConfigurationError("cognito_request_invalid");
    }
  }
}

export type AwsPutPresign = (
  sender: AwsCommandSender,
  command: PutObjectCommand,
  options: Readonly<{ readonly expiresIn: number }>,
) => Promise<string>;

export class AwsPresignPutPort implements PresignPutPort {
  readonly #sender: AwsCommandSender;
  readonly #bucketName: string;
  readonly #presign: AwsPutPresign;

  constructor(input: {
    readonly sender: AwsCommandSender;
    readonly bucketName: string;
    readonly presign?: AwsPutPresign;
  }) {
    if (!sender(input?.sender) || !bucket(input.bucketName)) {
      throw new AwsRuntimeConfigurationError("presign_configuration_invalid");
    }
    this.#sender = input.sender;
    this.#bucketName = input.bucketName;
    this.#presign = input.presign ?? (async (client, command, options) =>
      getSignedUrl(client as unknown as S3Client, command, options));
  }

  async presignPut(input: Parameters<PresignPutPort["presignPut"]>[0]): Promise<{
    readonly url: string;
    readonly headers: Readonly<Record<string, string>>;
  }> {
    if (typeof input?.key !== "string"
      || !/^server\/quarantine\/v1\/[a-f0-9]{24}\/[A-Za-z0-9_-]{16,128}$/u.test(input.key)
      || !Number.isSafeInteger(input.contentLength)
      || input.contentLength <= 0
      || input.contentLength > 5_368_709_120
      || !/^[A-Za-z0-9+/]{43}=$/u.test(input.checksumSha256)
      || (input.contentType !== "application/zip" && input.contentType !== "application/octet-stream")
      || !Number.isSafeInteger(input.expiresInSeconds)
      || input.expiresInSeconds < 1
      || input.expiresInSeconds > 300
      || input.ifNoneMatch !== "*"
      || input.encryption !== "bucket-default-kms"
      || Object.keys(input.metadata).length !== 1
      || input.metadata["roomscan-upload-kind"] !== "quarantine-v1") {
      throw new AwsRuntimeConfigurationError("presign_request_invalid");
    }
    const command = new PutObjectCommand({
      Bucket: this.#bucketName,
      Key: input.key,
      ContentLength: input.contentLength,
      ContentType: input.contentType,
      ChecksumSHA256: input.checksumSha256,
      IfNoneMatch: input.ifNoneMatch,
      Metadata: { ...input.metadata },
    });
    const url = await this.#presign(this.#sender, command, { expiresIn: input.expiresInSeconds });
    if (!safeHttpsUrl(url)) {
      throw new AwsRuntimeConfigurationError("presign_response_invalid");
    }
    return Object.freeze({
      url,
      headers: Object.freeze({
        "content-length": String(input.contentLength),
        "content-type": input.contentType,
        "x-amz-checksum-sha256": input.checksumSha256,
        "if-none-match": "*",
        "x-amz-meta-roomscan-upload-kind": "quarantine-v1",
      }),
    });
  }
}

/** Protected audit-object transport. The service worker supplies only its
 * allowlisted, bounded audit record; this adapter cannot receive arbitrary
 * provider/request bodies and never includes credentials or bearer material. */
export class AwsProviderAuditDeliveryPort {
  readonly #sender: AwsCommandSender;
  readonly #bucketName: string;

  constructor(input: { readonly sender: AwsCommandSender; readonly bucketName: string }) {
    if (!sender(input?.sender) || !bucket(input.bucketName)) {
      throw new AwsRuntimeConfigurationError("presign_configuration_invalid");
    }
    this.#sender = input.sender;
    this.#bucketName = input.bucketName;
  }

  async deliver(event: Readonly<{
    readonly id: string;
    readonly lane: "apple" | "email" | "stripe";
    readonly eventCode: string;
    readonly boundedReference: string;
    readonly occurredAtMs: number;
    readonly deliveryAttempts: number;
  }>): Promise<void> {
    if (!identifier(event?.id, 1, 128)
      || (event.lane !== "apple" && event.lane !== "email" && event.lane !== "stripe")
      || !auditCode(event.eventCode)
      || !identifier(event.boundedReference, 1, 256)
      || !Number.isSafeInteger(event.occurredAtMs)
      || event.occurredAtMs < 0
      || !Number.isSafeInteger(event.deliveryAttempts)
      || event.deliveryAttempts < 1
      || event.deliveryAttempts > 1_000) {
      throw new AwsRuntimeConfigurationError("presign_request_invalid");
    }
    const body = Buffer.from(JSON.stringify({
      schema: "roomscan-provider-audit-v1",
      id: event.id,
      lane: event.lane,
      eventCode: event.eventCode,
      boundedReference: event.boundedReference,
      occurredAtMs: event.occurredAtMs,
      deliveryAttempts: event.deliveryAttempts,
    }));
    const checksum = createHash("sha256").update(body).digest("base64");
    await this.#sender.send(new PutObjectCommand({
      Bucket: this.#bucketName,
      Key: `server/audit/application/v1/${event.lane}/${event.id}.json`,
      Body: body,
      ContentLength: body.length,
      ContentType: "application/json",
      ChecksumSHA256: checksum,
      IfNoneMatch: "*",
    }));
  }
}

export type FetchPort = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export class BoundedHttpTransport implements HttpTransport {
  constructor(private readonly fetchPort: FetchPort = globalThis.fetch) {
    if (typeof fetchPort !== "function") {
      throw new AwsRuntimeConfigurationError("http_request_rejected");
    }
  }

  async request(input: Parameters<HttpTransport["request"]>[0]): Promise<{
    readonly status: number;
    readonly headers: Readonly<Record<string, string>>;
    readonly body: Uint8Array;
  }> {
    if (input?.method !== "POST"
      || input.followRedirects !== false
      || !safeHttpsUrl(input.url)
      || !(input.body instanceof Uint8Array)
      || input.body.length > 1_048_576
      || !Number.isSafeInteger(input.timeoutMs)
      || input.timeoutMs < 100
      || input.timeoutMs > 30_000
      || !Number.isSafeInteger(input.maxResponseBytes)
      || input.maxResponseBytes < 1
      || input.maxResponseBytes > 1_048_576
      || !safeHeaders(input.headers)) {
      throw new AwsRuntimeConfigurationError("http_request_rejected");
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), input.timeoutMs);
    timeout.unref();
    try {
      const response = await this.fetchPort(input.url, {
        method: "POST",
        headers: { ...input.headers },
        body: Buffer.from(input.body),
        redirect: "manual",
        signal: controller.signal,
      });
      const body = await boundedBody(response, input.maxResponseBytes);
      const headers: Record<string, string> = {};
      for (const [name, value] of response.headers) {
        if (Object.hasOwn(headers, name.toLowerCase())) {
          throw new AwsRuntimeConfigurationError("http_request_rejected");
        }
        headers[name.toLowerCase()] = value;
      }
      return Object.freeze({ status: response.status, headers: Object.freeze(headers), body });
    } finally {
      clearTimeout(timeout);
    }
  }
}

/** Fixed-method bounded GET transport used by provider-owned read adapters.
 * URL/header policy remains in the service adapter; redirects and oversized
 * bodies fail closed here. */
export class BoundedGetHttpTransport {
  constructor(private readonly fetchPort: FetchPort = globalThis.fetch) {
    if (typeof fetchPort !== "function") throw new AwsRuntimeConfigurationError("http_request_rejected");
  }

  async request(input: {
    readonly url: string;
    readonly method: "GET";
    readonly headers: Readonly<Record<string, string>>;
    readonly timeoutMs: number;
    readonly maxResponseBytes: number;
    readonly followRedirects: false;
  }): Promise<{ readonly status: number; readonly headers: Readonly<Record<string, string>>; readonly body: Uint8Array }> {
    if (input?.method !== "GET" || input.followRedirects !== false || !safeHttpsUrl(input.url)
      || !Number.isSafeInteger(input.timeoutMs) || input.timeoutMs < 100 || input.timeoutMs > 30_000
      || !Number.isSafeInteger(input.maxResponseBytes) || input.maxResponseBytes < 1 || input.maxResponseBytes > 1_048_576
      || !safeHeaders(input.headers)) throw new AwsRuntimeConfigurationError("http_request_rejected");
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), input.timeoutMs); timeout.unref();
    try {
      const response = await this.fetchPort(input.url, {
        method: "GET", headers: { ...input.headers }, redirect: "manual", signal: controller.signal,
      });
      const body = await boundedBody(response, input.maxResponseBytes);
      const headers: Record<string, string> = {};
      for (const [name, value] of response.headers) {
        const canonical = name.toLowerCase();
        if (Object.hasOwn(headers, canonical)) throw new AwsRuntimeConfigurationError("http_request_rejected");
        headers[canonical] = value;
      }
      return Object.freeze({ status: response.status, headers: Object.freeze(headers), body });
    } finally { clearTimeout(timeout); }
  }
}

/** Apple-key endpoint is fixed here so no request or token can select a JWKS
 * URL. The service remains responsible for key-field/signature validation. */
export class AwsAppleJwksPort {
  readonly #transport: BoundedGetHttpTransport;
  constructor(input: { readonly transport?: BoundedGetHttpTransport } = {}) {
    this.#transport = input.transport ?? new BoundedGetHttpTransport();
  }
  async fetch(_input: { readonly forceRefresh: boolean }): Promise<readonly unknown[]> {
    const response = await this.#transport.request({
      url: "https://appleid.apple.com/auth/keys",
      method: "GET",
      headers: Object.freeze({ accept: "application/json" }),
      timeoutMs: 5_000,
      maxResponseBytes: 65_536,
      followRedirects: false,
    });
    if (response.status !== 200 || response.headers["content-type"]?.split(";", 1)[0] !== "application/json") {
      throw new AwsRuntimeConfigurationError("http_request_rejected");
    }
    let parsed: unknown;
    try { parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(response.body)) as unknown; } catch {
      throw new AwsRuntimeConfigurationError("http_request_rejected");
    }
    const object = record(parsed);
    if (object === undefined || Object.keys(object).length !== 1 || !Array.isArray(object.keys)
      || object.keys.length < 1 || object.keys.length > 32) throw new AwsRuntimeConfigurationError("http_request_rejected");
    return Object.freeze([...object.keys]);
  }
}

function sender(value: unknown): value is AwsCommandSender {
  return value !== null && typeof value === "object" && typeof (value as AwsCommandSender).send === "function";
}

function record(value: unknown): Readonly<Record<string, unknown>> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Readonly<Record<string, unknown>>
    : undefined;
}

function secretArn(value: unknown): value is string {
  return typeof value === "string"
    && /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u.test(value);
}

function transactionIdentifier(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9._:-]{1,512}$/u.test(value);
}

function toAwsParameter(parameter: SqlParameter): AwsSqlParameter {
  if (parameter === null
    || typeof parameter !== "object"
    || !/^[A-Za-z][A-Za-z0-9_]{0,63}$/u.test(parameter.name)) {
    throw new AwsRuntimeConfigurationError("data_api_request_invalid");
  }
  const value = parameter.value;
  if (value.kind === "blob" && value.bytes instanceof Uint8Array && value.bytes.length <= 1_048_576) {
    return { name: parameter.name, value: { blobValue: Uint8Array.from(value.bytes) } };
  }
  if (value.kind === "string"
    && typeof value.value === "string"
    && value.value.length <= 65_536
    && (value.typeHint === undefined || value.typeHint === "TIMESTAMP" || value.typeHint === "UUID")) {
    return {
      name: parameter.name,
      ...(value.typeHint === undefined ? {} : { typeHint: value.typeHint }),
      value: { stringValue: value.value },
    };
  }
  if (value.kind === "long" && Number.isSafeInteger(value.value)) {
    return { name: parameter.name, value: { longValue: value.value } };
  }
  if (value.kind === "boolean" && typeof value.value === "boolean") {
    return { name: parameter.name, value: { booleanValue: value.value } };
  }
  if (value.kind === "null") {
    return { name: parameter.name, value: { isNull: true } };
  }
  throw new AwsRuntimeConfigurationError("data_api_request_invalid");
}

function decodeSqlResult(value: unknown): SqlResult {
  const output = record(value);
  if (output === undefined) throw new AwsRuntimeConfigurationError("data_api_response_invalid");
  const rawRecords = output.records ?? [];
  const rawMetadata = output.columnMetadata ?? [];
  if (!Array.isArray(rawRecords) || !Array.isArray(rawMetadata) || rawRecords.length > 10_000 || rawMetadata.length > 256) {
    throw new AwsRuntimeConfigurationError("data_api_response_invalid");
  }
  const names = rawMetadata.map((metadata) => {
    const name = record(metadata)?.name;
    if (typeof name !== "string" || !/^[A-Za-z_][A-Za-z0-9_]{0,127}$/u.test(name)) {
      throw new AwsRuntimeConfigurationError("data_api_response_invalid");
    }
    return name;
  });
  if (new Set(names).size !== names.length) {
    throw new AwsRuntimeConfigurationError("data_api_response_invalid");
  }
  const rows = rawRecords.map((rawRow) => {
    if (!Array.isArray(rawRow) || rawRow.length !== names.length) {
      throw new AwsRuntimeConfigurationError("data_api_response_invalid");
    }
    const row: Record<string, SqlCell> = {};
    for (const [index, name] of names.entries()) {
      row[name] = decodeField(rawRow[index]);
    }
    return Object.freeze(row);
  });
  return Object.freeze({ rows: Object.freeze(rows) });
}

function decodeField(value: unknown): SqlCell {
  const field = record(value) as (Readonly<Field> & Readonly<Record<string, unknown>>) | undefined;
  if (field === undefined) throw new AwsRuntimeConfigurationError("data_api_response_invalid");
  const recognized = ["blobValue", "booleanValue", "doubleValue", "isNull", "longValue", "stringValue"]
    .filter((key) => field[key] !== undefined);
  if (recognized.length !== 1) throw new AwsRuntimeConfigurationError("data_api_response_invalid");
  if (field.isNull === true) return null;
  if (typeof field.booleanValue === "boolean") return field.booleanValue;
  if (typeof field.longValue === "number" && Number.isSafeInteger(field.longValue)) return field.longValue;
  if (typeof field.doubleValue === "number" && Number.isFinite(field.doubleValue)) return field.doubleValue;
  if (typeof field.stringValue === "string" && field.stringValue.length <= 1_048_576) return field.stringValue;
  if (field.blobValue instanceof Uint8Array && field.blobValue.length <= 1_048_576) return Uint8Array.from(field.blobValue);
  throw new AwsRuntimeConfigurationError("data_api_response_invalid");
}

async function boundedBody(response: Response, maximum: number): Promise<Uint8Array> {
  const declared = response.headers.get("content-length");
  if (declared !== null && (!/^\d+$/u.test(declared) || Number(declared) > maximum)) {
    throw new AwsRuntimeConfigurationError("http_response_too_large");
  }
  if (response.body === null) return new Uint8Array();
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      length += next.value.byteLength;
      if (length > maximum) {
        await reader.cancel();
        throw new AwsRuntimeConfigurationError("http_response_too_large");
      }
      chunks.push(Uint8Array.from(next.value));
    }
  } finally {
    reader.releaseLock();
  }
  const body = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.length;
  }
  return body;
}

function safeHeaders(headers: Readonly<Record<string, string>>): boolean {
  if (headers === null || typeof headers !== "object" || Array.isArray(headers)) return false;
  const entries = Object.entries(headers);
  if (entries.length > 32) return false;
  const names = new Set<string>();
  let bytes = 0;
  for (const [name, value] of entries) {
    const lower = name.toLowerCase();
    if (!/^[a-z0-9-]{1,64}$/u.test(lower)
      || names.has(lower)
      || typeof value !== "string"
      || /[\r\n]/u.test(value)) return false;
    names.add(lower);
    bytes += name.length + value.length;
  }
  return bytes <= 16_384;
}

function safeHttpsUrl(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 4_096) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.username === "" && url.password === "" && url.hash === "";
  } catch {
    return false;
  }
}

function sqsQueueUrl(value: unknown): value is string {
  if (!safeHttpsUrl(value)) return false;
  const url = new URL(value);
  return url.hostname === "sqs.us-east-1.amazonaws.com"
    && /^\/\d{12}\/[A-Za-z0-9_-]{1,80}$/u.test(url.pathname)
    && url.search === "";
}

function bucket(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 3
    && value.length <= 63
    && /^[a-z0-9][a-z0-9.-]*[a-z0-9]$/u.test(value)
    && !value.includes("..")
    && !/^\d+\.\d+\.\d+\.\d+$/u.test(value);
}

function email(value: unknown): value is string {
  return typeof value === "string"
    && value.length <= 254
    && /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value);
}

function token(value: unknown, maximum: number): value is string {
  return typeof value === "string"
    && value.length >= 1
    && value.length <= maximum
    && /^[A-Za-z0-9_.:@/-]+$/u.test(value);
}

function identifier(value: unknown, minimum: number, maximum: number): value is string {
  return typeof value === "string"
    && value.length >= minimum
    && value.length <= maximum
    && /^[A-Za-z0-9_.:@/-]+$/u.test(value)
    && !value.includes("..")
    && !value.startsWith("/")
    && !value.endsWith("/");
}

function auditCode(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 1
    && value.length <= 128
    && /^[a-z][a-z0-9_.-]*$/u.test(value);
}

function cognitoUsername(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 3
    && value.length <= 128
    && /^(?:rsc_[A-Za-z0-9_-]{43}|prn_[A-Za-z0-9_-]{22,64})$/u.test(value);
}

function cognitoSession(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 20
    && value.length <= 2_048
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function cognitoSelector(value: unknown): value is string {
  return typeof value === "string"
    && /^[A-Za-z0-9_-]{22}$/u.test(value)
    && Buffer.from(value, "base64url").length === 16
    && Buffer.from(value, "base64url").toString("base64url") === value;
}

function cognitoAnswer(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 64
    && value.length <= 512
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function boundedProviderSubject(value: unknown): value is string {
  return typeof value === "string"
    && value.length >= 1
    && value.length <= 512
    && !/[\u0000-\u001f\u007f]/u.test(value);
}

function awsErrorNamed(value: unknown, name: string): boolean {
  return value !== null
    && typeof value === "object"
    && (value as { readonly name?: unknown }).name === name;
}
