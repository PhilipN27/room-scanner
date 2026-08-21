import assert from "node:assert/strict";
import test from "node:test";

import {
  AwsDataApiClient,
  AwsPresignPutPort,
  AwsProviderAuditDeliveryPort,
  AwsSecretValuePort,
  AwsSesV2Port,
  AwsSqsWakePort,
  BoundedHttpTransport,
  type AwsCommandSender,
} from "../src/aws/runtime-clients.js";

const account = "111111111111";
const clusterArn = `arn:aws:rds:us-east-1:${account}:cluster:roomscan-dev`;
const databaseSecretArn = `arn:aws:secretsmanager:us-east-1:${account}:secret:roomscan-api-AbCdEf`;
const applicationSecretArn = `arn:aws:secretsmanager:us-east-1:${account}:secret:roomscan-hmac-AbCdEf`;

class RecordingSender implements AwsCommandSender {
  readonly commands: unknown[] = [];
  readonly responses: unknown[] = [];

  async send(command: unknown): Promise<unknown> {
    this.commands.push(command);
    if (this.responses.length === 0) throw new Error("missing fake response");
    return this.responses.shift();
  }
}

test("Data API client fixes cluster, database, and lane secret across every transaction command", async () => {
  const sender = new RecordingSender();
  sender.responses.push(
    { transactionId: "tx_1" },
    {
      columnMetadata: [
        { name: "id" },
        { name: "enabled" },
        { name: "digest" },
        { name: "empty" },
      ],
      records: [[
        { stringValue: "row-1" },
        { booleanValue: true },
        { blobValue: Uint8Array.of(1, 2, 3) },
        { isNull: true },
      ]],
    },
    {},
    {},
  );
  const client = new AwsDataApiClient({
    sender,
    resourceArn: clusterArn,
    secretArn: databaseSecretArn,
    database: "roomscan",
  });

  assert.deepEqual(await client.begin(), { transactionId: "tx_1" });
  const result = await client.execute({
    transactionId: "tx_1",
    sql: "SELECT :text, :uuid, :time, :count, :flag, :digest, :empty",
    parameters: [
      { name: "text", value: { kind: "string", value: "safe" } },
      { name: "uuid", value: { kind: "string", value: "11111111-1111-4111-8111-111111111111", typeHint: "UUID" } },
      { name: "time", value: { kind: "string", value: "2030-01-01T00:00:00.000Z", typeHint: "TIMESTAMP" } },
      { name: "count", value: { kind: "long", value: 7 } },
      { name: "flag", value: { kind: "boolean", value: true } },
      { name: "digest", value: { kind: "blob", bytes: Uint8Array.of(4, 5, 6) } },
      { name: "empty", value: { kind: "null" } },
    ],
  });
  await client.commit("tx_1");
  await client.rollback("tx_2");

  assert.deepEqual(result, {
    rows: [{ id: "row-1", enabled: true, digest: Uint8Array.of(1, 2, 3), empty: null }],
  });
  assert.deepEqual(sender.commands.map(commandName), [
    "BeginTransactionCommand",
    "ExecuteStatementCommand",
    "CommitTransactionCommand",
    "RollbackTransactionCommand",
  ]);
  for (const command of sender.commands) {
    const input = commandInput(command);
    assert.equal(input.resourceArn, clusterArn);
    assert.equal(input.secretArn, databaseSecretArn);
  }
  assert.equal(commandInput(sender.commands[0]!).database, "roomscan");
  assert.equal(commandInput(sender.commands[1]!).database, "roomscan");
  assert.equal("database" in commandInput(sender.commands[2]!), false);
  assert.equal("database" in commandInput(sender.commands[3]!), false);
  assert.deepEqual(commandInput(sender.commands[1]!).parameters, [
    { name: "text", value: { stringValue: "safe" } },
    { name: "uuid", typeHint: "UUID", value: { stringValue: "11111111-1111-4111-8111-111111111111" } },
    { name: "time", typeHint: "TIMESTAMP", value: { stringValue: "2030-01-01T00:00:00.000Z" } },
    { name: "count", value: { longValue: 7 } },
    { name: "flag", value: { booleanValue: true } },
    { name: "digest", value: { blobValue: Uint8Array.of(4, 5, 6) } },
    { name: "empty", value: { isNull: true } },
  ]);
});

test("Data API rejects malformed, ambiguous, and unsupported result cells fail closed", async () => {
  for (const result of [
    { transactionId: "" },
    { transactionId: "contains a space" },
  ]) {
    const sender = new RecordingSender();
    sender.responses.push(result);
    const client = dataClient(sender);
    await assert.rejects(client.begin(), /data_api_response_invalid/u);
  }

  for (const result of [
    { columnMetadata: [{ name: "duplicate" }, { name: "duplicate" }], records: [[{ stringValue: "a" }, { stringValue: "b" }]] },
    { columnMetadata: [{ name: "mismatch" }], records: [[]] },
    { columnMetadata: [{ name: "ambiguous" }], records: [[{ stringValue: "a", longValue: 1 }]] },
    { columnMetadata: [{ name: "array" }], records: [[{ arrayValue: { stringValues: ["a"] } }]] },
  ]) {
    const sender = new RecordingSender();
    sender.responses.push(result);
    await assert.rejects(
      dataClient(sender).execute({ transactionId: "tx_1", sql: "SELECT 1" }),
      /data_api_response_invalid/u,
    );
  }
});

