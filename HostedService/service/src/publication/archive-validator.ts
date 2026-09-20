import { createHash } from "node:crypto";
import { createInflate } from "node:zlib";

import {
  PUBLICATION_ARCHIVE_SCHEMA_VERSION,
  PUBLICATION_MAX_ARCHIVE_BYTES,
  PUBLICATION_MAX_ASSET_BYTES,
  PUBLICATION_MAX_NESTED_AI_READY_BYTES,
  PUBLICATION_MAX_PRESENTATION_BYTES,
  PUBLICATION_MAX_PROTECTED_CHUNK_BYTES,
  PUBLICATION_SELECTION_SCHEMA_VERSION,
  canonicalJsonSHA256,
  isCanonicalTimestamp,
  isSHA256,
  sha256Bytes,
  strictCanonicalJson,
} from "./contracts.js";

/** A random-access source is intentional: a 768 MiB publication archive is
 * never materialized in service memory before it is promoted. */
export interface PublicationArchiveReader {
  readonly byteLength: number;
  read(offset: number, length: number): Promise<Uint8Array>;
}

export interface PublicationArchiveExpectation {
  readonly archive: { readonly byteCount: number; readonly sha256: string };
  readonly publicationManifest: { readonly byteCount: number; readonly sha256: string };
  readonly presentation: { readonly byteCount: number; readonly sha256: string };
  readonly sourceBindingsSHA256: string;
  readonly selectionManifestSHA256: string;
  readonly approvalSHA256: string;
  readonly ledger: readonly {
    readonly path: string;
    readonly byteCount: number;
    readonly sha256: string;
    readonly mediaType: string;
  }[];
}

export type PublicationArchiveValidationCode =
  | "archive_digest"
  | "archive_size"
  | "zip_closure"
  | "manifest"
  | "presentation"
  | "binding"
  | "approval"
  | "selection"
  | "asset"
  | "media"
  | "geometry"
  | "ai_package";

export class PublicationArchiveValidationError extends Error {
  constructor(readonly code: PublicationArchiveValidationCode) {
    super(code);
    this.name = "PublicationArchiveValidationError";
  }
}

export interface ValidatedPublicationSourceBinding {
  readonly publicRoomKey: string;
  readonly sourceRevision: {
    readonly projectID: string;
    readonly revisionID: string;
    readonly coordinateSpaceEpochID: string;
    readonly packageSchemaVersion: "room-scan-project-v1" | "room-scan-project-v2";
    readonly semanticSHA256: string;
    readonly revisionManifestSHA256: string;
  };
}

export interface ValidatedPublicationAsset {
  readonly assetID: string;
  readonly publicRoomKey?: string;
  readonly assetClass: "webGeometry" | "webTexture" | "selectedImage" | "floorPlan" | "approvedConcept" | "brandingLogo" | "aiReadyPackage";
  readonly relativePath: string;
  readonly sha256: string;
  readonly byteCount: number;
  readonly mediaType: string;
}

/** Explicit download switches are part of the immutable presentation record.
 * The worker may derive a fallback only when this closed allowlist enables it;
 * a link cannot manufacture a PDF or gallery that the reviewed snapshot did
 * not approve. */
export interface ValidatedPublicationDownloads {
  readonly floorPlanPDF: boolean;
  readonly galleryZIP: boolean;
  readonly aiReadyPackageAssetID?: string;
}

export interface ValidatedPublicationArchive {
  readonly snapshotKind: "room" | "property";
  readonly sourceBindingsSHA256: string;
  readonly sourceBindings: readonly ValidatedPublicationSourceBinding[];
  readonly selectionManifestSHA256: string;
  readonly approvalSHA256: string;
  readonly presentationSHA256: string;
  readonly presentationText: string;
  readonly downloads: ValidatedPublicationDownloads;
  readonly independentRoomKeys: readonly string[];
  readonly assets: readonly ValidatedPublicationAsset[];
}

interface ZipEntry {
  readonly path: string;
  readonly crc32: number;
  readonly byteCount: number;
  readonly localOffset: number;
  readonly dataOffset: number;
}

interface PublicationManifest {
  readonly snapshotKind: "room" | "property";
  readonly sourceBindings: readonly ValidatedPublicationSourceBinding[];
  readonly sourceBindingsSHA256: string;
  readonly selectionManifestSHA256: string;
  readonly approvalSHA256: string;
  readonly presentationSHA256: string;
  readonly assets: readonly ValidatedPublicationAsset[];
  readonly aiBindings: ReadonlyMap<string, AIReadyPackageBinding>;
}

export interface AIReadyPackageBinding {
  readonly packageID: string;
  readonly publicRoomKey: string;
  readonly manifestSHA256: string;
  readonly artifactPlanSHA256: string;
  readonly selectionSHA256: string;
}

const ZIP_EOCD = 0x0605_4b50;
const ZIP_CENTRAL = 0x0201_4b50;
const ZIP_LOCAL = 0x0403_4b50;
const MAX_ZIP_ENTRIES = 512;
const MAX_CENTRAL_DIRECTORY_BYTES = 1_048_576;

/** Validates closure from the exact immutable outer bytes through the only
 * approved ledger and portal-safe presentation. This starts from an empty
 * allowlist; there is no private-project subtractive projection anywhere in
 * this module. */
export async function validatePublicationArchive(input: {
  readonly reader: PublicationArchiveReader;
  readonly expected: PublicationArchiveExpectation;
}): Promise<ValidatedPublicationArchive> {
  const { reader, expected } = input;
  assertReader(reader, PUBLICATION_MAX_ARCHIVE_BYTES, "archive_size");
  if (reader.byteLength !== expected.archive.byteCount || !isSHA256(expected.archive.sha256)) throw invalid("archive_digest");
  if (await digestReader(reader) !== expected.archive.sha256) throw invalid("archive_digest");

  const entries = await parseStoreZip(reader, "zip_closure");
  const byPath = mapEntries(entries, "zip_closure");
  const manifestEntry = requireEntry(byPath, "publication-manifest.json", "manifest");
  const presentationEntry = requireEntry(byPath, "presentation.json", "presentation");

  const manifestBytes = await readEntry(reader, manifestEntry, PUBLICATION_MAX_PRESENTATION_BYTES, "manifest");
  if (manifestBytes.byteLength !== expected.publicationManifest.byteCount || sha256Bytes(manifestBytes) !== expected.publicationManifest.sha256) throw invalid("manifest");
  const manifest = parsePublicationManifest(manifestBytes, expected);

  const presentationBytes = await readEntry(reader, presentationEntry, PUBLICATION_MAX_PRESENTATION_BYTES, "presentation");
  if (presentationBytes.byteLength !== expected.presentation.byteCount || sha256Bytes(presentationBytes) !== expected.presentation.sha256) throw invalid("presentation");
  if (manifest.presentationSHA256 !== expected.presentation.sha256) throw invalid("selection");
  const presentationText = utf8Text(presentationBytes, "presentation");
  const presentation = validatePresentation(presentationBytes, manifest);

  validateOuterClosure(entries, manifest.assets);
  validateFixtureLedger(manifest.assets, expected.ledger);
  for (const asset of manifest.assets) {
    const entry = requireEntry(byPath, asset.relativePath, "asset");
    await validateAsset(reader, entry, asset, manifest.aiBindings.get(asset.assetID), manifest.sourceBindings);
  }

  return Object.freeze({
    snapshotKind: manifest.snapshotKind,
    sourceBindingsSHA256: manifest.sourceBindingsSHA256,
    sourceBindings: Object.freeze([...manifest.sourceBindings]),
    selectionManifestSHA256: manifest.selectionManifestSHA256,
    approvalSHA256: manifest.approvalSHA256,
    presentationSHA256: manifest.presentationSHA256,
    presentationText,
    downloads: presentation.downloads,
    independentRoomKeys: Object.freeze([...presentation.independentRoomKeys]),
    assets: Object.freeze([...manifest.assets]),
  });
}

/** Worker-only inspection for building the validation expectation from the
 * exact quarantine object.  Nothing returned here is publication truth: the
 * subsequent validator binds the manifest to the allocation's source,
 * approval, selection and archive digests before any active object is made
 * reachable.  Keeping this separate prevents a worker from buffering a
 * 768 MiB upload just to learn the two small control-entry lengths. */
export async function inspectPublicationArchiveForValidation(reader: PublicationArchiveReader): Promise<Readonly<{
  readonly publicationManifest: Readonly<{ readonly byteCount: number; readonly sha256: string }>;
  readonly presentation: Readonly<{ readonly byteCount: number; readonly sha256: string }>;
  readonly ledger: readonly Readonly<{ readonly path: string; readonly byteCount: number; readonly sha256: string; readonly mediaType: string }>[];
}>> {
  assertReader(reader, PUBLICATION_MAX_ARCHIVE_BYTES, "archive_size");
  const entries = await parseStoreZip(reader, "zip_closure");
  const byPath = mapEntries(entries, "zip_closure");
  const manifestEntry = requireEntry(byPath, "publication-manifest.json", "manifest");
  const presentationEntry = requireEntry(byPath, "presentation.json", "presentation");
  const manifestBytes = await readEntry(reader, manifestEntry, PUBLICATION_MAX_PRESENTATION_BYTES, "manifest");
  const presentationBytes = await readEntry(reader, presentationEntry, PUBLICATION_MAX_PRESENTATION_BYTES, "presentation");
  const root = object(strict(manifestBytes, "manifest"), "manifest");
  const rawAssets = array(root.assets, "manifest");
  const ledger = rawAssets.map((candidate) => {
    const asset = object(candidate, "asset");
    const path = publicationAssetPath(asset.relativePath, identifier(asset.assetID, "asset"), enumString(asset.assetClass, ["webGeometry", "webTexture", "selectedImage", "floorPlan", "approvedConcept", "brandingLogo", "aiReadyPackage"] as const, "asset"), "asset");
    const entry = requireEntry(byPath, path, "asset");
    return Object.freeze({ path, byteCount: entry.byteCount, sha256: digest(asset.sha256, "asset"), mediaType: media(asset.mediaType, "asset") });
  });
  return Object.freeze({
    publicationManifest: Object.freeze({ byteCount: manifestBytes.byteLength, sha256: sha256Bytes(manifestBytes) }),
    presentation: Object.freeze({ byteCount: presentationBytes.byteLength, sha256: sha256Bytes(presentationBytes) }),
    ledger: Object.freeze(ledger),
  });
}

