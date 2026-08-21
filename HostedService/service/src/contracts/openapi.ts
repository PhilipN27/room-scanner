import { SLICE4_ROUTE_MANIFEST, SLICE4_ROUTE_SET_VERSION, type FieldRule, type SealedRoute } from "./route-manifest.js";

function operation(route: SealedRoute): Readonly<Record<string, unknown>> {
  const body = route.request.body === "none" ? {} : {
    requestBody: {
      required: true,
      content: {
        "application/json": {
          schema: route.request.body === "json"
            ? objectSchema(route.request.fields ?? {})
            : { type: "string", maxLength: route.request.maximumBytes },
        },
      },
    },
  };
  const successContent = route.responseKind === "scanner-html" ? { "text/html": { schema: { type: "string" } } } : { "application/json": { schema: { $ref: "#/components/schemas/Success" } } };
  return { operationId: route.id.replaceAll(".", "_"), security: route.authorization.kind === "public" ? [] : [{ opaqueBearer: [] }], ...body, responses: { "200": { description: "Success", content: successContent }, "400": { $ref: "#/components/responses/InvalidRequest" }, "401": { $ref: "#/components/responses/Unauthenticated" }, "403": { $ref: "#/components/responses/Forbidden" }, "500": { $ref: "#/components/responses/Failure" } } };
}
function objectSchema(fields: Readonly<Record<string, FieldRule>>): Readonly<Record<string, unknown>> {
  return {
    type: "object",
    additionalProperties: false,
    required: Object.entries(fields).filter(([, rule]) => rule.required).map(([name]) => name),
    properties: Object.fromEntries(Object.entries(fields).map(([name, rule]) => [name,
      rule.type === "string"
        ? { type: "string", minLength: rule.minLength, maxLength: rule.maxLength, ...(rule.enum === undefined ? {} : { enum: rule.enum }), ...(rule.pattern === undefined ? {} : { pattern: rule.pattern }) }
        : { type: "boolean", ...(rule.literal === undefined ? {} : { const: rule.literal }) },
    ])),
  };
}
const paths: Record<string, Record<string, unknown>> = {};
for (const route of SLICE4_ROUTE_MANIFEST) { const path = route.pathTemplate.replace(":selector", "{selector}"); const item = paths[path] ?? {}; item[route.method.toLowerCase()] = operation(route); if (route.pathTemplate.includes(":selector")) item.parameters = [{ name: "selector", in: "path", required: true, schema: { type: "string", minLength: 16, maxLength: 128, pattern: "^[A-Za-z0-9_-]+$" } }]; paths[path] = item; }
const errorSchema = { type: "object", additionalProperties: false, required: ["error"], properties: { error: { type: "object", additionalProperties: false, required: ["code"], properties: { code: { type: "string", enum: ["invalid_request", "unauthenticated", "forbidden", "not_found", "unavailable"] } } } } };
const errorResponse = (description: string) => ({ description, content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } });
export const SLICE4_OPENAPI = deepFreeze({ openapi: "3.1.0", info: { title: "RoomScanStudio Professional Service", version: SLICE4_ROUTE_SET_VERSION }, paths, components: { securitySchemes: { opaqueBearer: { type: "http", scheme: "bearer", bearerFormat: "app-owned-opaque" } }, schemas: { Success: { type: "object", additionalProperties: true }, Error: errorSchema }, responses: { InvalidRequest: errorResponse("Invalid request"), Unauthenticated: errorResponse("Unauthenticated"), Forbidden: errorResponse("Forbidden"), Failure: errorResponse("Unavailable") } } });
function deepFreeze<T>(value: T): T { if (typeof value === "object" && value !== null && !Object.isFrozen(value)) { for (const child of Object.values(value as Record<string, unknown>)) deepFreeze(child); Object.freeze(value); } return value; }