test("Secrets Manager reader accepts only its fixed ARN and exact bounded JSON field", async () => {
  const sender = new RecordingSender();
  sender.responses.push({ SecretString: JSON.stringify({ key: "k".repeat(64), decoy: "ignored" }) });
  const reader = new AwsSecretValuePort({ sender, secretArn: applicationSecretArn, jsonField: "key" });
  assert.equal(await reader.read(applicationSecretArn), "k".repeat(64));
  assert.equal(commandName(sender.commands[0]!), "GetSecretValueCommand");
  assert.deepEqual(commandInput(sender.commands[0]!), { SecretId: applicationSecretArn, VersionStage: "AWSCURRENT" });
  await assert.rejects(reader.read(databaseSecretArn), /secret_reference_rejected/u);

  for (const response of [
    {},
    { SecretBinary: Uint8Array.of(1) },
    { SecretString: "not-json" },
    { SecretString: JSON.stringify({ key: "" }) },
    { SecretString: JSON.stringify({ key: "x".repeat(16_385) }) },
  ]) {
    const invalidSender = new RecordingSender();
    invalidSender.responses.push(response);
    await assert.rejects(
      new AwsSecretValuePort({ sender: invalidSender, secretArn: applicationSecretArn, jsonField: "key" }).read(applicationSecretArn),
      /secret_value_invalid/u,
    );
  }
});

test("SQS wake and SES transport bind exact configured destinations without payload logging seams", async () => {
  const sqs = new RecordingSender();
  sqs.responses.push({ MessageId: "message-1" });
  const wake = new AwsSqsWakePort({
    sender: sqs,
    queueUrl: "https://sqs.us-east-1.amazonaws.com/111111111111/roomscan-dev-reconciliation",
    messageKind: "stripe-reconciliation-wake-v1",
  });
  await wake.notify();
  assert.equal(commandName(sqs.commands[0]!), "SendMessageCommand");
  assert.deepEqual(commandInput(sqs.commands[0]!), {
    QueueUrl: "https://sqs.us-east-1.amazonaws.com/111111111111/roomscan-dev-reconciliation",
    MessageBody: '{"kind":"stripe-reconciliation-wake-v1"}',
  });

  const ses = new RecordingSender();
  ses.responses.push({ MessageId: "ses-1" });
  await new AwsSesV2Port(ses).send({
    fromEmailAddress: "professional@example.invalid",
    fromEmailAddressIdentityArn: "arn:aws:ses:us-east-1:111111111111:identity/example.invalid",
    configurationSetName: "roomscan-transactional",
    destination: ["person@example.invalid"],
    templateName: "roomscan-magic-link-v1",
    templateData: '{"sealed":"value"}',
    tags: [{ name: "purpose", value: "magic_link" }],
  });
  assert.equal(commandName(ses.commands[0]!), "SendEmailCommand");
  assert.deepEqual(commandInput(ses.commands[0]!), {
    FromEmailAddress: "professional@example.invalid",
    FromEmailAddressIdentityArn: "arn:aws:ses:us-east-1:111111111111:identity/example.invalid",
    ConfigurationSetName: "roomscan-transactional",
    Destination: { ToAddresses: ["person@example.invalid"] },
    Content: { Template: { TemplateName: "roomscan-magic-link-v1", TemplateData: '{"sealed":"value"}' } },
    EmailTags: [{ Name: "purpose", Value: "magic_link" }],
  });
});

test("S3 presigner binds one quarantine bucket and exact signed PUT constraints", async () => {
  const sender = new RecordingSender();
  const observed: unknown[] = [];
  const presigner = new AwsPresignPutPort({
    sender,
    bucketName: "roomscan-dev-quarantine-111111111111",
    presign: async (_sender, command, options) => {
      observed.push(command, options);
      return "https://roomscan-dev-quarantine-111111111111.s3.us-east-1.amazonaws.com/server/quarantine/v1/key?signature=redacted";
    },
  });
  const response = await presigner.presignPut({
    key: "server/quarantine/v1/aaaaaaaaaaaaaaaaaaaaaaaa/opaque_server_key_1",
    contentLength: 42,
    checksumSha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    contentType: "application/zip",
    expiresInSeconds: 300,
    metadata: { "roomscan-upload-kind": "quarantine-v1" },
    ifNoneMatch: "*",
    encryption: "bucket-default-kms",
  });
  assert.equal(commandName(observed[0]!), "PutObjectCommand");
  assert.deepEqual(commandInput(observed[0]!), {
    Bucket: "roomscan-dev-quarantine-111111111111",
    Key: "server/quarantine/v1/aaaaaaaaaaaaaaaaaaaaaaaa/opaque_server_key_1",
    ContentLength: 42,
    ContentType: "application/zip",
    ChecksumSHA256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    IfNoneMatch: "*",
    Metadata: { "roomscan-upload-kind": "quarantine-v1" },
  });
  assert.deepEqual(observed[1], { expiresIn: 300 });
  assert.deepEqual(response.headers, {
    "content-length": "42",
    "content-type": "application/zip",
    "x-amz-checksum-sha256": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    "if-none-match": "*",
    "x-amz-meta-roomscan-upload-kind": "quarantine-v1",
  });
  assert.equal("ServerSideEncryption" in commandInput(observed[0]!), false);
});