/** This is deliberately usable only after `validatePublicationArchive` has
 * succeeded in the worker.  It is a random-access extraction primitive for a
 * ledger path; it rechecks ZIP framing and CRC before bytes cross from the
 * immutable quarantine object into the active derivative namespace. */
export async function readValidatedPublicationArchiveEntry(reader: PublicationArchiveReader, path: string, maximumBytes: number): Promise<Uint8Array> {
  if (typeof path !== "string" || !Number.isSafeInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > PUBLICATION_MAX_NESTED_AI_READY_BYTES) throw invalid("asset");
  const entries = await parseStoreZip(reader, "zip_closure");
  const entry = requireEntry(mapEntries(entries, "zip_closure"), path, "asset");
  if (entry.byteCount > maximumBytes) throw invalid("asset");
  const bytes = await readEntry(reader, entry, maximumBytes, "asset");
  if (crc32(bytes) !== entry.crc32) throw invalid("asset");
  return bytes;
}

function parsePublicationManifest(bytes: Uint8Array, expected: PublicationArchiveExpectation): PublicationManifest {
  const root = object(strict(bytes, "manifest"), "manifest");
  exactKeys(root, [
    "approval", "assets", "contractKind", "presentationSHA256", "schemaVersion", "selectionManifestSHA256",
    "snapshotKind", "sourceBindings", "sourceBindingsSHA256",
  ], "manifest");
  if (root.schemaVersion !== PUBLICATION_ARCHIVE_SCHEMA_VERSION || root.contractKind !== "publicationArchive") throw invalid("manifest");
  const snapshotKind = enumString(root.snapshotKind, ["room", "property"] as const, "manifest");
  const sourceBindingsRaw = array(root.sourceBindings, "binding");
  const sourceBindings = parseSourceBindings(sourceBindingsRaw, snapshotKind);
  const sourceBindingsSHA256 = digest(root.sourceBindingsSHA256, "binding");
  if (sourceBindingsSHA256 !== canonicalJsonSHA256(sourceBindingsRaw) || sourceBindingsSHA256 !== expected.sourceBindingsSHA256) throw invalid("binding");

  const selectionManifestSHA256 = digest(root.selectionManifestSHA256, "selection");
  const presentationSHA256 = digest(root.presentationSHA256, "selection");
  const { approvalSHA256 } = parseApproval(root.approval, sourceBindingsSHA256, selectionManifestSHA256, expected.approvalSHA256);
  const { assets, aiBindings, rawAssets } = parseLedger(root.assets, sourceBindings);
  const computedSelection = canonicalJsonSHA256({
    schemaVersion: PUBLICATION_SELECTION_SCHEMA_VERSION,
    presentationSHA256,
    assets: rawAssets,
  });
  if (selectionManifestSHA256 !== computedSelection || selectionManifestSHA256 !== expected.selectionManifestSHA256) throw invalid("selection");
  return Object.freeze({
    snapshotKind, sourceBindings, sourceBindingsSHA256, selectionManifestSHA256, approvalSHA256,
    presentationSHA256, assets, aiBindings,
  });
}

function parseSourceBindings(values: readonly unknown[], snapshotKind: "room" | "property"): readonly ValidatedPublicationSourceBinding[] {
  if (values.length < 1 || values.length > 64 || (snapshotKind === "room" && values.length !== 1) || (snapshotKind === "property" && values.length < 2)) throw invalid("binding");
  const keys = new Set<string>();
  const result = values.map((value) => {
    const root = object(value, "binding");
    exactKeys(root, ["publicRoomKey", "sourceRevision"], "binding");
    const publicRoomKey = identifier(root.publicRoomKey, "binding");
    if (keys.has(publicRoomKey)) throw invalid("binding");
    keys.add(publicRoomKey);
    const source = object(root.sourceRevision, "binding");
    exactKeys(source, ["coordinateSpaceEpochID", "packageSchemaVersion", "projectID", "revisionID", "revisionManifestSHA256", "semanticSHA256"], "binding");
    return Object.freeze({
      publicRoomKey,
      sourceRevision: Object.freeze({
        coordinateSpaceEpochID: identifier(source.coordinateSpaceEpochID, "binding"),
        packageSchemaVersion: enumString(source.packageSchemaVersion, ["room-scan-project-v1", "room-scan-project-v2"] as const, "binding"),
        projectID: identifier(source.projectID, "binding"),
        revisionID: identifier(source.revisionID, "binding"),
        revisionManifestSHA256: digest(source.revisionManifestSHA256, "binding"),
        semanticSHA256: digest(source.semanticSHA256, "binding"),
      }),
    });
  });
  return Object.freeze(result);
}

function parseApproval(value: unknown, sourceBindingsSHA256: string, selectionManifestSHA256: string, expectedApproval: string): { readonly approvalSHA256: string } {
  const approval = object(value, "approval");
  exactKeys(approval, ["decision", "reviewID", "reviewedAt", "selectionManifestSHA256", "sourceBindingsSHA256"], "approval");
  if (
    approval.decision !== "approved" || !isCanonicalTimestamp(approval.reviewedAt) ||
    identifier(approval.reviewID, "approval") === "" ||
    digest(approval.sourceBindingsSHA256, "approval") !== sourceBindingsSHA256 ||
    digest(approval.selectionManifestSHA256, "approval") !== selectionManifestSHA256
  ) throw invalid("approval");
  const approvalSHA256 = canonicalJsonSHA256(approval);
  if (approvalSHA256 !== expectedApproval) throw invalid("approval");
  return Object.freeze({ approvalSHA256 });
}

function parseLedger(value: unknown, sourceBindings: readonly ValidatedPublicationSourceBinding[]): {
  readonly assets: readonly ValidatedPublicationAsset[];
  readonly aiBindings: ReadonlyMap<string, AIReadyPackageBinding>;
  readonly rawAssets: readonly unknown[];
} {
  const rawAssets = array(value, "asset");
  if (rawAssets.length < 1 || rawAssets.length > 256) throw invalid("asset");
  const sourceRoomKeys = new Set(sourceBindings.map((binding) => binding.publicRoomKey));
  const ids = new Set<string>(); const paths = new Set<string>(); const aiBindings = new Map<string, AIReadyPackageBinding>();
  const assets = rawAssets.map((candidate) => {
    const root = object(candidate, "asset");
    exactKeys(root, ["assetClass", "assetID", "byteCount", "mediaType", "relativePath", "sha256"], "asset", ["publicRoomKey", "aiReadyPackageBinding"]);
    const assetID = identifier(root.assetID, "asset");
    const assetClass = enumString(root.assetClass, ["webGeometry", "webTexture", "selectedImage", "floorPlan", "approvedConcept", "brandingLogo", "aiReadyPackage"] as const, "asset");
    const relativePath = publicationAssetPath(root.relativePath, assetID, assetClass, "asset");
    const mediaType = media(root.mediaType, "asset");
    const byteCount = boundedInteger(root.byteCount, 1, assetClass === "aiReadyPackage" ? PUBLICATION_MAX_NESTED_AI_READY_BYTES : PUBLICATION_MAX_ASSET_BYTES, "asset");
    const sha256 = digest(root.sha256, "asset");
    const publicRoomKey = root.publicRoomKey === undefined ? undefined : identifier(root.publicRoomKey, "asset");
    if (ids.has(assetID) || paths.has(relativePath)) throw invalid("asset");
    ids.add(assetID); paths.add(relativePath);
    const roomScoped = assetClass !== "brandingLogo";
    if (roomScoped !== (publicRoomKey !== undefined) || (publicRoomKey !== undefined && !sourceRoomKeys.has(publicRoomKey))) throw invalid("asset");
    if (!assetClassMediaMatches(assetClass, mediaType)) throw invalid("asset");
    if (assetClass === "aiReadyPackage") {
      const binding = parseAIReadyBinding(root.aiReadyPackageBinding, publicRoomKey, "asset");
      aiBindings.set(assetID, binding);
    } else if (root.aiReadyPackageBinding !== undefined) {
      throw invalid("asset");
    }
    return Object.freeze({
      assetID, ...(publicRoomKey === undefined ? {} : { publicRoomKey }), assetClass,
      relativePath, sha256, byteCount, mediaType,
    });
  });
  if (assets.some((asset, index) => index > 0 && assets[index - 1]!.assetID.localeCompare(asset.assetID) >= 0)) throw invalid("asset");
  return Object.freeze({ assets: Object.freeze(assets), aiBindings, rawAssets: Object.freeze([...rawAssets]) });
}

function parseAIReadyBinding(value: unknown, publicRoomKey: string | undefined, code: PublicationArchiveValidationCode): AIReadyPackageBinding {
  if (publicRoomKey === undefined) throw invalid(code);
  const root = object(value, code);
  exactKeys(root, ["artifactPlanSHA256", "manifestSHA256", "packageID", "publicRoomKey", "selectionSHA256"], code);
  const binding = Object.freeze({
    packageID: identifier(root.packageID, code),
    publicRoomKey: identifier(root.publicRoomKey, code),
    manifestSHA256: digest(root.manifestSHA256, code),
    artifactPlanSHA256: digest(root.artifactPlanSHA256, code),
    selectionSHA256: digest(root.selectionSHA256, code),
  });
  if (binding.publicRoomKey !== publicRoomKey) throw invalid(code);
  return binding;
}

