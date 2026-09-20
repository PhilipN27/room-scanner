namespace RoomScanWeb {
  export class WebContractError extends Error {
    constructor(readonly code: "invalid_presentation" | "invalid_response" | "invalid_canonical_json" | "invalid_geometry") {
      super(code);
      this.name = "WebContractError";
    }
  }

  export type PublishedAssetID = string;
  export type PresentationKind = "room" | "property";
  export type SemanticAccent = "blueprint" | "forest" | "slate" | "terracotta";
  export type PublishedLayoutKind = "wall" | "door" | "window" | "opening" | "floor" | "fixedObject" | "movableObject";
  export type QualitySeverity = "advisory" | "reviewRecommended" | "insufficientEvidence";
  export type InitialView = "entry" | "wall" | "corner" | "topDown";

  export type PublishedLayoutElement = Readonly<{ readonly kind: PublishedLayoutKind; readonly label: string; readonly x: number; readonly y: number; readonly width: number; readonly height: number }>;
  export type PublishedRoom = Readonly<{
    readonly roomKey: string;
    readonly displayName: string;
    readonly semanticLayout: Readonly<{ readonly elements: readonly PublishedLayoutElement[] }>;
    readonly orientation: Readonly<{ readonly initialView: InitialView }>;
    readonly dimensions: readonly Readonly<{ readonly label: string; readonly meters: number }>[];
    readonly qualityWarnings: readonly Readonly<{ readonly code: string; readonly severity: QualitySeverity; readonly message: string }>[];
    readonly comparisons: readonly Readonly<{ readonly originalAssetID: PublishedAssetID; readonly conceptAssetID: PublishedAssetID; readonly label: string; readonly disclaimer: string }>[];
    readonly assets: Readonly<{
      readonly webGeometryAssetID: PublishedAssetID;
      readonly floorPlanAssetID: PublishedAssetID;
      readonly selectedImageAssetIDs: readonly PublishedAssetID[];
      readonly webTextureAssetIDs: readonly PublishedAssetID[];
      readonly approvedConceptAssetIDs: readonly PublishedAssetID[];
    }>;
  }>;
  export type PublishedBranding = Readonly<{
    readonly businessName: string;
    readonly logoAssetID?: PublishedAssetID;
    readonly contact: Readonly<{ readonly phone?: string; readonly website?: string }>;
    readonly accent: SemanticAccent;
  }>;
  export type PublishedDownloads = Readonly<{ readonly floorPlanPDF: boolean; readonly galleryZIP: boolean; readonly aiReadyPackageAssetID?: PublishedAssetID }>;
  export type PublishedPresentation = Readonly<{
    readonly kind: PresentationKind;
    readonly title: string;
    readonly rooms: readonly PublishedRoom[];
    readonly branding: PublishedBranding;
    readonly downloads: PublishedDownloads;
    readonly independentRoomNotice?: string;
  }>;
  export type WebGeometry = Readonly<{
    readonly vertices: readonly Readonly<{ readonly x: number; readonly y: number; readonly z: number }>[];
    readonly triangles: readonly Readonly<{ readonly a: number; readonly b: number; readonly c: number }>[];
  }>;
  export type PortalSnapshotResponse = Readonly<{
    readonly snapshotID: string;
    readonly kind: PresentationKind;
    readonly presentation: Readonly<{ readonly assetID: PublishedAssetID; readonly contentType: "application/json"; readonly byteCount: number }>;
    readonly rooms: readonly Readonly<{ readonly roomKey: string; readonly roomOrder: number }>[];
    readonly feedbackEnabled: boolean;
    readonly aiReadyPackageEnabled: boolean;
  }>;

  const ROOM_SCHEMA = "roomscan-published-room-snapshot-v2";
  const PROPERTY_SCHEMA = "roomscan-published-property-snapshot-v1";
  export const INDEPENDENT_ROOM_NOTICE = "Rooms are presented independently; they do not share coordinates, alignment, connectivity, or reconstruction.";
  const MAX_ROOMS = 64;
  const MAX_LAYOUT = 256;
  const MAX_DIMENSIONS = 32;
  const MAX_WARNINGS = 32;
  const MAX_COMPARISONS = 32;
  const MAX_ASSETS_PER_ROOM = 64;

  export function parsePresentation(value: unknown): PublishedPresentation {
    const root = plainRecord(value, "invalid_presentation");
    const schemaVersion = presentationText(required(root, "schemaVersion", "invalid_presentation"), 1, 80);
    const contractKind = enumValue(required(root, "contractKind", "invalid_presentation"), ["publishedRoomSnapshot", "publishedPropertySnapshot"] as const, "invalid_presentation");
    if (schemaVersion === ROOM_SCHEMA && contractKind === "publishedRoomSnapshot") return parseRoomPresentation(root);
    if (schemaVersion === PROPERTY_SCHEMA && contractKind === "publishedPropertySnapshot") return parsePropertyPresentation(root);
    throw new WebContractError("invalid_presentation");
  }

  export function parseWebGeometry(value: unknown): WebGeometry {
    const record = closedRecord(value, ["vertices", "triangles"], [], "invalid_geometry");
    const verticesInput = arrayValue(record.vertices, 3, 250_000, "invalid_geometry");
    const vertices = verticesInput.map((candidate) => {
      const vertex = closedRecord(candidate, ["x", "y", "z"], [], "invalid_geometry");
      return freeze({
        x: finite(required(vertex, "x", "invalid_geometry"), -1_000, 1_000, "invalid_geometry"),
        y: finite(required(vertex, "y", "invalid_geometry"), -1_000, 1_000, "invalid_geometry"),
        z: finite(required(vertex, "z", "invalid_geometry"), -1_000, 1_000, "invalid_geometry"),
      });
    });
    const triangles = arrayValue(record.triangles, 1, 500_000, "invalid_geometry").map((candidate) => {
      const triangle = closedRecord(candidate, ["a", "b", "c"], [], "invalid_geometry");
      const a = integer(required(triangle, "a", "invalid_geometry"), 0, vertices.length - 1, "invalid_geometry");
      const b = integer(required(triangle, "b", "invalid_geometry"), 0, vertices.length - 1, "invalid_geometry");
      const c = integer(required(triangle, "c", "invalid_geometry"), 0, vertices.length - 1, "invalid_geometry");
      if (a === b || a === c || b === c) throw new WebContractError("invalid_geometry");
      return freeze({ a, b, c });
    });
    return freeze({ vertices: freezeArray(vertices), triangles: freezeArray(triangles) });
  }

  /** This is deliberately separate from the immutable presentation parser: the
   * service projects the two live link-policy facts at request time. */
  export function parsePortalSnapshot(value: unknown): PortalSnapshotResponse {
    const record = closedRecord(value, ["snapshotID", "kind", "presentation", "rooms", "feedbackEnabled", "aiReadyPackageEnabled"], [], "invalid_response");
    const kind = enumValue(required(record, "kind", "invalid_response"), ["room", "property"] as const, "invalid_response");
    const presentation = closedRecord(required(record, "presentation", "invalid_response"), ["assetID", "contentType", "byteCount"], [], "invalid_response");
    const rooms = arrayValue(required(record, "rooms", "invalid_response"), 0, MAX_ROOMS, "invalid_response").map((candidate) => {
      const room = closedRecord(candidate, ["roomKey", "roomOrder"], [], "invalid_response");
      return freeze({
        roomKey: webIdentifier(required(room, "roomKey", "invalid_response"), "invalid_response"),
        roomOrder: integer(required(room, "roomOrder", "invalid_response"), 1, MAX_ROOMS, "invalid_response"),
      });
    });
    unique(rooms.map((room) => room.roomKey), "invalid_response");
    unique(rooms.map((room) => String(room.roomOrder)), "invalid_response");
    if (kind === "room" && rooms.length !== 0) throw new WebContractError("invalid_response");
    if (kind === "property" && (rooms.length < 2 || rooms.some((room, index) => room.roomOrder !== index + 1))) throw new WebContractError("invalid_response");
    return freeze({
      snapshotID: publicIdentifier(required(record, "snapshotID", "invalid_response"), "snp_", "invalid_response"),
      kind,
      presentation: freeze({
        assetID: publicIdentifier(required(presentation, "assetID", "invalid_response"), "ast_", "invalid_response"),
        contentType: enumValue(required(presentation, "contentType", "invalid_response"), ["application/json"] as const, "invalid_response"),
        byteCount: integer(required(presentation, "byteCount", "invalid_response"), 1, 8_388_608, "invalid_response"),
      }),
      rooms: freezeArray(rooms),
      feedbackEnabled: booleanValue(required(record, "feedbackEnabled", "invalid_response"), "invalid_response"),
      aiReadyPackageEnabled: booleanValue(required(record, "aiReadyPackageEnabled", "invalid_response"), "invalid_response"),
    });
  }

  export function canonicalJSON(value: unknown): string {
    return canonical(value);
  }

  export function parseCanonicalJSON(source: string): unknown {
    if (typeof source !== "string" || source.length === 0 || source.length > 131_072) throw new WebContractError("invalid_canonical_json");
    let parsed: unknown;
    try { parsed = JSON.parse(source); } catch { throw new WebContractError("invalid_canonical_json"); }
    if (canonical(parsed) !== source) throw new WebContractError("invalid_canonical_json");
    return parsed;
  }

  function parseRoomPresentation(root: Readonly<Record<string, unknown>>): PublishedPresentation {
    const record = closedRecord(root, ["schemaVersion", "contractKind", "title", "room", "branding", "downloads"], [], "invalid_presentation");
    const room = parseRoom(required(record, "room", "invalid_presentation"));
    return freeze({
      kind: "room" as const,
      title: presentationText(required(record, "title", "invalid_presentation"), 1, 180),
      rooms: freezeArray([room]),
      branding: parseBranding(required(record, "branding", "invalid_presentation")),
      downloads: parseDownloads(required(record, "downloads", "invalid_presentation")),
    });
  }

  function parsePropertyPresentation(root: Readonly<Record<string, unknown>>): PublishedPresentation {
    const record = closedRecord(root, ["schemaVersion", "contractKind", "propertyTitle", "independentRoomNotice", "rooms", "branding", "downloads"], [], "invalid_presentation");
    const notice = presentationText(required(record, "independentRoomNotice", "invalid_presentation"), 1, 256);
    if (notice !== INDEPENDENT_ROOM_NOTICE) throw new WebContractError("invalid_presentation");
    const rooms = arrayValue(required(record, "rooms", "invalid_presentation"), 2, MAX_ROOMS, "invalid_presentation").map(parseRoom);
    unique(rooms.map((room) => room.roomKey), "invalid_presentation");
    return freeze({
      kind: "property" as const,
      title: presentationText(required(record, "propertyTitle", "invalid_presentation"), 1, 180),
      rooms: freezeArray(rooms),
      branding: parseBranding(required(record, "branding", "invalid_presentation")),
      downloads: parseDownloads(required(record, "downloads", "invalid_presentation")),
      independentRoomNotice: notice,
    });
  }

  function parseRoom(value: unknown): PublishedRoom {
    const record = closedRecord(value, ["roomKey", "displayName", "semanticLayout", "orientation", "dimensions", "qualityWarnings", "comparisons", "assets"], [], "invalid_presentation");
    const layoutRecord = closedRecord(required(record, "semanticLayout", "invalid_presentation"), ["elements"], [], "invalid_presentation");
    const elements = arrayValue(required(layoutRecord, "elements", "invalid_presentation"), 1, MAX_LAYOUT, "invalid_presentation").map(parseLayoutElement);
    const orientation = closedRecord(required(record, "orientation", "invalid_presentation"), ["initialView"], [], "invalid_presentation");
    const dimensions = arrayValue(required(record, "dimensions", "invalid_presentation"), 1, MAX_DIMENSIONS, "invalid_presentation").map((candidate) => {
      const dimension = closedRecord(candidate, ["label", "meters"], [], "invalid_presentation");
      return freeze({ label: presentationText(required(dimension, "label", "invalid_presentation"), 1, 80), meters: finite(required(dimension, "meters", "invalid_presentation"), 0.001, 1_000, "invalid_presentation") });
    });
    const warnings = arrayValue(required(record, "qualityWarnings", "invalid_presentation"), 0, MAX_WARNINGS, "invalid_presentation").map((candidate) => {
      const warning = closedRecord(candidate, ["code", "severity", "message"], [], "invalid_presentation");
      return freeze({
        code: identifier(required(warning, "code", "invalid_presentation"), "invalid_presentation"),
        severity: enumValue(required(warning, "severity", "invalid_presentation"), ["advisory", "reviewRecommended", "insufficientEvidence"] as const, "invalid_presentation"),
        message: presentationText(required(warning, "message", "invalid_presentation"), 1, 500),
      });
    });
    unique(warnings.map((warning) => warning.code), "invalid_presentation");
    const comparisons = arrayValue(required(record, "comparisons", "invalid_presentation"), 0, MAX_COMPARISONS, "invalid_presentation").map((candidate) => {
      const comparison = closedRecord(candidate, ["originalAssetID", "conceptAssetID", "label", "disclaimer"], [], "invalid_presentation");
      return freeze({
        originalAssetID: identifier(required(comparison, "originalAssetID", "invalid_presentation"), "invalid_presentation"),
        conceptAssetID: identifier(required(comparison, "conceptAssetID", "invalid_presentation"), "invalid_presentation"),
        label: presentationText(required(comparison, "label", "invalid_presentation"), 1, 120),
        disclaimer: presentationText(required(comparison, "disclaimer", "invalid_presentation"), 1, 500),
      });
    });
    const assets = parseRoomAssets(required(record, "assets", "invalid_presentation"));
    return freeze({
      roomKey: identifier(required(record, "roomKey", "invalid_presentation"), "invalid_presentation"),
      displayName: presentationText(required(record, "displayName", "invalid_presentation"), 1, 120),
      semanticLayout: freeze({ elements: freezeArray(elements) }),
      orientation: freeze({ initialView: enumValue(required(orientation, "initialView", "invalid_presentation"), ["entry", "wall", "corner", "topDown"] as const, "invalid_presentation") }),
      dimensions: freezeArray(dimensions),
      qualityWarnings: freezeArray(warnings),
      comparisons: freezeArray(comparisons),
      assets,
    });
  }

  function parseLayoutElement(value: unknown): PublishedLayoutElement {
    const record = closedRecord(value, ["kind", "label", "x", "y", "width", "height"], [], "invalid_presentation");
    const x = finite(required(record, "x", "invalid_presentation"), 0, 1, "invalid_presentation");
    const y = finite(required(record, "y", "invalid_presentation"), 0, 1, "invalid_presentation");
    const width = finite(required(record, "width", "invalid_presentation"), 0.0001, 1, "invalid_presentation");
    const height = finite(required(record, "height", "invalid_presentation"), 0.0001, 1, "invalid_presentation");
    if (x + width > 1.000_001 || y + height > 1.000_001) throw new WebContractError("invalid_presentation");
    return freeze({
      kind: enumValue(required(record, "kind", "invalid_presentation"), ["wall", "door", "window", "opening", "floor", "fixedObject", "movableObject"] as const, "invalid_presentation"),
      label: presentationText(required(record, "label", "invalid_presentation"), 1, 120), x, y, width, height,
    });
  }

  function parseRoomAssets(value: unknown): PublishedRoom["assets"] {
    const record = closedRecord(value, ["webGeometryAssetID", "floorPlanAssetID", "selectedImageAssetIDs", "webTextureAssetIDs", "approvedConceptAssetIDs"], [], "invalid_presentation");
    return freeze({
      webGeometryAssetID: identifier(required(record, "webGeometryAssetID", "invalid_presentation"), "invalid_presentation"),
      floorPlanAssetID: identifier(required(record, "floorPlanAssetID", "invalid_presentation"), "invalid_presentation"),
      selectedImageAssetIDs: identifierArray(required(record, "selectedImageAssetIDs", "invalid_presentation")),
      webTextureAssetIDs: identifierArray(required(record, "webTextureAssetIDs", "invalid_presentation")),
      approvedConceptAssetIDs: identifierArray(required(record, "approvedConceptAssetIDs", "invalid_presentation")),
    });
  }

  function parseBranding(value: unknown): PublishedBranding {
    const record = closedRecord(value, ["businessName", "contact", "accent"], ["logoAssetID"], "invalid_presentation");
    const contactRecord = closedRecord(required(record, "contact", "invalid_presentation"), [], ["phone", "website"], "invalid_presentation");
    const phone = contactRecord.phone === undefined ? undefined : phoneValue(contactRecord.phone);
    const website = contactRecord.website === undefined ? undefined : httpsURL(contactRecord.website);
    if (phone === undefined && website === undefined) throw new WebContractError("invalid_presentation");
    const logoAssetID = record.logoAssetID === undefined ? undefined : identifier(record.logoAssetID, "invalid_presentation");
    return freeze({
      businessName: presentationText(required(record, "businessName", "invalid_presentation"), 1, 120),
      ...(logoAssetID === undefined ? {} : { logoAssetID }),
      contact: freeze({ ...(phone === undefined ? {} : { phone }), ...(website === undefined ? {} : { website }) }),
      accent: enumValue(required(record, "accent", "invalid_presentation"), ["blueprint", "forest", "slate", "terracotta"] as const, "invalid_presentation"),
    });
  }

  function parseDownloads(value: unknown): PublishedDownloads {
    const record = closedRecord(value, ["floorPlanPDF", "galleryZIP"], ["aiReadyPackageAssetID"], "invalid_presentation");
    const aiReadyPackageAssetID = record.aiReadyPackageAssetID === undefined ? undefined : identifier(record.aiReadyPackageAssetID, "invalid_presentation");
    return freeze({
      floorPlanPDF: booleanValue(required(record, "floorPlanPDF", "invalid_presentation"), "invalid_presentation"),
      galleryZIP: booleanValue(required(record, "galleryZIP", "invalid_presentation"), "invalid_presentation"),
      ...(aiReadyPackageAssetID === undefined ? {} : { aiReadyPackageAssetID }),
    });
  }

  function identifierArray(value: unknown): readonly PublishedAssetID[] {
    const items = arrayValue(value, 0, MAX_ASSETS_PER_ROOM, "invalid_presentation").map((candidate) => identifier(candidate, "invalid_presentation"));
    unique(items, "invalid_presentation");
    return freezeArray(items);
  }

  function canonical(value: unknown): string {
    if (value === null) return "null";
    if (typeof value === "string") {
      if (hasUnpairedSurrogate(value)) throw new WebContractError("invalid_canonical_json");
      return JSON.stringify(value);
    }
    if (typeof value === "boolean") return value ? "true" : "false";
    if (typeof value === "number") {
      if (!Number.isFinite(value)) throw new WebContractError("invalid_canonical_json");
      const encoded = JSON.stringify(value);
      if (encoded === undefined) throw new WebContractError("invalid_canonical_json");
      return encoded;
    }
    if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
    if (value !== null && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
      const record = value as Readonly<Record<string, unknown>>;
      return `{${Object.keys(record).sort().map((key) => `${canonical(key)}:${canonical(record[key])}`).join(",")}}`;
    }
    throw new WebContractError("invalid_canonical_json");
  }

  function hasUnpairedSurrogate(value: string): boolean {
    for (let index = 0; index < value.length; index += 1) {
      const unit = value.charCodeAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        const next = value.charCodeAt(index + 1);
        if (!(next >= 0xdc00 && next <= 0xdfff)) return true;
        index += 1;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) return true;
    }
    return false;
  }

  function plainRecord(value: unknown, code: WebContractError["code"]): Readonly<Record<string, unknown>> {
    if (value === null || typeof value !== "object" || Array.isArray(value) || Object.getPrototypeOf(value) !== Object.prototype) throw new WebContractError(code);
    return value as Readonly<Record<string, unknown>>;
  }
  function closedRecord(value: unknown, requiredKeys: readonly string[], optionalKeys: readonly string[], code: WebContractError["code"]): Readonly<Record<string, unknown>> {
    const record = plainRecord(value, code); const allowed = new Set([...requiredKeys, ...optionalKeys]);
    if (Object.keys(record).some((key) => !allowed.has(key)) || requiredKeys.some((key) => !(key in record))) throw new WebContractError(code);
    return record;
  }
  function required(record: Readonly<Record<string, unknown>>, key: string, code: WebContractError["code"]): unknown { if (!(key in record)) throw new WebContractError(code); return record[key]; }
  function arrayValue(value: unknown, minimum: number, maximum: number, code: WebContractError["code"]): readonly unknown[] { if (!Array.isArray(value) || value.length < minimum || value.length > maximum) throw new WebContractError(code); return value; }
  function presentationText(value: unknown, minimum: number, maximum: number): string { if (typeof value !== "string" || scalarLength(value) < minimum || scalarLength(value) > maximum || hasUnpairedSurrogate(value) || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) throw new WebContractError("invalid_presentation"); return value; }
  function identifier(value: unknown, code: WebContractError["code"]): string { if (typeof value !== "string" || value.length < 1 || value.length > 128 || !/^[A-Za-z0-9_-]+$/u.test(value)) throw new WebContractError(code); return value; }
  function publicIdentifier(value: unknown, prefix: string, code: WebContractError["code"]): string { const result = identifier(value, code); if (!result.startsWith(prefix) || result.length < 20) throw new WebContractError(code); return result; }
  function webIdentifier(value: unknown, code: WebContractError["code"]): string { if (typeof value !== "string" || value.length < 1 || value.length > 128 || !/^[A-Za-z0-9_.-]+$/u.test(value)) throw new WebContractError(code); return value; }
  function finite(value: unknown, minimum: number, maximum: number, code: WebContractError["code"]): number { if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) throw new WebContractError(code); return value; }
  function integer(value: unknown, minimum: number, maximum: number, code: WebContractError["code"]): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw new WebContractError(code); return value; }
  function booleanValue(value: unknown, code: WebContractError["code"]): boolean { if (typeof value !== "boolean") throw new WebContractError(code); return value; }
  function enumValue<T extends readonly string[]>(value: unknown, allowed: T, code: WebContractError["code"]): T[number] { if (typeof value !== "string" || !allowed.includes(value)) throw new WebContractError(code); return value as T[number]; }
  function unique(values: readonly string[], code: WebContractError["code"]): void { if (new Set(values).size !== values.length) throw new WebContractError(code); }
  function scalarLength(value: string): number { return Array.from(value).length; }
  function phoneValue(value: unknown): string { return presentationText(value, 1, 80); }
  function httpsURL(value: unknown): string {
    if (typeof value !== "string" || value.length > 2_048 || hasUnpairedSurrogate(value) || !/^https:\/\/[A-Za-z0-9.-]+(?:\/[^\s]*)?$/u.test(value)) throw new WebContractError("invalid_presentation");
    return value;
  }
  function freeze<T extends object>(value: T): Readonly<T> { return Object.freeze(value); }
  function freezeArray<T>(values: readonly T[]): readonly T[] { return Object.freeze([...values]); }
}