test("provider audit delivery writes only bounded canonical facts under the protected server prefix", async () => {
  const sender = new RecordingSender();
  sender.responses.push({ ETag: '"etag"' });
  const delivery = new AwsProviderAuditDeliveryPort({
    sender,
    bucketName: "roomscan-dev-audit-111111111111",
  });
  await delivery.deliver({
    id: "audit_0000000000000001",
    lane: "stripe",
    eventCode: "stripe.reconciliation.applied",
    boundedReference: "evt_0000000000000001",
    occurredAtMs: 1_893_456_000_000,
    deliveryAttempts: 1,
  });
  assert.equal(commandName(sender.commands[0]!), "PutObjectCommand");
  const input = commandInput(sender.commands[0]!);
  assert.equal(input.Bucket, "roomscan-dev-audit-111111111111");
  assert.equal(input.Key, "server/audit/application/v1/stripe/audit_0000000000000001.json");
  assert.equal(input.ContentType, "application/json");
  assert.equal(input.IfNoneMatch, "*");
  assert.match(String(input.ChecksumSHA256), /^[A-Za-z0-9+/]{43}=$/u);
  const body = JSON.parse(Buffer.from(input.Body as Uint8Array).toString("utf8")) as Record<string, unknown>;
  assert.deepEqual(body, {
    schema: "roomscan-provider-audit-v1",
    id: "audit_0000000000000001",
    lane: "stripe",
    eventCode: "stripe.reconciliation.applied",
    boundedReference: "evt_0000000000000001",
    occurredAtMs: 1_893_456_000_000,
    deliveryAttempts: 1,
  });
  assert.equal("ServerSideEncryption" in input, false);
  assert.doesNotMatch(JSON.stringify(input), /accessToken|refreshToken|magic|presigned|biometric|latitude|longitude/u);
});

test("bounded HTTP transport disables redirects, aborts, and stops reading beyond the declared maximum", async () => {
  const requests: Array<{ readonly input: string | URL | Request; readonly init?: RequestInit }> = [];
  const transport = new BoundedHttpTransport(async (input, init) => {
    requests.push({ input, init });
    return new Response(Uint8Array.of(1, 2, 3), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  });
  const response = await transport.request({
    url: "https://appleid.apple.com/auth/token",
    method: "POST",
    headers: { accept: "application/json" },
    body: Uint8Array.of(4, 5),
    timeoutMs: 1_000,
    maxResponseBytes: 16,
    followRedirects: false,
  });
  assert.deepEqual(response.body, Uint8Array.of(1, 2, 3));
  assert.equal(requests[0]?.init?.redirect, "manual");
  assert.ok(requests[0]?.init?.signal instanceof AbortSignal);

  const oversized = new BoundedHttpTransport(async () => new Response(Uint8Array.of(1, 2, 3)));
  await assert.rejects(oversized.request({
    url: "https://appleid.apple.com/auth/token",
    method: "POST",
    headers: {},
    body: new Uint8Array(),
    timeoutMs: 1_000,
    maxResponseBytes: 2,
    followRedirects: false,
  }), /http_response_too_large/u);
  await assert.rejects(transport.request({
    url: "http://appleid.apple.com/auth/token",
    method: "POST",
    headers: {},
    body: new Uint8Array(),
    timeoutMs: 1_000,
    maxResponseBytes: 16,
    followRedirects: false,
  }), /http_request_rejected/u);
});

function dataClient(sender: AwsCommandSender): AwsDataApiClient {
  return new AwsDataApiClient({ sender, resourceArn: clusterArn, secretArn: databaseSecretArn, database: "roomscan" });
}

function commandName(value: unknown): string {
  return (value as { readonly constructor?: { readonly name?: string } }).constructor?.name ?? "";
}

function commandInput(value: unknown): Record<string, unknown> {
  const input = (value as { readonly input?: unknown }).input;
  assert.ok(input !== null && typeof input === "object" && !Array.isArray(input));
  return input as Record<string, unknown>;
}