function validatePresentation(bytes: Uint8Array, manifest: PublicationManifest): Readonly<{ readonly downloads: ValidatedPublicationDownloads; readonly independentRoomKeys: readonly string[] }> {
  const root = object(strict(bytes, "presentation"), "presentation");
  assertNoForbiddenPresentationKeys(root);
  const expectedKeys = manifest.snapshotKind === "room"
    ? ["branding", "contractKind", "downloads", "room", "schemaVersion", "title"]
    : ["branding", "contractKind", "downloads", "independentRoomNotice", "propertyTitle", "rooms", "schemaVersion"];
  exactKeys(root, expectedKeys, "presentation");
  if (
    root.contractKind !== (manifest.snapshotKind === "room" ? "publishedRoomSnapshot" : "publishedPropertySnapshot") ||
    root.schemaVersion !== (manifest.snapshotKind === "room" ? "roomscan-published-room-snapshot-v2" : "roomscan-published-property-snapshot-v1")
  ) throw invalid("presentation");
  text(root[manifest.snapshotKind === "room" ? "title" : "propertyTitle"], 1, 180, "presentation");
  validateBranding(root.branding, manifest.assets);
  const downloads = validateDownloads(root.downloads, manifest.assets);
  const roomValues = manifest.snapshotKind === "room" ? [root.room] : array(root.rooms, "presentation");
  if ((manifest.snapshotKind === "room" && roomValues.length !== 1) || (manifest.snapshotKind === "property" && roomValues.length < 2)) throw invalid("presentation");
  if (manifest.snapshotKind === "property" && root.independentRoomNotice !== "Rooms are presented independently; they do not share coordinates, alignment, connectivity, or reconstruction.") throw invalid("presentation");
  const keys = roomValues.map((room) => validatePublicRoom(room, manifest.assets));
  if (new Set(keys).size !== keys.length || keys.join("\u0000") !== manifest.sourceBindings.map((binding) => binding.publicRoomKey).join("\u0000")) throw invalid("presentation");
  return Object.freeze({ downloads, independentRoomKeys: Object.freeze(keys) });
}

function validateBranding(value: unknown, assets: readonly ValidatedPublicationAsset[]): void {
  const root = object(value, "presentation");
  exactKeys(root, ["accent", "businessName", "contact"], "presentation", ["logoAssetID"]);
  text(root.businessName, 1, 120, "presentation");
  enumString(root.accent, ["blueprint", "forest", "slate", "terracotta"] as const, "presentation");
  const contact = object(root.contact, "presentation");
  exactKeys(contact, [], "presentation", ["phone", "website"]);
  if (typeof contact.phone !== "string" && typeof contact.website !== "string") throw invalid("presentation");
  if (contact.phone !== undefined) text(contact.phone, 1, 80, "presentation");
  if (contact.website !== undefined && (typeof contact.website !== "string" || !/^https:\/\/[A-Za-z0-9.-]+(?:\/[^\s]*)?$/u.test(contact.website) || contact.website.length > 2_048)) throw invalid("presentation");
  if (root.logoAssetID !== undefined && !assetMatches(assets, identifier(root.logoAssetID, "presentation"), "brandingLogo")) throw invalid("presentation");
}

function validateDownloads(value: unknown, assets: readonly ValidatedPublicationAsset[]): ValidatedPublicationDownloads {
  const root = object(value, "presentation");
  exactKeys(root, ["floorPlanPDF", "galleryZIP"], "presentation", ["aiReadyPackageAssetID"]);
  if (typeof root.floorPlanPDF !== "boolean" || typeof root.galleryZIP !== "boolean") throw invalid("presentation");
  const aiReadyPackageAssetID = root.aiReadyPackageAssetID === undefined ? undefined : identifier(root.aiReadyPackageAssetID, "presentation");
  if (aiReadyPackageAssetID !== undefined && !assetMatches(assets, aiReadyPackageAssetID, "aiReadyPackage")) throw invalid("presentation");
  return Object.freeze({ floorPlanPDF: root.floorPlanPDF, galleryZIP: root.galleryZIP, ...(aiReadyPackageAssetID === undefined ? {} : { aiReadyPackageAssetID }) });
}

function validatePublicRoom(value: unknown, assets: readonly ValidatedPublicationAsset[]): string {
  const root = object(value, "presentation");
  exactKeys(root, ["assets", "comparisons", "dimensions", "displayName", "orientation", "qualityWarnings", "roomKey", "semanticLayout"], "presentation");
  const roomKey = identifier(root.roomKey, "presentation");
  text(root.displayName, 1, 120, "presentation");
  const semantic = object(root.semanticLayout, "presentation"); exactKeys(semantic, ["elements"], "presentation");
  const elements = array(semantic.elements, "presentation"); if (elements.length < 1 || elements.length > 256) throw invalid("presentation");
  for (const element of elements) validateSemanticElement(element);
  const orientation = object(root.orientation, "presentation"); exactKeys(orientation, ["initialView"], "presentation"); enumString(orientation.initialView, ["entry", "wall", "corner", "topDown"] as const, "presentation");
  const dimensions = array(root.dimensions, "presentation"); if (dimensions.length < 1 || dimensions.length > 32) throw invalid("presentation");
  for (const dimension of dimensions) { const item = object(dimension, "presentation"); exactKeys(item, ["label", "meters"], "presentation"); text(item.label, 1, 80, "presentation"); finite(item.meters, 0.001, 1_000, "presentation"); }
  const warnings = array(root.qualityWarnings, "presentation"); if (warnings.length > 32) throw invalid("presentation"); const warningCodes = new Set<string>();
  for (const warning of warnings) { const item = object(warning, "presentation"); exactKeys(item, ["code", "message", "severity"], "presentation"); const code = identifier(item.code, "presentation"); if (warningCodes.has(code)) throw invalid("presentation"); warningCodes.add(code); text(item.message, 1, 500, "presentation"); enumString(item.severity, ["advisory", "reviewRecommended", "insufficientEvidence"] as const, "presentation"); }
  const roomAssets = object(root.assets, "presentation"); exactKeys(roomAssets, ["approvedConceptAssetIDs", "floorPlanAssetID", "selectedImageAssetIDs", "webGeometryAssetID", "webTextureAssetIDs"], "presentation");
  requireRoomAsset(assets, identifier(roomAssets.webGeometryAssetID, "presentation"), "webGeometry", roomKey);
  requireRoomAsset(assets, identifier(roomAssets.floorPlanAssetID, "presentation"), "floorPlan", roomKey);
  for (const id of boundedIdentifierArray(roomAssets.selectedImageAssetIDs, 0, 64, "presentation")) requireRoomAsset(assets, id, "selectedImage", roomKey);
  for (const id of boundedIdentifierArray(roomAssets.webTextureAssetIDs, 0, 64, "presentation")) requireRoomAsset(assets, id, "webTexture", roomKey);
  for (const id of boundedIdentifierArray(roomAssets.approvedConceptAssetIDs, 0, 64, "presentation")) requireRoomAsset(assets, id, "approvedConcept", roomKey);
  const comparisons = array(root.comparisons, "presentation"); if (comparisons.length > 32) throw invalid("presentation");
  for (const comparison of comparisons) { const item = object(comparison, "presentation"); exactKeys(item, ["conceptAssetID", "disclaimer", "label", "originalAssetID"], "presentation"); requireRoomAsset(assets, identifier(item.originalAssetID, "presentation"), "selectedImage", roomKey); requireRoomAsset(assets, identifier(item.conceptAssetID, "presentation"), "approvedConcept", roomKey); text(item.label, 1, 120, "presentation"); text(item.disclaimer, 1, 500, "presentation"); }
  return roomKey;
}

function validateSemanticElement(value: unknown): void {
  const root = object(value, "presentation"); exactKeys(root, ["height", "kind", "label", "width", "x", "y"], "presentation");
  enumString(root.kind, ["wall", "door", "window", "opening", "floor", "fixedObject", "movableObject"] as const, "presentation"); text(root.label, 1, 120, "presentation");
  const x = finite(root.x, 0, 1, "presentation"); const y = finite(root.y, 0, 1, "presentation"); const width = finite(root.width, 0.0001, 1, "presentation"); const height = finite(root.height, 0.0001, 1, "presentation");
  if (x + width > 1.000_001 || y + height > 1.000_001) throw invalid("presentation");
}

async function validateAsset(reader: PublicationArchiveReader, entry: ZipEntry, asset: ValidatedPublicationAsset, aiBinding: AIReadyPackageBinding | undefined, sourceBindings: readonly ValidatedPublicationSourceBinding[]): Promise<void> {
  if (entry.byteCount !== asset.byteCount || await digestEntry(reader, entry, "asset") !== asset.sha256) throw invalid("asset");
  if (asset.assetClass === "webGeometry") {
    validateGeometry(await readEntry(reader, entry, PUBLICATION_MAX_PRESENTATION_BYTES, "geometry"));
  } else if (asset.assetClass === "aiReadyPackage") {
    if (aiBinding === undefined) throw invalid("ai_package");
    await validateAIReadyPackage(subReader(reader, entry.dataOffset, entry.byteCount), aiBinding, sourceBindings);
  } else if (asset.mediaType === "image/png") {
    await validatePublishedPNG(await readEntry(reader, entry, PUBLICATION_MAX_ASSET_BYTES, "media"));
  } else if (asset.mediaType === "image/jpeg") {
    validatePublishedJPEG(await readEntry(reader, entry, PUBLICATION_MAX_ASSET_BYTES, "media"));
  } else {
    throw invalid("asset");
  }
}

function validateGeometry(bytes: Uint8Array): void {
  const root = object(strict(bytes, "geometry"), "geometry"); exactKeys(root, ["triangles", "vertices"], "geometry");
  const vertices = array(root.vertices, "geometry"); const triangles = array(root.triangles, "geometry");
  if (vertices.length < 3 || vertices.length > 250_000 || triangles.length < 1 || triangles.length > 500_000) throw invalid("geometry");
  for (const vertex of vertices) { const item = object(vertex, "geometry"); exactKeys(item, ["x", "y", "z"], "geometry"); finite(item.x, -1_000, 1_000, "geometry"); finite(item.y, -1_000, 1_000, "geometry"); finite(item.z, -1_000, 1_000, "geometry"); }
  for (const triangle of triangles) { const item = object(triangle, "geometry"); exactKeys(item, ["a", "b", "c"], "geometry"); const a = boundedInteger(item.a, 0, vertices.length - 1, "geometry"); const b = boundedInteger(item.b, 0, vertices.length - 1, "geometry"); const c = boundedInteger(item.c, 0, vertices.length - 1, "geometry"); if (a === b || a === c || b === c) throw invalid("geometry"); }
}

/** This closed structural profile is intentionally strict (only IHDR, IDAT,
 * IEND). A full bounded inflate is added below the archive closure rather than
 * trusting any image metadata or browser decoder. */
export async function validatePublishedPNG(bytes: Uint8Array): Promise<void> {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.byteLength < signature.length + 12 || signature.some((value, index) => bytes[index] !== value)) throw invalid("media");
  let offset = 8; let sawHeader = false; let sawIDAT = false; let sawEnd = false;
  let width = 0; let height = 0; let bitDepth = 0; let colorType = 0; let interlace = 0; const idat: Uint8Array[] = [];
  while (offset < bytes.byteLength) {
    if (offset + 12 > bytes.byteLength || sawEnd) throw invalid("media");
    const size = be32(bytes, offset); const start = offset + 8; const end = start + size;
    if (end + 4 > bytes.byteLength) throw invalid("media");
    const type = ascii(bytes.subarray(offset + 4, offset + 8), "media");
    const payload = bytes.subarray(start, end);
    if (be32(bytes, end) !== crc32Parts([bytes.subarray(offset + 4, offset + 8), payload])) throw invalid("media");
    if (!sawHeader) {
      if (type !== "IHDR" || size !== 13) throw invalid("media");
      width = be32(payload, 0); height = be32(payload, 4); bitDepth = payload[8] ?? 0; colorType = payload[9] ?? -1; interlace = payload[12] ?? -1;
      if (width < 1 || height < 1 || width > 8_192 || height > 8_192 || width * height > 24_000_000 || !validPNGDepthColor(bitDepth, colorType) || payload[10] !== 0 || payload[11] !== 0 || ![0, 1].includes(interlace)) throw invalid("media");
      sawHeader = true;
    } else if (type === "IDAT" && !sawEnd) {
      if (size === 0) throw invalid("media"); sawIDAT = true; idat.push(payload);
    } else if (type === "IEND") {
      if (!sawIDAT || size !== 0 || end + 4 !== bytes.byteLength) throw invalid("media"); sawEnd = true;
    } else {
      throw invalid("media");
    }
    offset = end + 4;
  }
  if (!sawHeader || !sawIDAT || !sawEnd) throw invalid("media");
  const decoder = new PNGFilterDecoder(width, height, bitDepth, colorType, interlace);
  await inflatePNG(idat, decoder);
  decoder.finish();
}

async function inflatePNG(parts: readonly Uint8Array[], decoder: PNGFilterDecoder): Promise<void> {
  const compressedBytes = parts.reduce((total, part) => total + part.byteLength, 0);
  const inflater = createInflate({ maxOutputLength: decoder.expectedByteCount });
  await new Promise<void>((resolve, reject) => {
    let failed = false;
    const fail = (error: unknown): void => {
      if (!failed) { failed = true; inflater.destroy(error instanceof Error ? error : new Error("invalid PNG inflate")); }
    };
    inflater.on("data", (chunk: Uint8Array) => { try { decoder.write(chunk); } catch (error) { fail(error); } });
    inflater.once("error", () => reject(new PublicationArchiveValidationError("media")));
    inflater.once("end", () => {
      const consumed = (inflater as unknown as { readonly bytesWritten?: unknown }).bytesWritten;
      if (failed || consumed !== compressedBytes) { reject(new PublicationArchiveValidationError("media")); return; }
      resolve();
    });
    for (const part of parts) inflater.write(part);
    inflater.end();
  });
}

class PNGFilterDecoder {
  readonly expectedByteCount: number;
  private readonly passes: readonly { readonly width: number; readonly height: number; readonly rowByteCount: number }[];
  private passIndex = 0;
  private rowIndex = 0;
  private rowOffset = 0;
  private received = 0;
  private row: Uint8Array;
  private previous: Uint8Array;
  private current: Uint8Array;

  constructor(width: number, height: number, bitDepth: number, colorType: number, interlace: number) {
    const channels = colorType === 0 ? 1 : colorType === 2 ? 3 : colorType === 4 ? 2 : 4;
    const bitsPerPixel = channels * bitDepth;
    const passes = interlace === 0
      ? [{ width, height }]
      : [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]].map(([x, y, dx, dy]) => ({ width: passExtent(width, x!, dx!), height: passExtent(height, y!, dy!) }));
    this.passes = Object.freeze(passes.filter((pass) => pass.width > 0 && pass.height > 0).map((pass) => Object.freeze({ ...pass, rowByteCount: Math.ceil(pass.width * bitsPerPixel / 8) })));
    this.expectedByteCount = this.passes.reduce((total, pass) => {
      const bytes = (pass.rowByteCount + 1) * pass.height;
      if (!Number.isSafeInteger(bytes) || total > Number.MAX_SAFE_INTEGER - bytes) throw invalid("media");
      return total + bytes;
    }, 0);
    if (this.expectedByteCount < 1 || this.expectedByteCount > 201_326_592) throw invalid("media");
    const initial = this.passes[0];
    if (initial === undefined) throw invalid("media");
    this.row = new Uint8Array(initial.rowByteCount + 1); this.previous = new Uint8Array(initial.rowByteCount); this.current = new Uint8Array(initial.rowByteCount);
    this.bytesPerPixel = Math.max(1, Math.ceil(bitsPerPixel / 8));
  }

  private readonly bytesPerPixel: number;

  write(chunk: Uint8Array): void {
    for (const byte of chunk) {
      if (this.received >= this.expectedByteCount) throw invalid("media");
      this.row[this.rowOffset++] = byte; this.received += 1;
      if (this.rowOffset === this.row.byteLength) this.decodeRow();
    }
  }

  finish(): void {
    if (this.received !== this.expectedByteCount || this.passIndex !== this.passes.length || this.rowOffset !== 0) throw invalid("media");
  }

  private decodeRow(): void {
    const filter = this.row[0]; if (filter === undefined || filter > 4) throw invalid("media");
    for (let index = 0; index < this.current.byteLength; index += 1) {
      const raw = this.row[index + 1] ?? 0; const left = index >= this.bytesPerPixel ? this.current[index - this.bytesPerPixel] ?? 0 : 0; const up = this.previous[index] ?? 0; const upLeft = index >= this.bytesPerPixel ? this.previous[index - this.bytesPerPixel] ?? 0 : 0;
      this.current[index] = filter === 0 ? raw : filter === 1 ? (raw + left) & 0xff : filter === 2 ? (raw + up) & 0xff : filter === 3 ? (raw + Math.floor((left + up) / 2)) & 0xff : (raw + paeth(left, up, upLeft)) & 0xff;
    }
    const previous = this.previous; this.previous = this.current; this.current = previous; this.current.fill(0); this.rowOffset = 0; this.rowIndex += 1;
    const pass = this.passes[this.passIndex];
    if (pass === undefined) throw invalid("media");
    if (this.rowIndex === pass.height) {
      this.passIndex += 1; this.rowIndex = 0;
      const next = this.passes[this.passIndex];
      if (next !== undefined) { this.row = new Uint8Array(next.rowByteCount + 1); this.previous = new Uint8Array(next.rowByteCount); this.current = new Uint8Array(next.rowByteCount); }
    }
  }
}

function validPNGDepthColor(depth: number, color: number): boolean { return (color === 0 && [1, 2, 4, 8, 16].includes(depth)) || ((color === 2 || color === 4 || color === 6) && (depth === 8 || depth === 16)); }
function passExtent(total: number, start: number, stride: number): number { return total <= start ? 0 : Math.floor((total - start - 1) / stride) + 1; }
function paeth(left: number, up: number, upLeft: number): number { const prediction = left + up - upLeft; const leftDistance = Math.abs(prediction - left); const upDistance = Math.abs(prediction - up); const diagonalDistance = Math.abs(prediction - upLeft); return leftDistance <= upDistance && leftDistance <= diagonalDistance ? left : upDistance <= diagonalDistance ? up : upLeft; }

/** Fully decodes baseline DCT entropy coefficients, while deliberately
 * discarding the coefficient surface. This rejects private JPEG carriers that
 * marker/EOI scanners cannot see: malformed Huffman tables, truncated scans,
 * invalid stuffing/padding/restarts, extra MCUs, and post-EOI data. */
export function validatePublishedJPEG(bytes: Uint8Array): void {
  if (bytes.byteLength < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) throw invalid("media");
  let offset = 2;
  const quantization = new Map<number, Uint8Array>();
  const huffman = new Map<string, JPEGHuffmanTable>();
  let frame: JPEGFrame | undefined;
  let restartInterval: number | undefined;
  while (offset < bytes.byteLength) {
    const marker = readJPEGMarker(bytes, offset); offset = marker.nextOffset;
    if (marker.value === 0xd9) throw invalid("media");
    if (![0xdb, 0xc4, 0xc0, 0xdd, 0xda].includes(marker.value)) throw invalid("media");
    if (offset + 2 > bytes.byteLength) throw invalid("media");
    const length = be16(bytes, offset); const payloadStart = offset + 2; const payloadEnd = offset + length;
    if (length < 2 || payloadEnd > bytes.byteLength) throw invalid("media");
    const payload = bytes.subarray(payloadStart, payloadEnd); offset = payloadEnd;
    switch (marker.value) {
    case 0xdb:
      parseJPEGQuantization(payload, quantization); break;
    case 0xc4:
      parseJPEGHuffman(payload, huffman); break;
    case 0xc0:
      if (frame !== undefined) throw invalid("media");
      frame = parseJPEGFrame(payload); break;
    case 0xdd:
      if (restartInterval !== undefined || payload.byteLength !== 2) throw invalid("media");
      restartInterval = be16(payload, 0); break;
    case 0xda: {
      if (frame === undefined) throw invalid("media");
      if (frame.components.some((component) => !quantization.has(component.quantizationID))) throw invalid("media");
      const scan = parseJPEGScan(payload, frame, huffman);
      decodeJPEGEntropy(bytes, offset, frame, scan, restartInterval ?? 0, huffman);
      return;
    }
    }
  }
  throw invalid("media");
}

interface JPEGHuffmanTable { readonly symbols: ReadonlyMap<number, number>; }
interface JPEGComponent { readonly id: number; readonly horizontal: number; readonly vertical: number; readonly quantizationID: number; }
interface JPEGFrame { readonly width: number; readonly height: number; readonly components: readonly JPEGComponent[]; readonly maximumHorizontal: number; readonly maximumVertical: number; }
interface JPEGScanComponent { readonly component: JPEGComponent; readonly dcTableID: number; readonly acTableID: number; }

function readJPEGMarker(bytes: Uint8Array, offset: number): { readonly value: number; readonly nextOffset: number } {
  if (bytes[offset] !== 0xff) throw invalid("media");
  do { offset += 1; } while (bytes[offset] === 0xff);
  const value = bytes[offset];
  if (value === undefined || value === 0x00 || value === 0xff || value === 0x01 || value === 0xd8 || (value >= 0xd0 && value <= 0xd7)) throw invalid("media");
  return Object.freeze({ value, nextOffset: offset + 1 });
}

function parseJPEGQuantization(payload: Uint8Array, tables: Map<number, Uint8Array>): void {
  let offset = 0;
  while (offset < payload.byteLength) {
    const selector = payload[offset++]; if (selector === undefined || selector >>> 4 !== 0 || (selector & 0x0f) > 3 || offset + 64 > payload.byteLength) throw invalid("media");
    const id = selector & 0x0f; if (tables.has(id)) throw invalid("media");
    const values = Uint8Array.from(payload.subarray(offset, offset + 64)); if (values.some((value) => value === 0)) throw invalid("media");
    tables.set(id, values); offset += 64;
  }
  if (offset !== payload.byteLength) throw invalid("media");
}

function parseJPEGHuffman(payload: Uint8Array, tables: Map<string, JPEGHuffmanTable>): void {
  let offset = 0;
  while (offset < payload.byteLength) {
    const selector = payload[offset++]; if (selector === undefined || selector >>> 4 > 1 || (selector & 0x0f) > 3 || offset + 16 > payload.byteLength) throw invalid("media");
    const tableClass = selector >>> 4; const tableID = selector & 0x0f; const key = `${tableClass}:${tableID}`;
    if (tables.has(key)) throw invalid("media");
    const counts = payload.subarray(offset, offset + 16); offset += 16;
    const count = counts.reduce((total, value) => total + value, 0);
    if (count < 1 || count > 256 || offset + count > payload.byteLength) throw invalid("media");
    const values = payload.subarray(offset, offset + count); offset += count;
    const symbols = new Map<number, number>(); let code = 0; let valueIndex = 0;
    for (let bitLength = 1; bitLength <= 16; bitLength += 1) {
      code <<= 1; const countAtLength = counts[bitLength - 1] ?? 0;
      if (code + countAtLength > 1 << bitLength) throw invalid("media");
      for (let index = 0; index < countAtLength; index += 1) {
        const value = values[valueIndex++]; if (value === undefined || !validJPEGHuffmanSymbol(tableClass, value)) throw invalid("media");
        symbols.set((bitLength << 16) | code, value); code += 1;
      }
    }
    if (valueIndex !== values.byteLength) throw invalid("media");
    tables.set(key, Object.freeze({ symbols }));
  }
  if (offset !== payload.byteLength) throw invalid("media");
}

function validJPEGHuffmanSymbol(tableClass: number, value: number): boolean {
  if (tableClass === 0) return value <= 11;
  const run = value >>> 4; const size = value & 0x0f;
  return value === 0 || value === 0xf0 || (run <= 15 && size >= 1 && size <= 10);
}

function parseJPEGFrame(payload: Uint8Array): JPEGFrame {
  if (payload.byteLength < 6 || payload[0] !== 8) throw invalid("media");
  const height = be16(payload, 1); const width = be16(payload, 3); const count = payload[5];
  if (height < 1 || width < 1 || width > 8_192 || height > 8_192 || width * height > 24_000_000 || (count !== 1 && count !== 3) || payload.byteLength !== 6 + 3 * count) throw invalid("media");
  const ids = new Set<number>(); const components: JPEGComponent[] = [];
  for (let index = 0; index < count; index += 1) {
    const start = 6 + 3 * index; const id = payload[start]; const sampling = payload[start + 1]; const quantizationID = payload[start + 2];
    if (id === undefined || sampling === undefined || quantizationID === undefined || id === 0 || ids.has(id) || quantizationID > 3) throw invalid("media");
    const horizontal = sampling >>> 4; const vertical = sampling & 0x0f;
    if (horizontal < 1 || horizontal > 2 || vertical < 1 || vertical > 2) throw invalid("media");
    ids.add(id); components.push(Object.freeze({ id, horizontal, vertical, quantizationID }));
  }
  const maximumHorizontal = Math.max(...components.map((component) => component.horizontal)); const maximumVertical = Math.max(...components.map((component) => component.vertical));
  const allOne = components.every((component) => component.horizontal === 1 && component.vertical === 1);
  const fourTwoZero = components.length === 3 && components[0]?.horizontal === 2 && components[0]?.vertical === 2 && components.slice(1).every((component) => component.horizontal === 1 && component.vertical === 1);
  if (!(components.length === 1 && allOne) && !allOne && !fourTwoZero) throw invalid("media");
  return Object.freeze({ width, height, components: Object.freeze(components), maximumHorizontal, maximumVertical });
}

function parseJPEGScan(payload: Uint8Array, frame: JPEGFrame, huffman: ReadonlyMap<string, JPEGHuffmanTable>): readonly JPEGScanComponent[] {
  const count = payload[0];
  if ((count !== 1 && count !== 3) || count !== frame.components.length || payload.byteLength !== 4 + 2 * count || payload[payload.byteLength - 3] !== 0 || payload[payload.byteLength - 2] !== 63 || payload[payload.byteLength - 1] !== 0) throw invalid("media");
  const seen = new Set<number>(); const components: JPEGScanComponent[] = [];
  for (let index = 0; index < count; index += 1) {
    const id = payload[1 + 2 * index]; const selectors = payload[2 + 2 * index]; const component = frame.components.find((candidate) => candidate.id === id);
    if (id === undefined || selectors === undefined || component === undefined || seen.has(id) || selectors >>> 4 > 3 || (selectors & 0x0f) > 3) throw invalid("media");
    const dcTableID = selectors >>> 4; const acTableID = selectors & 0x0f;
    if (!huffman.has(`0:${dcTableID}`) || !huffman.has(`1:${acTableID}`)) throw invalid("media");
    seen.add(id); components.push(Object.freeze({ component, dcTableID, acTableID }));
  }
  return Object.freeze(components);
}

function decodeJPEGEntropy(bytes: Uint8Array, offset: number, frame: JPEGFrame, scan: readonly JPEGScanComponent[], restartInterval: number, huffman: ReadonlyMap<string, JPEGHuffmanTable>): void {
  const reader = new JPEGEntropyReader(bytes, offset); const predictors = new Map<number, number>();
  const columns = Math.ceil(frame.width / (frame.maximumHorizontal * 8)); const rows = Math.ceil(frame.height / (frame.maximumVertical * 8));
  const mcuCount = columns * rows; if (!Number.isSafeInteger(mcuCount) || mcuCount < 1 || mcuCount > 24_000_000) throw invalid("media");
  let restartIndex = 0;
  for (let mcu = 0; mcu < mcuCount; mcu += 1) {
    if (restartInterval > 0 && mcu > 0 && mcu % restartInterval === 0) { reader.expectRestart(0xd0 + (restartIndex & 7)); restartIndex += 1; predictors.clear(); }
    for (const scanned of scan) {
      const dcTable = huffman.get(`0:${scanned.dcTableID}`); const acTable = huffman.get(`1:${scanned.acTableID}`);
      if (dcTable === undefined || acTable === undefined) throw invalid("media");
      for (let vertical = 0; vertical < scanned.component.vertical; vertical += 1) for (let horizontal = 0; horizontal < scanned.component.horizontal; horizontal += 1) decodeJPEGBlock(reader, dcTable, acTable, predictors, scanned.component.id);
    }
  }
  reader.expectEOI();
}

function decodeJPEGBlock(reader: JPEGEntropyReader, dcTable: JPEGHuffmanTable, acTable: JPEGHuffmanTable, predictors: Map<number, number>, componentID: number): void {
  const category = decodeJPEGHuffman(reader, dcTable); if (category > 11) throw invalid("media");
  const difference = receiveExtend(reader.readBits(category), category); const next = (predictors.get(componentID) ?? 0) + difference;
  if (next < -2_048 || next > 2_047) throw invalid("media"); predictors.set(componentID, next);
  let coefficient = 1;
  while (coefficient < 64) {
    const symbol = decodeJPEGHuffman(reader, acTable);
    if (symbol === 0) return;
    if (symbol === 0xf0) { coefficient += 16; if (coefficient > 64) throw invalid("media"); continue; }
    const run = symbol >>> 4; const size = symbol & 0x0f;
    if (size < 1 || size > 10 || coefficient + run >= 64) throw invalid("media");
    coefficient += run; receiveExtend(reader.readBits(size), size); coefficient += 1;
  }
}

function decodeJPEGHuffman(reader: JPEGEntropyReader, table: JPEGHuffmanTable): number {
  let code = 0;
  for (let length = 1; length <= 16; length += 1) { code = (code << 1) | reader.readBit(); const symbol = table.symbols.get((length << 16) | code); if (symbol !== undefined) return symbol; }
  throw invalid("media");
}

function receiveExtend(value: number, size: number): number { if (size === 0) return 0; return value < 1 << (size - 1) ? value - ((1 << size) - 1) : value; }

class JPEGEntropyReader {
  private offset: number;
  private current = 0;
  private remaining = 0;

  constructor(private readonly bytes: Uint8Array, offset: number) { this.offset = offset; }

  readBit(): number {
    if (this.remaining === 0) { this.current = this.nextDataByte(); this.remaining = 8; }
    this.remaining -= 1; return (this.current >>> this.remaining) & 1;
  }
  readBits(count: number): number { let value = 0; for (let index = 0; index < count; index += 1) value = (value << 1) | this.readBit(); return value; }
  expectRestart(expected: number): void { this.align(); if (this.readMarker() !== expected) throw invalid("media"); }
  expectEOI(): void { this.align(); if (this.readMarker() !== 0xd9 || this.offset !== this.bytes.byteLength) throw invalid("media"); }

  private align(): void { if (this.remaining > 0 && (this.current & ((1 << this.remaining) - 1)) !== (1 << this.remaining) - 1) throw invalid("media"); this.remaining = 0; }
  private nextDataByte(): number {
    const byte = this.bytes[this.offset++]; if (byte === undefined) throw invalid("media");
    if (byte !== 0xff) return byte;
    const escaped = this.bytes[this.offset]; if (escaped === 0x00) { this.offset += 1; return 0xff; }
    throw invalid("media");
  }
  private readMarker(): number {
    if (this.bytes[this.offset] !== 0xff) throw invalid("media");
    do { this.offset += 1; } while (this.bytes[this.offset] === 0xff);
    const marker = this.bytes[this.offset++]; if (marker === undefined || marker === 0x00) throw invalid("media"); return marker;
  }
}

export async function validateAIReadyPackage(reader: PublicationArchiveReader, binding: AIReadyPackageBinding, sourceBindings: readonly ValidatedPublicationSourceBinding[]): Promise<void> {
  assertReader(reader, PUBLICATION_MAX_NESTED_AI_READY_BYTES, "ai_package");
  const entries = await parseStoreZip(reader, "ai_package"); const byPath = mapEntries(entries, "ai_package");
  const manifestEntry = requireEntry(byPath, "manifest.json", "ai_package");
  const manifestBytes = await readEntry(reader, manifestEntry, PUBLICATION_MAX_PRESENTATION_BYTES, "ai_package");
  if (sha256Bytes(manifestBytes) !== binding.manifestSHA256) throw invalid("ai_package");
  const root = object(strict(manifestBytes, "ai_package"), "ai_package");
  exactKeys(root, ["artifactPlan", "artifactPlanSHA256", "artifacts", "contractKind", "disclosureReview", "packageID", "profile", "schemaVersion", "selectionSHA256", "sourceRevision"], "ai_package");
  if (root.schemaVersion !== "roomscan-ai-room-package-v1" || root.contractKind !== "aiRoomPackage" || root.profile !== "aiReady" || root.packageID !== binding.packageID || digest(root.artifactPlanSHA256, "ai_package") !== binding.artifactPlanSHA256 || digest(root.selectionSHA256, "ai_package") !== binding.selectionSHA256) throw invalid("ai_package");
  const source = sourceBindings.find((candidate) => candidate.publicRoomKey === binding.publicRoomKey)?.sourceRevision;
  if (source === undefined || canonicalJsonSHA256(root.sourceRevision) !== canonicalJsonSHA256(source)) throw invalid("ai_package");
  const artifactPlan = parseAIReadyPlan(array(root.artifactPlan, "ai_package"));
  if (canonicalJsonSHA256({ schemaVersion: "roomscan-ai-room-package-v1", contractKind: "aiRoomPackage", profile: "aiReady", sourceRevision: root.sourceRevision, slots: artifactPlan.map((slot) => ({ artifactClass: slot.artifactClass, artifactID: slot.artifactID })) }) !== binding.artifactPlanSHA256) throw invalid("ai_package");
  const rawArtifacts = array(root.artifacts, "ai_package"); if (rawArtifacts.length < 1 || rawArtifacts.length > 256 || canonicalJsonSHA256(rawArtifacts) !== binding.selectionSHA256) throw invalid("ai_package");
  const artifacts = parseAIReadyArtifacts(rawArtifacts, artifactPlan);
  validateAIReadyDisclosure(root.disclosureReview, source, binding);
  const expectedPaths = new Set<string>(["manifest.json"]);
  for (const artifact of artifacts) {
    if (artifact.disposition === "included") {
      const entry = requireEntry(byPath, artifact.relativePath!, "ai_package");
      if (expectedPaths.has(artifact.relativePath!) || entry.byteCount !== artifact.byteCount || await digestEntry(reader, entry, "ai_package") !== artifact.sha256) throw invalid("ai_package");
      expectedPaths.add(artifact.relativePath!);
    }
  }
  validateAIReadyIncludedCounts(artifacts);
  if (expectedPaths.size !== entries.length || entries.some((entry) => !expectedPaths.has(entry.path))) throw invalid("ai_package");
}

type AIReadyArtifactClass = "normalizedSemantics" | "revisionLineage" | "orientation" | "floorPlan" | "canonicalView" | "selectedReferenceImage" | "materials" | "qualityReport" | "roomBrief" | "redesignIntent" | "providerInstructions" | "mesh" | "texture";
interface AIReadySlot { readonly artifactID: string; readonly artifactClass: AIReadyArtifactClass; }
interface AIReadyArtifact extends AIReadySlot { readonly disposition: "included" | "excluded" | "skipped" | "unavailable"; readonly relativePath?: string; readonly sha256?: string; readonly byteCount?: number; readonly mediaType?: string; readonly reasonCode?: string; }

const AI_READY_CLASS_RANK: Readonly<Record<AIReadyArtifactClass, number>> = Object.freeze({ normalizedSemantics: 0, revisionLineage: 1, orientation: 2, floorPlan: 3, canonicalView: 4, selectedReferenceImage: 5, materials: 6, qualityReport: 7, roomBrief: 8, redesignIntent: 9, providerInstructions: 10, mesh: 11, texture: 12 });
const AI_READY_CLASSES = new Set<AIReadyArtifactClass>(Object.keys(AI_READY_CLASS_RANK) as AIReadyArtifactClass[]);

function parseAIReadyPlan(values: readonly unknown[]): readonly AIReadySlot[] {
  if (values.length < 1 || values.length > 1_000) throw invalid("ai_package");
  const ids = new Set<string>(); const slots = values.map((value) => {
    const item = object(value, "ai_package"); exactKeys(item, ["artifactClass", "artifactID"], "ai_package");
    const artifactClass = aiReadyClass(item.artifactClass); const artifactID = identifier(item.artifactID, "ai_package");
    if (ids.has(artifactID)) throw invalid("ai_package"); ids.add(artifactID); return Object.freeze({ artifactClass, artifactID });
  });
  if (slots.some((slot, index) => index > 0 && (AI_READY_CLASS_RANK[slots[index - 1]!.artifactClass] > AI_READY_CLASS_RANK[slot.artifactClass] || AI_READY_CLASS_RANK[slots[index - 1]!.artifactClass] === AI_READY_CLASS_RANK[slot.artifactClass] && slots[index - 1]!.artifactID.localeCompare(slot.artifactID) >= 0))) throw invalid("ai_package");
  const count = (artifactClass: AIReadyArtifactClass): number => slots.filter((slot) => slot.artifactClass === artifactClass).length;
  for (const artifactClass of ["normalizedSemantics", "revisionLineage", "orientation", "floorPlan", "materials", "qualityReport", "roomBrief", "redesignIntent"] as const) if (count(artifactClass) !== 1) throw invalid("ai_package");
  if (count("canonicalView") !== 6 || !(count("selectedReferenceImage") >= 1 && count("selectedReferenceImage") <= 64) || !(count("mesh") >= 1 && count("mesh") <= 32) || !(count("texture") >= 1 && count("texture") <= 64)) throw invalid("ai_package");
  const providers = new Set(slots.filter((slot) => slot.artifactClass === "providerInstructions").map((slot) => slot.artifactID));
  if (providers.size !== 4 || !["instructions-provider-neutral", "instructions-chatgpt", "instructions-claude", "instructions-grok"].every((id) => providers.has(id))) throw invalid("ai_package");
  return Object.freeze(slots);
}

function parseAIReadyArtifacts(values: readonly unknown[], plan: readonly AIReadySlot[]): readonly AIReadyArtifact[] {
  if (values.length !== plan.length) throw invalid("ai_package");
  const artifacts = values.map((value, index) => {
    const item = object(value, "ai_package"); exactKeys(item, ["artifactClass", "artifactID", "disposition"], "ai_package", ["byteCount", "mediaType", "reasonCode", "relativePath", "sha256"]);
    const artifactClass = aiReadyClass(item.artifactClass); const artifactID = identifier(item.artifactID, "ai_package"); const slot = plan[index];
    if (slot === undefined || slot.artifactClass !== artifactClass || slot.artifactID !== artifactID) throw invalid("ai_package");
    const disposition = enumString(item.disposition, ["included", "excluded", "skipped", "unavailable"] as const, "ai_package");
    if (disposition === "included") {
      const relativePath = nestedPath(item.relativePath, "ai_package"); const sha256 = digest(item.sha256, "ai_package"); const byteCount = boundedInteger(item.byteCount, 1, PUBLICATION_MAX_ASSET_BYTES, "ai_package"); const mediaType = media(item.mediaType, "ai_package");
      if (item.reasonCode !== undefined || !aiReadyPathMediaAllowed(artifactClass, relativePath, mediaType)) throw invalid("ai_package");
      return Object.freeze({ artifactClass, artifactID, disposition, relativePath, sha256, byteCount, mediaType });
    }
    if (item.relativePath !== undefined || item.sha256 !== undefined || item.byteCount !== undefined || item.mediaType !== undefined) throw invalid("ai_package");
    return Object.freeze({ artifactClass, artifactID, disposition, reasonCode: identifier(item.reasonCode, "ai_package") });
  });
  return Object.freeze(artifacts);
}

function validateAIReadyIncludedCounts(artifacts: readonly AIReadyArtifact[]): void {
  const included = (artifactClass: AIReadyArtifactClass): number => artifacts.filter((artifact) => artifact.artifactClass === artifactClass && artifact.disposition === "included").length;
  for (const artifactClass of ["normalizedSemantics", "revisionLineage", "orientation", "floorPlan", "roomBrief", "redesignIntent"] as const) if (included(artifactClass) !== 1) throw invalid("ai_package");
  if (included("canonicalView") !== 6 || included("providerInstructions") !== 4 || included("selectedReferenceImage") > 4) throw invalid("ai_package");
}

function validateAIReadyDisclosure(value: unknown, source: ValidatedPublicationSourceBinding["sourceRevision"], binding: AIReadyPackageBinding): void {
  const review = object(value, "ai_package"); exactKeys(review, ["decision", "preciseGPSExcluded", "rawEvidenceDisclosureAccepted", "reviewID", "reviewedArtifactPlanSHA256", "reviewedAt", "reviewedSelectionSHA256", "sourceRevisionID", "sourceRevisionManifestSHA256"], "ai_package");
  if (review.decision !== "approved" || review.preciseGPSExcluded !== true || review.rawEvidenceDisclosureAccepted !== false || !isCanonicalTimestamp(review.reviewedAt) || identifier(review.reviewID, "ai_package") === "" || identifier(review.sourceRevisionID, "ai_package") !== source.revisionID || digest(review.sourceRevisionManifestSHA256, "ai_package") !== source.revisionManifestSHA256 || digest(review.reviewedArtifactPlanSHA256, "ai_package") !== binding.artifactPlanSHA256 || digest(review.reviewedSelectionSHA256, "ai_package") !== binding.selectionSHA256) throw invalid("ai_package");
}

function aiReadyClass(value: unknown): AIReadyArtifactClass { if (typeof value !== "string" || !AI_READY_CLASSES.has(value as AIReadyArtifactClass)) throw invalid("ai_package"); return value as AIReadyArtifactClass; }
function aiReadyPathMediaAllowed(artifactClass: AIReadyArtifactClass, path: string, mediaType: string): boolean {
  switch (artifactClass) {
  case "normalizedSemantics": return path === "truth/semantic-model.json" && mediaType === "application/json";
  case "revisionLineage": return path === "truth/revision-lineage.json" && mediaType === "application/json";
  case "orientation": return path === "truth/orientation.json" && mediaType === "application/json";
  case "floorPlan": return path === "derivatives/floor-plan.png" && mediaType === "image/png";
  case "canonicalView": return path.startsWith("derivatives/canonical-views/") && path.endsWith(".png") && mediaType === "image/png";
  case "selectedReferenceImage": return path.startsWith("references/") && path.endsWith(".jpg") && mediaType === "image/jpeg";
  case "materials": return path === "appearance/materials.json" && mediaType === "application/json";
  case "qualityReport": return path === "quality/quality-report-carrier.json" && mediaType === "application/json";
  case "roomBrief": return path === "brief/room-brief.txt" && mediaType === "text/plain";
  case "redesignIntent": return path === "intent/redesign-intent.json" && mediaType === "application/json";
  case "providerInstructions": return path.startsWith("instructions/") && path.endsWith(".txt") && mediaType === "text/plain";
  case "mesh": return path.startsWith("geometry/") && ["model/vnd.usdz+zip", "model/gltf-binary", "model/obj", "text/plain", "application/octet-stream"].includes(mediaType);
  case "texture": return path.startsWith("appearance/textures/") && path.endsWith(".png") && mediaType === "image/png";
  }
}

function validateOuterClosure(entries: readonly ZipEntry[], assets: readonly ValidatedPublicationAsset[]): void {
  const expected = new Set(["publication-manifest.json", "presentation.json", ...assets.map((asset) => asset.relativePath)]);
  if (expected.size !== entries.length || entries.some((entry) => !expected.has(entry.path))) throw invalid("zip_closure");
}

function validateFixtureLedger(assets: readonly ValidatedPublicationAsset[], expected: readonly PublicationArchiveExpectation["ledger"][number][]): void {
  if (assets.length !== expected.length) throw invalid("asset");
  const expectedByPath = new Map(expected.map((entry) => [entry.path, entry]));
  if (expectedByPath.size !== expected.length) throw invalid("asset");
  for (const asset of assets) {
    const fixture = expectedByPath.get(asset.relativePath);
    if (fixture === undefined || fixture.byteCount !== asset.byteCount || fixture.sha256 !== asset.sha256 || fixture.mediaType !== asset.mediaType) throw invalid("asset");
  }
}

async function parseStoreZip(reader: PublicationArchiveReader, code: PublicationArchiveValidationCode): Promise<readonly ZipEntry[]> {
  assertReader(reader, PUBLICATION_MAX_ARCHIVE_BYTES, code);
  const tailLength = Math.min(reader.byteLength, 65_557); const tailStart = reader.byteLength - tailLength;
  const tail = await readExact(reader, tailStart, tailLength, code);
  let eocd = -1;
  for (let offset = tail.byteLength - 22; offset >= 0; offset -= 1) if (le32(tail, offset) === ZIP_EOCD && offset + 22 + le16(tail, offset + 20) === tail.byteLength) { eocd = offset; break; }
  if (eocd < 0 || le16(tail, eocd + 4) !== 0 || le16(tail, eocd + 6) !== 0) throw invalid(code);
  const count = le16(tail, eocd + 10); const centralSize = le32(tail, eocd + 12); const centralOffset = le32(tail, eocd + 16);
  if (count < 1 || count > MAX_ZIP_ENTRIES || centralSize < 46 || centralSize > MAX_CENTRAL_DIRECTORY_BYTES || centralOffset + centralSize !== tailStart + eocd || centralOffset + centralSize > reader.byteLength) throw invalid(code);
  const central = await readExact(reader, centralOffset, centralSize, code); const entries: ZipEntry[] = []; let offset = 0;
  for (let index = 0; index < count; index += 1) {
    if (offset + 46 > central.byteLength || le32(central, offset) !== ZIP_CENTRAL) throw invalid(code);
    const flags = le16(central, offset + 8); const method = le16(central, offset + 10); const crc = le32(central, offset + 16); const compressed = le32(central, offset + 20); const uncompressed = le32(central, offset + 24); const nameLength = le16(central, offset + 28); const extraLength = le16(central, offset + 30); const commentLength = le16(central, offset + 32); const disk = le16(central, offset + 34); const external = le32(central, offset + 38); const localOffset = le32(central, offset + 42);
    const end = offset + 46 + nameLength + extraLength + commentLength;
    if (end > central.byteLength || flags !== 0x0800 || method !== 0 || compressed !== uncompressed || disk !== 0 || extraLength !== 0 || commentLength !== 0 || isSymlink(le16(central, offset + 5), external)) throw invalid(code);
    const path = zipPath(central.subarray(offset + 46, offset + 46 + nameLength), code);
    if (entries.some((entry) => entry.path === path)) throw invalid(code);
    entries.push(Object.freeze({ path, crc32: crc, byteCount: uncompressed, localOffset, dataOffset: 0 })); offset = end;
  }
  if (offset !== central.byteLength) throw invalid(code);
  const ordered = [...entries].sort((left, right) => left.localOffset - right.localOffset); let previousEnd = 0;
  const verified: ZipEntry[] = [];
  for (const entry of ordered) {
    if (entry.localOffset !== previousEnd || entry.localOffset + 30 > centralOffset) throw invalid(code);
    const header = await readExact(reader, entry.localOffset, 30, code);
    if (le32(header, 0) !== ZIP_LOCAL || le16(header, 6) !== 0x0800 || le16(header, 8) !== 0 || le32(header, 14) !== entry.crc32 || le32(header, 18) !== entry.byteCount || le32(header, 22) !== entry.byteCount || le16(header, 28) !== 0) throw invalid(code);
    const nameLength = le16(header, 26); const name = await readExact(reader, entry.localOffset + 30, nameLength, code);
    if (zipPath(name, code) !== entry.path) throw invalid(code);
    const dataOffset = entry.localOffset + 30 + nameLength; const end = dataOffset + entry.byteCount;
    if (end > centralOffset) throw invalid(code);
    previousEnd = end; verified.push(Object.freeze({ ...entry, dataOffset }));
  }
  if (previousEnd !== centralOffset) throw invalid(code);
  return Object.freeze(verified);
}

function mapEntries(entries: readonly ZipEntry[], code: PublicationArchiveValidationCode): ReadonlyMap<string, ZipEntry> {
  const mapped = new Map(entries.map((entry) => [entry.path, entry])); if (mapped.size !== entries.length) throw invalid(code); return mapped;
}
function requireEntry(entries: ReadonlyMap<string, ZipEntry>, path: string, code: PublicationArchiveValidationCode): ZipEntry { const entry = entries.get(path); if (entry === undefined) throw invalid(code); return entry; }
function subReader(parent: PublicationArchiveReader, start: number, byteLength: number): PublicationArchiveReader {
  return Object.freeze({ byteLength, read: async (offset: number, length: number) => {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || offset + length > byteLength) throw invalid("ai_package");
    return parent.read(start + offset, length);
  } });
}
async function readEntry(reader: PublicationArchiveReader, entry: ZipEntry, maximum: number, code: PublicationArchiveValidationCode): Promise<Uint8Array> {
  if (entry.byteCount > maximum) throw invalid(code); return readExact(reader, entry.dataOffset, entry.byteCount, code);
}
async function digestEntry(reader: PublicationArchiveReader, entry: ZipEntry, code: PublicationArchiveValidationCode): Promise<string> {
  const hash = createHash("sha256"); let crc = 0xffff_ffff;
  for (let offset = 0; offset < entry.byteCount; offset += PUBLICATION_MAX_PROTECTED_CHUNK_BYTES) { const chunk = await readExact(reader, entry.dataOffset + offset, Math.min(PUBLICATION_MAX_PROTECTED_CHUNK_BYTES, entry.byteCount - offset), code); hash.update(chunk); crc = crc32Update(crc, chunk); }
  if ((crc ^ 0xffff_ffff) >>> 0 !== entry.crc32) throw invalid(code); return hash.digest("hex");
}
async function digestReader(reader: PublicationArchiveReader): Promise<string> { const hash = createHash("sha256"); for (let offset = 0; offset < reader.byteLength; offset += PUBLICATION_MAX_PROTECTED_CHUNK_BYTES) hash.update(await readExact(reader, offset, Math.min(PUBLICATION_MAX_PROTECTED_CHUNK_BYTES, reader.byteLength - offset), "archive_digest")); return hash.digest("hex"); }
async function readExact(reader: PublicationArchiveReader, offset: number, length: number, code: PublicationArchiveValidationCode): Promise<Uint8Array> {
  const maximum = code === "archive_digest"
    ? PUBLICATION_MAX_PROTECTED_CHUNK_BYTES
    : code === "asset" || code === "media" || code === "geometry" || code === "presentation" || code === "manifest" || code === "ai_package"
      ? PUBLICATION_MAX_NESTED_AI_READY_BYTES
      : MAX_CENTRAL_DIRECTORY_BYTES;
  // This is a reader-call ceiling, not a ZIP central-directory ceiling. The
  // central directory remains independently limited at its EOCD parse site.
  if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || offset + length > reader.byteLength || length > maximum) throw invalid(code);
  let value: Uint8Array;
  try { value = await reader.read(offset, length); } catch { throw invalid(code); }
  if (!(value instanceof Uint8Array) || value.byteLength !== length) throw invalid(code);
  return value;
}
function assertReader(reader: PublicationArchiveReader, maximum: number, code: PublicationArchiveValidationCode): void { if (reader === null || typeof reader !== "object" || typeof reader.read !== "function" || !Number.isSafeInteger(reader.byteLength) || reader.byteLength < 22 || reader.byteLength > maximum) throw invalid(code); }

function strict(bytes: Uint8Array, code: PublicationArchiveValidationCode): unknown { try { return strictCanonicalJson(bytes); } catch { throw invalid(code); } }
function utf8Text(bytes: Uint8Array, code: PublicationArchiveValidationCode): string { try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { throw invalid(code); } }
function object(value: unknown, code: PublicationArchiveValidationCode): Readonly<Record<string, unknown>> { if (value === null || typeof value !== "object" || Array.isArray(value) || Object.getPrototypeOf(value) !== Object.prototype) throw invalid(code); return value as Readonly<Record<string, unknown>>; }
function array(value: unknown, code: PublicationArchiveValidationCode): readonly unknown[] { if (!Array.isArray(value)) throw invalid(code); return value; }
function exactKeys(value: Readonly<Record<string, unknown>>, required: readonly string[], code: PublicationArchiveValidationCode, optional: readonly string[] = []): void { const allowed = new Set([...required, ...optional]); if (required.some((key) => value[key] === undefined) || Object.keys(value).some((key) => !allowed.has(key))) throw invalid(code); }
function enumString<T extends readonly string[]>(value: unknown, values: T, code: PublicationArchiveValidationCode): T[number] { if (typeof value !== "string" || !values.includes(value)) throw invalid(code); return value as T[number]; }
function identifier(value: unknown, code: PublicationArchiveValidationCode): string { if (typeof value !== "string" || value.length < 1 || value.length > 128 || !/^[A-Za-z0-9_.-]+$/u.test(value)) throw invalid(code); return value; }
function digest(value: unknown, code: PublicationArchiveValidationCode): string { if (!isSHA256(value)) throw invalid(code); return value; }
function boundedInteger(value: unknown, minimum: number, maximum: number, code: PublicationArchiveValidationCode): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw invalid(code); return value; }
function finite(value: unknown, minimum: number, maximum: number, code: PublicationArchiveValidationCode): number { if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) throw invalid(code); return value; }
function text(value: unknown, minimum: number, maximum: number, code: PublicationArchiveValidationCode): string { if (typeof value !== "string" || value.length < minimum || value.length > maximum || hasControl(value)) throw invalid(code); return value; }
function media(value: unknown, code: PublicationArchiveValidationCode): string { if (typeof value !== "string" || value.length < 3 || value.length > 127 || !/^[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]+$/u.test(value)) throw invalid(code); return value; }
function publicationAssetPath(value: unknown, assetID: string, assetClass: ValidatedPublicationAsset["assetClass"], code: PublicationArchiveValidationCode): string { if (typeof value !== "string" || !/^assets\/[A-Za-z0-9_.-]+\.(?:geometry\.json|png|jpg|zip)$/u.test(value) || value.includes("..") || value.includes("\\")) throw invalid(code); const expectedSuffix = assetClass === "webGeometry" ? ".geometry.json" : assetClass === "aiReadyPackage" ? ".zip" : undefined; if (expectedSuffix !== undefined && value !== `assets/${assetID}${expectedSuffix}`) throw invalid(code); if (expectedSuffix === undefined && !value.startsWith(`assets/${assetID}.`)) throw invalid(code); return value; }
function nestedPath(value: unknown, code: PublicationArchiveValidationCode): string { if (typeof value !== "string" || value.length < 1 || value.length > 256 || !/^[A-Za-z0-9][A-Za-z0-9_.\/-]*$/u.test(value) || value.includes("..") || value.includes("//") || value.includes("\\")) throw invalid(code); return value; }
function assetClassMediaMatches(assetClass: ValidatedPublicationAsset["assetClass"], mediaType: string): boolean { if (assetClass === "webGeometry") return mediaType === "application/json"; if (assetClass === "aiReadyPackage") return mediaType === "application/zip"; return mediaType === "image/png" || mediaType === "image/jpeg"; }
function assetMatches(assets: readonly ValidatedPublicationAsset[], assetID: string, assetClass: ValidatedPublicationAsset["assetClass"]): boolean { return assets.some((asset) => asset.assetID === assetID && asset.assetClass === assetClass); }
function requireRoomAsset(assets: readonly ValidatedPublicationAsset[], assetID: string, assetClass: ValidatedPublicationAsset["assetClass"], roomKey: string): void { if (!assets.some((asset) => asset.assetID === assetID && asset.assetClass === assetClass && asset.publicRoomKey === roomKey)) throw invalid("presentation"); }
function boundedIdentifierArray(value: unknown, minimum: number, maximum: number, code: PublicationArchiveValidationCode): readonly string[] { const values = array(value, code); if (values.length < minimum || values.length > maximum) throw invalid(code); const result = values.map((item) => identifier(item, code)); if (new Set(result).size !== result.length) throw invalid(code); return result; }
function assertNoForbiddenPresentationKeys(value: unknown): void { const forbidden = new Set(["rawRGB", "rawRgb", "depth", "confidence", "diagnostics", "worldMap", "worldMaps", "privateNotes", "notes", "preciseGPS", "gps", "latitude", "longitude", "revisionHistory", "history", "coordinates", "alignment", "connectivity", "reconstruction", "topology"]); const visit = (candidate: unknown): void => { if (Array.isArray(candidate)) { candidate.forEach(visit); return; } if (candidate !== null && typeof candidate === "object") for (const [key, child] of Object.entries(candidate as Record<string, unknown>)) { if (forbidden.has(key)) throw invalid("presentation"); visit(child); } }; visit(value); }
function hasControl(value: string): boolean { for (let index = 0; index < value.length; index += 1) if (value.charCodeAt(index) < 0x20) return true; return false; }
function zipPath(bytes: Uint8Array, code: PublicationArchiveValidationCode): string { let path: string; try { path = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { throw invalid(code); } if (!/^[A-Za-z0-9][A-Za-z0-9_.\/-]*$/u.test(path) || path.includes("..") || path.includes("//") || path.includes("\\") || path.endsWith("/")) throw invalid(code); return path; }
function isSymlink(versionMadeBy: number, external: number): boolean { const platform = versionMadeBy >> 8; const mode = external >>> 16; return platform === 3 && (mode & 0o170000) === 0o120000; }
function ascii(bytes: Uint8Array, code: PublicationArchiveValidationCode): string { try { const value = new TextDecoder("ascii", { fatal: true }).decode(bytes); if (!/^[A-Za-z]{4}$/u.test(value)) throw new Error(); return value; } catch { throw invalid(code); } }
function le16(bytes: Uint8Array, offset: number): number { return (bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8); }
function le32(bytes: Uint8Array, offset: number): number { return (((bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8) | ((bytes[offset + 2] ?? 0) << 16) | ((bytes[offset + 3] ?? 0) << 24)) >>> 0); }
function be16(bytes: Uint8Array, offset: number): number { return ((bytes[offset] ?? 0) << 8) | (bytes[offset + 1] ?? 0); }
function be32(bytes: Uint8Array, offset: number): number { return ((((bytes[offset] ?? 0) << 24) | ((bytes[offset + 1] ?? 0) << 16) | ((bytes[offset + 2] ?? 0) << 8) | (bytes[offset + 3] ?? 0)) >>> 0); }
const CRC32_TABLE = Array.from({ length: 256 }, (_, index) => { let value = index; for (let round = 0; round < 8; round += 1) value = (value & 1) === 1 ? (value >>> 1) ^ 0xedb8_8320 : value >>> 1; return value >>> 0; });
function crc32Update(state: number, bytes: Uint8Array): number { let value = state; for (const byte of bytes) value = (value >>> 8) ^ (CRC32_TABLE[(value ^ byte) & 0xff] ?? 0); return value >>> 0; }
function crc32(bytes: Uint8Array): number { return (crc32Update(0xffff_ffff, bytes) ^ 0xffff_ffff) >>> 0; }
function crc32Parts(parts: readonly Uint8Array[]): number { return (parts.reduce((state, part) => crc32Update(state, part), 0xffff_ffff) ^ 0xffff_ffff) >>> 0; }
function invalid(code: PublicationArchiveValidationCode): never { throw new PublicationArchiveValidationError(code); }
