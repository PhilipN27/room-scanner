import { createHash } from "node:crypto";

import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "../contracts/project-sync.js";

/**
 * The hosted validator intentionally knows only the transport envelope. It
 * does not hydrate an app package or try to repair it: downloads use the app's
 * existing staged package-validation boundary after this independent server
 * check succeeds.
 */
export type ProjectSyncArchiveTier = "working" | "raw";

export interface ProjectSyncArchiveExpectation {
  readonly projectId: string;
  readonly sourceRevisionId: string;
  /** Exact persisted working/raw manifest digest. */
  readonly manifestSha256: string;
  /** Exact persisted accepted raw-review digest. Required for raw only. */
  readonly reviewSha256?: string;
  readonly sha256: string;
  readonly byteCount: number;
}

export interface ProjectSyncArchiveValidationInput {
  readonly tier: ProjectSyncArchiveTier;
  readonly archive: Uint8Array;
  readonly expected: ProjectSyncArchiveExpectation;
}

export interface ValidatedProjectSyncArchive {
  readonly tier: ProjectSyncArchiveTier;
  readonly projectId: string;
  readonly sourceRevisionId: string;
  readonly coordinateSpaceEpochId: string;
  readonly sha256: string;
  readonly byteCount: number;
}

export type ProjectSyncArchiveValidationCode =
  | "invalid_input"
  | "digest_mismatch"
  | "zip_structure"
  | "duplicate_entry"
  | "unsafe_path"
  | "forbidden_raw_artifact"
  | "invalid_json"
  | "noncanonical_json"
  | "invalid_manifest"
  | "binding_mismatch"
  | "entry_closure"
  | "entry_digest";

export class ProjectSyncArchiveValidationError extends Error {
  constructor(readonly code: ProjectSyncArchiveValidationCode) {
    super(code);
    this.name = "ProjectSyncArchiveValidationError";
  }
}

interface ZipEntry {
  readonly path: string;
  readonly bytes: Uint8Array;
  readonly crc32: number;
}

interface SourceBinding {
  readonly projectID: string;
  readonly revisionID: string;
  readonly coordinateSpaceEpochID: string;
  readonly packageSchemaVersion: string;
  readonly revisionManifestSHA256: string;
  readonly semanticSHA256: string;
}

interface ValidatedBackupDescriptor {
  readonly snapshotID: string;
  readonly projectID: string;
  readonly headRevisionID: string;
  readonly projectSchemaVersion: SourceBinding["packageSchemaVersion"];
  readonly displayName: string;
  readonly sourceUpdatedAt: number;
  readonly revisionCount: number;
  readonly fileCount: number;
  readonly uncompressedByteCount: number;
  readonly manifestSHA256: string;
  readonly archiveSHA256: string;
  readonly archiveByteCount: number;
}

interface ManifestEntry {
  readonly path: string;
  readonly byteCount: number;
  readonly sha256: string;
  readonly kind?: WorkingEntryKind | undefined;
  readonly assetClass?: string | undefined;
  readonly assetID?: string | undefined;
  readonly mediaType?: string | undefined;
}

interface Vector3 {
  readonly x: number;
  readonly y: number;
  readonly z: number;
}

interface ConceptAttachmentMapping {
  readonly status: "automatic" | "manual" | "unmatched";
  readonly cameraID?: string | undefined;
}

interface ConceptAttachment {
  readonly attachmentID: string;
  readonly relativePath: string;
  readonly sha256: string;
  readonly byteCount: number;
  readonly mapping: ConceptAttachmentMapping;
}

interface ValidatedConceptSet {
  readonly conceptSetID: string;
  readonly sourcePackage?: Readonly<{ readonly packageID: string }> | undefined;
  readonly attachments: readonly ConceptAttachment[];
}

interface ValidatedAiPackage {
  readonly packageID: string;
  readonly canonicalCameraIDs: ReadonlySet<string>;
}

interface ConceptMappingAdjustment {
  readonly conceptSetID: string;
  readonly attachmentID: string;
  readonly from: ConceptAttachmentMapping;
  readonly to: ConceptAttachmentMapping;
}

interface AiArtifactSlot {
  readonly artifactID: string;
  readonly artifactClass: string;
}

interface AiArtifact extends AiArtifactSlot {
  readonly disposition: "included" | "excluded" | "skipped" | "unavailable" | "failed";
  readonly relativePath?: string | undefined;
  readonly sha256?: string | undefined;
  readonly byteCount?: number | undefined;
  readonly mediaType?: string | undefined;
  readonly reasonCode?: string | undefined;
}

type WorkingEntryKind = "packageBackup" | "redesignCompanion" | "conceptSetManifest" | "conceptSetAttachment" | "conceptSourcePackageProvenance";

const SHA256 = /^[a-f0-9]{64}$/u;
const SAFE_ID = /^[A-Za-z0-9_-]{1,128}$/u;
const FORBIDDEN_RAW_PATH = /(?:^|\/)(?:rgb|depth|confidence|diagnostic(?:s)?|world[-_]?map|capture[-_]?bundle)(?:[._/\-]|$)/iu;
const MAX_ARCHIVE_BYTES = PROJECT_SYNC_MAX_ARCHIVE_BYTES;
const MAX_ENTRY_COUNT = 512;
const MAX_ENTRY_BYTES = MAX_ARCHIVE_BYTES;
const MAX_CONTRACT_ASSET_BYTES = 1_099_511_627_776;
const MAX_COLLECTION_COUNT = 1_000;
const AI_ARTIFACT_CLASSES = [
  "normalizedSemantics", "revisionLineage", "orientation", "floorPlan", "canonicalView", "selectedReferenceImage",
  "materials", "qualityReport", "roomBrief", "redesignIntent", "providerInstructions", "mesh", "texture",
  "conceptAttachment", "comments", "rawRGB", "rawDepth", "rawConfidence", "diagnostics", "worldMap",
] as const;
const AI_ARTIFACT_CLASS_RANK = new Map<string, number>(AI_ARTIFACT_CLASSES.map((value, index) => [value, index]));
const AI_READY_ALLOWED_ARTIFACTS = new Set<string>([
  "normalizedSemantics", "revisionLineage", "orientation", "floorPlan", "canonicalView", "selectedReferenceImage",
  "materials", "qualityReport", "roomBrief", "redesignIntent", "providerInstructions", "mesh", "texture",
]);
const CORE_GRAPHEME_SEGMENTER = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** Validates bytes and all declared bindings. Caller-provided digests are only
 * expectations: the archive is always hashed and parsed locally. */
export function validateProjectSyncArchive(input: ProjectSyncArchiveValidationInput): ValidatedProjectSyncArchive {
  if (input === null || typeof input !== "object" || (input.tier !== "working" && input.tier !== "raw")
    || !(input.archive instanceof Uint8Array) || !validExpectation(input.expected)) {
    throw fail("invalid_input");
  }
  // The worker intentionally has no second full-archive allocation. The AWS
  // provider has already bounded its read; this guard keeps direct callers
  // from making ZIP parsing/hash work for a larger in-memory value.
  if (input.archive.byteLength > MAX_ARCHIVE_BYTES) throw fail("zip_structure");
  const archive = input.archive;
  // This preflight is intentionally in front of ZIP parsing. It makes the
  // detector exerciseable on a corrupt archive too, so a test can prove the
  // raw detector is live rather than only traversing successful ZIPs.
  if (input.tier === "working" && containsForbiddenRawBytes(archive)) throw fail("forbidden_raw_artifact");
  const digest = sha256(archive);
  if (archive.byteLength !== input.expected.byteCount || digest !== input.expected.sha256) throw fail("digest_mismatch");
  const entries = readZip32Store(archive);
  return input.tier === "working"
    ? validateWorking(entries, input.expected, digest, archive.byteLength)
    : validateRaw(entries, input.expected, digest, archive.byteLength);
}

/** Used by the verifier's positive control. It only reports a detection; it
 * is not an authorization decision and never logs paths or bytes. */
export function containsForbiddenRawBytes(bytes: Uint8Array): boolean {
  return containsForbiddenRawByteChunks([bytes]);
}

/**
 * The raw marker guard deliberately consumes byte chunks so a future stream
 * boundary cannot evade it by splitting a marker. It retains no archive
 * bytes: only the longest marker plus its preceding quote/start sentinel.
 */
export function containsForbiddenRawByteChunks(chunks: Iterable<Uint8Array>): boolean {
  const scanner = new ForbiddenRawByteScanner();
  for (const chunk of chunks) {
    scanner.push(chunk);
    if (scanner.detected) return true;
  }
  return false;
}

const FORBIDDEN_RAW_LITERAL = asciiBytes("rgb_capture_bundle_forbidden");
const FORBIDDEN_RAW_PATH_MARKERS = [
  "raw/rgb",
  "raw/depth",
  "raw/confidence",
  "raw/diagnostic",
  "raw/world-map",
  "raw/world_map",
].map(asciiBytes);
const FORBIDDEN_RAW_SCANNER_WINDOW = Math.max(
  FORBIDDEN_RAW_LITERAL.byteLength,
  ...FORBIDDEN_RAW_PATH_MARKERS.map((marker) => marker.byteLength),
) + 1;

class ForbiddenRawByteScanner {
  readonly #window = new Uint8Array(FORBIDDEN_RAW_SCANNER_WINDOW);
  #write = 0;
  #seen = 0;
  detected = false;

  push(chunk: Uint8Array): void {
    for (const source of chunk) {
      this.#window[this.#write] = asciiLower(source);
      this.#write = (this.#write + 1) % this.#window.byteLength;
      this.#seen += 1;
      if (this.#matches(FORBIDDEN_RAW_LITERAL)
        || FORBIDDEN_RAW_PATH_MARKERS.some((marker) => this.#matchesRawPath(marker))) {
        this.detected = true;
        return;
      }
    }
  }

  #matchesRawPath(marker: Uint8Array): boolean {
    if (!this.#matches(marker)) return false;
    if (this.#seen === marker.byteLength) return true;
    const preceding = this.#fromEnd(marker.byteLength);
    return preceding === 0x22 || preceding === 0x27;
  }

  #matches(marker: Uint8Array): boolean {
    if (this.#seen < marker.byteLength) return false;
    for (let index = 0; index < marker.byteLength; index += 1) {
      if (this.#fromEnd(marker.byteLength - 1 - index) !== marker[index]) return false;
    }
    return true;
  }

  #fromEnd(distance: number): number {
    return this.#window[(this.#write - 1 - distance + this.#window.byteLength) % this.#window.byteLength]!;
  }
}

function asciiBytes(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index += 1) bytes[index] = value.charCodeAt(index);
  return bytes;
}

function asciiLower(value: number): number {
  return value >= 0x41 && value <= 0x5a ? value + 0x20 : value;
}

function validateWorking(entries: ReadonlyMap<string, ZipEntry>, expected: ProjectSyncArchiveExpectation, digest: string, byteCount: number): ValidatedProjectSyncArchive {
  rejectForbiddenWorkingEntries(entries);
  const manifestEntry = required(entries, "working-set-manifest.json");
  const manifest = strictJson(manifestEntry.bytes);
  const record = object(manifest, "invalid_manifest");
  requireExactKeys(record, ["schemaVersion", "projectID", "headRevisionID", "packageDescriptor", "sourceRevision", "entries", "conceptMappingAdjustments"]);
  if (record.schemaVersion !== "roomscan-professional-working-set-manifest-v1") throw fail("invalid_manifest");
  if (sha256(manifestEntry.bytes) !== expected.manifestSha256) throw fail("entry_digest");
  const binding = sourceBinding(record.sourceRevision);
  if (record.projectID !== expected.projectId || record.headRevisionID !== expected.sourceRevisionId
    || binding.projectID !== expected.projectId || binding.revisionID !== expected.sourceRevisionId) throw fail("binding_mismatch");
  const listed = workingManifestEntries(record.entries);
  const expectedPaths = new Set<string>(["working-set-manifest.json", ...listed.map((entry) => entry.path)]);
  if (expectedPaths.size !== entries.size || [...entries.keys()].some((path) => !expectedPaths.has(path))) throw fail("entry_closure");
  for (const entry of listed) {
    const actual = required(entries, entry.path);
    if (actual.bytes.byteLength !== entry.byteCount || sha256(actual.bytes) !== entry.sha256) throw fail("entry_digest");
  }
  const packageEntries = listed.filter((entry) => entry.kind === "packageBackup" && entry.path === "package-backup.zip");
  if (packageEntries.length !== 1 || packageEntries[0] === undefined) throw fail("entry_closure");
  const packageEntry = packageEntries[0];
  validateNestedBackup(required(entries, packageEntry.path).bytes, record.packageDescriptor, binding);
  validateWorkingCompanions(entries, listed, binding, record.conceptMappingAdjustments);
  return Object.freeze({
    tier: "working",
    projectId: expected.projectId,
    sourceRevisionId: expected.sourceRevisionId,
    coordinateSpaceEpochId: binding.coordinateSpaceEpochID,
    sha256: digest,
    byteCount,
  });
}

function validateRaw(entries: ReadonlyMap<string, ZipEntry>, expected: ProjectSyncArchiveExpectation, digest: string, byteCount: number): ValidatedProjectSyncArchive {
  const manifestEntry = required(entries, "raw-archive-manifest.json");
  const record = object(strictJson(manifestEntry.bytes), "invalid_manifest");
  requireExactKeys(record, ["schemaVersion", "sourceRevision", "review", "entries"]);
  if (record.schemaVersion !== "roomscan-professional-raw-archive-manifest-v1") throw fail("invalid_manifest");
  if (sha256(manifestEntry.bytes) !== expected.manifestSha256 || expected.reviewSha256 === undefined) throw fail("entry_digest");
  const binding = sourceBinding(record.sourceRevision);
  const review = object(record.review, "invalid_manifest");
  requireExactKeys(review, ["schemaVersion", "reviewID", "sourceRevision", "reviewedSelectionSHA256", "reviewedAt", "decision", "preciseGPSExcluded"]);
  if (sha256(Buffer.from(canonicalJson(review), "utf8")) !== expected.reviewSha256
    || review.schemaVersion !== "roomscan-raw-disclosure-review-v1" || !SAFE_ID.test(string(review.reviewID, "invalid_manifest"))
    || review.decision !== "accepted" || review.preciseGPSExcluded !== true || !canonicalTimestamp(review.reviewedAt)
    || !sameBinding(sourceBinding(review.sourceRevision), binding)
    || binding.projectID !== expected.projectId || binding.revisionID !== expected.sourceRevisionId) throw fail("binding_mismatch");
  const listed = rawManifestEntries(record.entries);
  const expectedPaths = new Set<string>(["raw-archive-manifest.json", ...listed.map((entry) => entry.path)]);
  if (expectedPaths.size !== entries.size || [...entries.keys()].some((path) => !expectedPaths.has(path))) throw fail("entry_closure");
  for (const entry of listed) {
    const actual = required(entries, entry.path);
    if (actual.bytes.byteLength !== entry.byteCount || sha256(actual.bytes) !== entry.sha256) throw fail("entry_digest");
  }
  const selection = {
    schemaVersion: "roomscan-professional-raw-selection-v1",
    sourceRevision: bindingForCanonicalJson(binding),
    entries: listed.map((entry) => ({
      assetID: entry.assetID,
      assetClass: entry.assetClass,
      path: entry.path,
      mediaType: entry.mediaType,
      byteCount: entry.byteCount,
      sha256: entry.sha256,
    })),
  };
  if (sha256(Buffer.from(canonicalJson(selection), "utf8")) !== hex(review.reviewedSelectionSHA256, "invalid_manifest")) throw fail("binding_mismatch");
  return Object.freeze({
    tier: "raw",
    projectId: expected.projectId,
    sourceRevisionId: expected.sourceRevisionId,
    coordinateSpaceEpochId: binding.coordinateSpaceEpochID,
    sha256: digest,
    byteCount,
  });
}

function validateWorkingCompanions(
  entries: ReadonlyMap<string, ZipEntry>,
  listed: readonly ManifestEntry[],
  binding: SourceBinding,
  conceptMappingAdjustments: unknown,
): void {
  const referencedPackages = new Set<string>();
  const provenancePackages = new Map<string, ValidatedAiPackage>();
  const conceptSets: Array<Readonly<{ readonly entry: ManifestEntry; readonly value: ValidatedConceptSet }>> = [];
  const conceptAttachments = new Map<string, ManifestEntry>();
  let currentCanonicalCameraIDs = new Set<string>();
  for (const entry of listed) {
    if (entry.kind === "redesignCompanion") {
      currentCanonicalCameraIDs = new Set(validateRedesignCompanionSchema(strictJson(required(entries, entry.path).bytes), binding));
    }
    if (entry.kind === "conceptSetManifest") {
      const conceptSetID = conceptSetIdFromManifestPath(entry.path);
      const value = validateConceptSetCompanionSchema(strictJson(required(entries, entry.path).bytes), binding);
      if (value.conceptSetID !== conceptSetID || conceptSets.some((concept) => concept.value.conceptSetID === conceptSetID)) throw fail("binding_mismatch");
      conceptSets.push(Object.freeze({ entry, value }));
      for (const attachment of value.attachments) {
        const base = entry.path.slice(0, entry.path.lastIndexOf("/manifest.json"));
        const attachmentPath = `${base}/${attachment.relativePath}`;
        const listedAttachment = listed.find((candidate) => candidate.path === attachmentPath && candidate.kind === "conceptSetAttachment");
        if (listedAttachment === undefined || listedAttachment.byteCount !== attachment.byteCount
          || listedAttachment.sha256 !== attachment.sha256) throw fail("entry_closure");
        conceptAttachments.set(attachmentPath, listedAttachment);
      }
    }
    if (entry.kind === "conceptSourcePackageProvenance") {
      const packageID = conceptPackageIdFromProvenancePath(entry.path);
      const value = validateConceptSourcePackageProvenanceSchema(strictJson(required(entries, entry.path).bytes), binding);
      if (value.packageID !== packageID || provenancePackages.has(packageID)) throw fail("binding_mismatch");
      provenancePackages.set(packageID, value);
    }
  }
  for (const concept of conceptSets) {
    for (const attachment of concept.value.attachments) {
      const { status, cameraID } = attachment.mapping;
      if (status === "automatic") {
        const sourcePackage = concept.value.sourcePackage;
        if (sourcePackage === undefined || cameraID === undefined) throw fail("binding_mismatch");
        referencedPackages.add(sourcePackage.packageID);
        const provenance = provenancePackages.get(sourcePackage.packageID);
        if (provenance === undefined || !currentCanonicalCameraIDs.has(cameraID)
          || !provenance.canonicalCameraIDs.has(cameraID)) throw fail("binding_mismatch");
      } else if (status === "manual" && (cameraID === undefined || !currentCanonicalCameraIDs.has(cameraID))) {
        throw fail("binding_mismatch");
      }
    }
  }
  if ([...referencedPackages].some((packageID) => !provenancePackages.has(packageID))
    || [...provenancePackages.keys()].some((packageID) => !referencedPackages.has(packageID))
    || listed.filter((entry) => entry.kind === "conceptSetAttachment").some((entry) => !conceptAttachments.has(entry.path))) {
    throw fail("entry_closure");
  }
  // Core binds recovery adjustments only after all Concept manifests have
  // passed their source/provenance checks. An adjustment is not a second
  // source of truth: its destination must be exactly the mapping persisted in
  // that already-validated transported attachment.
  validateConceptMappingAdjustments(conceptMappingAdjustments, conceptSets);
}

/** Mirrors `RoomProfessionalConceptMappingAdjustment.validate()` and
 * `RoomProfessionalWorkingSetArchive.validateConceptMappingAdjustments`.
 * This deliberately accepts no future opaque metadata: working-set archives
 * are immutable validation inputs, not a forward-compatible side channel. */
function validateConceptMappingAdjustments(
  value: unknown,
  conceptSets: readonly Readonly<{ readonly entry: ManifestEntry; readonly value: ValidatedConceptSet }>[],
): void {
  const conceptsByID = new Map(conceptSets.map((concept) => [concept.value.conceptSetID, concept.value] as const));
  const identifiers = new Set<string>();
  let previousConceptSetID = "";
  let previousAttachmentID = "";
  for (const rawAdjustment of boundedArray(value, 0, MAX_COLLECTION_COUNT)) {
    const record = closedObject(rawAdjustment, ["conceptSetID", "attachmentID", "from", "to"]);
    const conceptSetID = identifier(record.conceptSetID);
    const attachmentID = identifier(record.attachmentID);
    if (conceptSetID < previousConceptSetID || (conceptSetID === previousConceptSetID && attachmentID < previousAttachmentID)) throw fail("invalid_manifest");
    previousConceptSetID = conceptSetID;
    previousAttachmentID = attachmentID;
    const identifierKey = `${conceptSetID}/${attachmentID}`;
    if (identifiers.has(identifierKey)) throw fail("invalid_manifest");
    identifiers.add(identifierKey);

    const adjustment = Object.freeze({
      conceptSetID,
      attachmentID,
      from: conceptAttachmentMapping(record.from),
      to: conceptAttachmentMapping(record.to),
    } satisfies ConceptMappingAdjustment);
    if (adjustment.from.status !== "automatic" || adjustment.from.cameraID === undefined) throw fail("invalid_manifest");
    if (adjustment.to.status === "manual") {
      if (adjustment.to.cameraID !== adjustment.from.cameraID) throw fail("invalid_manifest");
    } else if (adjustment.to.status !== "unmatched" || adjustment.to.cameraID !== undefined) {
      throw fail("invalid_manifest");
    }

    const attachment = conceptsByID.get(adjustment.conceptSetID)?.attachments.find((candidate) => candidate.attachmentID === adjustment.attachmentID);
    if (attachment === undefined || !sameConceptAttachmentMapping(attachment.mapping, adjustment.to)) throw fail("invalid_manifest");
  }
}

function conceptAttachmentMapping(value: unknown): ConceptAttachmentMapping {
  const record = closedObject(value, ["status"], ["cameraID"]);
  const status = enumValue(record.status, ["automatic", "manual", "unmatched"] as const);
  const cameraID = optionalIdentifier(record, "cameraID");
  if ((status === "automatic" || status === "manual") !== (cameraID !== undefined)) throw fail("invalid_manifest");
  return Object.freeze({ status, ...(cameraID === undefined ? {} : { cameraID }) });
}

function sameConceptAttachmentMapping(left: ConceptAttachmentMapping, right: ConceptAttachmentMapping): boolean {
  return left.status === right.status && left.cameraID === right.cameraID;
}

/** These closed schemas mirror the Core transport validators used by
 * `RoomProfessionalWorkingSetArchive`: service validation may never turn a
 * future/opaque companion field into silently hosted bytes. They intentionally
 * validate every nested object before the narrower source/provenance checks. */
function validateRedesignCompanionSchema(value: unknown, binding: SourceBinding): ReadonlySet<string> {
  const record = closedObject(value, ["schemaVersion", "contractKind", "sourceRevision", "orientation", "conceptMetadata"], ["redesignIntent", "propertyMembership"]);
  if (record.schemaVersion !== "roomscan-local-redesign-extension-v2" || record.contractKind !== "localRedesignExtension" || !sameBinding(sourceBinding(record.sourceRevision), binding)) throw fail("binding_mismatch");
  const orientation = closedObject(record.orientation, ["source", "confidence", "coordinateSpaceEpochID", "entryPositionMeters", "inwardDirection", "canonicalAxes", "topDownOrientation", "canonicalCameras"], ["entryFeatureID", "referenceWallFeatureID", "suggestionEvidence"]);
  const source = enumValue(orientation.source, ["suggested", "confirmed", "manual"] as const);
  if (identifier(orientation.coordinateSpaceEpochID) !== binding.coordinateSpaceEpochID) throw fail("binding_mismatch");
  finiteRange(orientation.confidence, 0, 1);
  point(orientation.entryPositionMeters);
  const inward = horizontalUnit(orientation.inwardDirection);
  const axes = closedObject(orientation.canonicalAxes, ["right", "up", "forward"]);
  const right = unit(axes.right); const up = unit(axes.up); const forward = horizontalUnit(axes.forward);
  if (!approximatelyEqual(forward, inward) || !approximatelyEqual(up, { x: 0, y: 1, z: 0 }) || !approximatelyEqual(right, cross(up, forward))) throw fail("invalid_manifest");
  const topDown = closedObject(orientation.topDownOrientation, ["upAxis", "screenUp"], ["presentationTransform"]);
  if (enumValue(topDown.upAxis, ["positiveY"] as const) !== "positiveY" || !approximatelyEqual(unit(topDown.screenUp), forward)) throw fail("invalid_manifest");
  const presentation = optionalClosedObject(topDown, "presentationTransform", ["quarterTurnsClockwise", "isMirroredHorizontally"]);
  if (presentation !== undefined) {
    integerRange(presentation.quarterTurnsClockwise, 0, 3);
    if (typeof presentation.isMirroredHorizontally !== "boolean") throw fail("invalid_manifest");
  }
  const roles = ["entry", "wall", "corner", "orbit", "perspective", "topDown"] as const;
  const cameras = boundedArray(orientation.canonicalCameras, 6, 6);
  const cameraIDs = new Set<string>();
  for (const [index, camera] of cameras.entries()) {
    const item = closedObject(camera, ["cameraID", "role", "positionMeters", "targetMeters", "fieldOfViewDegrees"]);
    const cameraID = identifier(item.cameraID);
    if (cameraIDs.has(cameraID) || enumValue(item.role, roles) !== roles[index]) throw fail("invalid_manifest");
    cameraIDs.add(cameraID);
    const position = point(item.positionMeters); const target = point(item.targetMeters);
    finiteRange(item.fieldOfViewDegrees, 1, 179);
    if (length({ x: position.x - target.x, y: position.y - target.y, z: position.z - target.z }) <= 0.001) throw fail("invalid_manifest");
  }
  const entryFeatureID = optionalIdentifier(orientation, "entryFeatureID");
  const referenceWallFeatureID = optionalIdentifier(orientation, "referenceWallFeatureID");
  const evidence = optionalClosedObject(orientation, "suggestionEvidence", ["featureID", "semanticRole", "usedScanStartPose", "usedDoorOrOpening"], ["scanStartPose"]);
  if (evidence !== undefined) {
    const evidenceFeatureID = identifier(evidence.featureID);
    const role = enumValue(evidence.semanticRole, ["wall", "door", "window", "opening", "floor", "ceiling", "fixedObject", "movableObject", "unknownObject"] as const);
    if ((role !== "door" && role !== "opening") || evidence.usedScanStartPose !== true || evidence.usedDoorOrOpening !== true) throw fail("invalid_manifest");
    const pose = optionalClosedObject(evidence, "scanStartPose", ["positionMeters", "forwardDirection", "coordinateSpaceEpochID"]);
    if (pose !== undefined) {
      point(pose.positionMeters); normalizedHorizontal(pose.forwardDirection);
      if (identifier(pose.coordinateSpaceEpochID) !== binding.coordinateSpaceEpochID) throw fail("binding_mismatch");
    }
    if (source === "suggested" && entryFeatureID !== undefined && entryFeatureID !== evidenceFeatureID) throw fail("invalid_manifest");
  }
  if (source === "manual" && (entryFeatureID !== undefined || referenceWallFeatureID === undefined)) throw fail("invalid_manifest");

  const intent = optionalClosedObject(record, "redesignIntent", ["request", "scope", "permissions"], ["constraints"]);
  if (intent !== undefined) {
    spatialText(intent.request, 8_000); enumValue(intent.scope, ["stage", "renovate", "reimagine"] as const);
    const constraints = optionalClosedObject(intent, "constraints", ["purpose", "style", "householdNeeds", "accessibility", "circulation", "materials", "colors", "referenceImageIDs", "desiredObjects"], ["budget"]);
    if (constraints !== undefined) {
      for (const key of ["purpose", "style", "householdNeeds", "accessibility", "circulation", "materials", "colors", "desiredObjects"]) {
        unique(boundedArray(constraints[key], 0, 100).map((entry) => spatialText(entry, 500)));
      }
      unique(boundedArray(constraints.referenceImageIDs, 0, 100).map(identifier));
      if ("budget" in constraints) spatialText(constraints.budget, 500);
    }
    const permissionIDs: string[] = [];
    for (const permission of boundedArray(intent.permissions, 0, MAX_COLLECTION_COUNT)) {
      const item = closedObject(permission, ["featureID", "permission"]);
      permissionIDs.push(identifier(item.featureID));
      enumValue(item.permission, ["preserve", "mayChange", "requestedChange"] as const);
    }
    unique(permissionIDs);
  }
  const membership = optionalClosedObject(record, "propertyMembership", ["propertyID", "roomProjectIDs"]);
  if (membership !== undefined) {
    identifier(membership.propertyID);
    const projectIDs = boundedArray(membership.roomProjectIDs, 1, MAX_COLLECTION_COUNT).map(identifier);
    unique(projectIDs);
    if (!projectIDs.includes(binding.projectID)) throw fail("binding_mismatch");
  }
  const conceptIDs: string[] = [];
  for (const concept of boundedArray(record.conceptMetadata, 0, MAX_COLLECTION_COUNT)) {
    const item = closedObject(concept, ["conceptSetID", "sourceRevision", "request", "scope", "provider", "sourceAIRoomPackageSchemaVersion", "sourceAIRoomPackageID", "createdAt", "importedAt", "mappingStatus", "attachments", "comments", "approvalState", "archiveState"]);
    conceptIDs.push(identifier(item.conceptSetID));
    if (!sameBinding(sourceBinding(item.sourceRevision), binding)) throw fail("binding_mismatch");
    spatialText(item.request, 8_000); enumValue(item.scope, ["stage", "renovate", "reimagine"] as const); spatialText(item.provider, 500);
    identifier(item.sourceAIRoomPackageSchemaVersion); identifier(item.sourceAIRoomPackageID);
    if (timestamp(item.importedAt) < timestamp(item.createdAt)) throw fail("invalid_manifest");
    enumValue(item.mappingStatus, ["automatic", "manual", "unmatched"] as const);
    for (const attachment of boundedArray(item.attachments, 0, MAX_COLLECTION_COUNT)) validateRedesignConceptAttachment(attachment);
    for (const comment of boundedArray(item.comments, 0, MAX_COLLECTION_COUNT)) spatialText(comment, 2_000);
    enumValue(item.approvalState, ["pending", "approved", "rejected"] as const);
    enumValue(item.archiveState, ["active", "archived"] as const);
  }
  unique(conceptIDs);
  return cameraIDs;
}

function validateConceptSetCompanionSchema(value: unknown, binding: SourceBinding): ValidatedConceptSet {
  const record = closedObject(value, ["schemaVersion", "conceptSetID", "sourceRevision", "request", "scope", "importProvenance", "createdAt", "importedAt", "attachments", "comments", "approvalState", "archiveState"], ["provider", "sourceAIRoomPackage"]);
  if (record.schemaVersion !== "roomscan-concept-set-v1" || !sameBinding(sourceBinding(record.sourceRevision), binding)) throw fail("binding_mismatch");
  const conceptSetID = identifier(record.conceptSetID);
  conceptText(record.request, 8_000); enumValue(record.scope, ["stage", "renovate", "reimagine"] as const);
  if ("provider" in record) conceptText(record.provider, 500);
  const importProvenance = closedObject(record.importProvenance, ["kind", "sourceFilename"]);
  const importKind = enumValue(importProvenance.kind, ["looseLocalFile", "packagedOutput"] as const);
  portableFilename(importProvenance.sourceFilename);
  const sourcePackage = optionalClosedObject(record, "sourceAIRoomPackage", ["schemaVersion", "packageID"]);
  if ((importKind === "packagedOutput") !== (sourcePackage !== undefined)) throw fail("binding_mismatch");
  const validatedSourcePackage = sourcePackage === undefined ? undefined : (() => {
    if (sourcePackage.schemaVersion !== "roomscan-ai-room-package-v1") throw fail("binding_mismatch");
    return Object.freeze({ packageID: identifier(sourcePackage.packageID) });
  })();
  if (timestamp(record.importedAt) < timestamp(record.createdAt)) throw fail("invalid_manifest");
  const rawAttachments = boundedArray(record.attachments, 1, 64);
  if (importKind === "looseLocalFile" && rawAttachments.length !== 1) throw fail("invalid_manifest");
  const attachments: ConceptAttachment[] = [];
  const attachmentIDs = new Set<string>(); const relativePaths = new Set<string>(); let priorAttachmentID = "";
  for (const attachment of rawAttachments) {
    const item = closedObject(attachment, ["attachmentID", "relativePath", "sha256", "byteCount", "mediaType", "sanitizationProvenance", "mapping"]);
    const attachmentID = identifier(item.attachmentID);
    if (attachmentID <= priorAttachmentID || attachmentIDs.has(attachmentID)) throw fail("invalid_manifest");
    priorAttachmentID = attachmentID; attachmentIDs.add(attachmentID);
    const relativePath = conceptAttachmentPath(item.relativePath);
    if (relativePaths.has(relativePath.toLowerCase())) throw fail("invalid_manifest");
    relativePaths.add(relativePath.toLowerCase());
    const mediaType = enumValue(item.mediaType, ["image/png", "image/jpeg"] as const);
    if ((mediaType === "image/png" && !relativePath.toLowerCase().endsWith(".png"))
      || (mediaType === "image/jpeg" && !(relativePath.toLowerCase().endsWith(".jpg") || relativePath.toLowerCase().endsWith(".jpeg")))) throw fail("invalid_manifest");
    const expectedSanitization = importKind === "looseLocalFile" ? "appReencodedLooseFile" : "appReencodedPackagedFile";
    if (enumValue(item.sanitizationProvenance, ["appReencodedLooseFile", "appReencodedPackagedFile"] as const) !== expectedSanitization) throw fail("invalid_manifest");
    const mapping = closedObject(item.mapping, ["status"], ["cameraID"]);
    const status = enumValue(mapping.status, ["automatic", "manual", "unmatched"] as const);
    const cameraID = optionalIdentifier(mapping, "cameraID");
    if ((status === "automatic" || status === "manual") !== (cameraID !== undefined)) throw fail("invalid_manifest");
    attachments.push(Object.freeze({ attachmentID, relativePath, sha256: hex(item.sha256, "invalid_manifest"), byteCount: positiveConceptAttachment(item.byteCount), mapping: Object.freeze({ status, ...(cameraID === undefined ? {} : { cameraID }) }) }));
  }
  for (const comment of boundedArray(record.comments, 0, MAX_COLLECTION_COUNT)) conceptText(comment, 2_000);
  enumValue(record.approvalState, ["pending", "approved", "rejected"] as const);
  enumValue(record.archiveState, ["active", "archived"] as const);
  return Object.freeze({ conceptSetID, ...(validatedSourcePackage === undefined ? {} : { sourcePackage: validatedSourcePackage }), attachments: Object.freeze(attachments) });
}

function validateConceptSourcePackageProvenanceSchema(value: unknown, binding: SourceBinding): ValidatedAiPackage {
  const record = closedObject(value, ["schemaVersion", "contractKind", "packageID", "profile", "sourceRevision", "artifactPlan", "artifactPlanSHA256", "selectionSHA256", "disclosureReview", "artifacts"]);
  if (record.schemaVersion !== "roomscan-ai-room-package-v1" || record.contractKind !== "aiRoomPackage" || record.profile !== "aiReady"
    || !sameBinding(sourceBinding(record.sourceRevision), binding)) throw fail("binding_mismatch");
  const packageID = identifier(record.packageID);
  const artifactPlanSHA256 = hex(record.artifactPlanSHA256, "invalid_manifest");
  const selectionSHA256 = hex(record.selectionSHA256, "invalid_manifest");
  const slots = validateAiArtifactPlan(record.artifactPlan);
  const artifacts = validateAiArtifacts(record.artifacts, slots);
  const planDigest = sha256(Buffer.from(canonicalJson({
    schemaVersion: "roomscan-ai-room-package-v1", contractKind: "aiRoomPackage", profile: "aiReady",
    sourceRevision: bindingForCanonicalJson(binding), slots: slots.map((slot) => ({ artifactID: slot.artifactID, artifactClass: slot.artifactClass })),
  }), "utf8"));
  if (planDigest !== artifactPlanSHA256 || sha256(Buffer.from(canonicalJson(artifacts), "utf8")) !== selectionSHA256) throw fail("binding_mismatch");
  validateAiDisclosureReview(record.disclosureReview, binding, artifactPlanSHA256, selectionSHA256);
  const canonicalCameraIDs = new Set<string>();
  for (const artifact of artifacts) {
    if (artifact.artifactClass === "canonicalView" && artifact.disposition === "included") {
      const relativePath = artifact.relativePath;
      if (relativePath === undefined || !relativePath.startsWith("derivatives/canonical-views/") || !relativePath.endsWith(".png")) throw fail("invalid_manifest");
      canonicalCameraIDs.add(identifier(relativePath.slice("derivatives/canonical-views/".length, -4)));
    }
  }
  if (canonicalCameraIDs.size !== 6) throw fail("invalid_manifest");
  return Object.freeze({ packageID, canonicalCameraIDs });
}

function validateRedesignConceptAttachment(value: unknown): void {
  const attachment = closedObject(value, ["relativePath", "sha256", "byteCount", "mediaType"]);
  coreRelativePath(attachment.relativePath); hex(attachment.sha256, "invalid_manifest");
  positiveContractAsset(attachment.byteCount); mediaType(attachment.mediaType);
}

function validateAiArtifactPlan(value: unknown): readonly AiArtifactSlot[] {
  const slots: AiArtifactSlot[] = [];
  const ids = new Set<string>();
  for (const rawSlot of boundedArray(value, 1, MAX_COLLECTION_COUNT)) {
    const record = closedObject(rawSlot, ["artifactID", "artifactClass"]);
    const artifactID = identifier(record.artifactID);
    const artifactClass = artifactClassValue(record.artifactClass);
    if (!AI_READY_ALLOWED_ARTIFACTS.has(artifactClass)) {
      if (["rawRGB", "rawDepth", "rawConfidence", "diagnostics", "worldMap"].includes(artifactClass)) throw fail("forbidden_raw_artifact");
      throw fail("invalid_manifest");
    }
    if (ids.has(artifactID)) throw fail("invalid_manifest");
    ids.add(artifactID); slots.push(Object.freeze({ artifactID, artifactClass }));
  }
  const canonical = [...slots].sort((left, right) => {
    const leftRank = AI_ARTIFACT_CLASS_RANK.get(left.artifactClass); const rightRank = AI_ARTIFACT_CLASS_RANK.get(right.artifactClass);
    if (leftRank === undefined || rightRank === undefined) throw fail("invalid_manifest");
    return leftRank === rightRank ? (left.artifactID < right.artifactID ? -1 : left.artifactID > right.artifactID ? 1 : 0) : leftRank - rightRank;
  });
  if (!slots.every((slot, index) => slot.artifactID === canonical[index]?.artifactID && slot.artifactClass === canonical[index]?.artifactClass)) throw fail("invalid_manifest");
  const count = (artifactClass: string): number => slots.filter((slot) => slot.artifactClass === artifactClass).length;
  for (const artifactClass of ["normalizedSemantics", "revisionLineage", "orientation", "floorPlan", "materials", "qualityReport", "roomBrief", "redesignIntent"]) {
    if (count(artifactClass) !== 1) throw fail("invalid_manifest");
  }
  if (count("canonicalView") !== 6 || !between(count("selectedReferenceImage"), 1, 64)
    || !between(count("mesh"), 1, 32) || !between(count("texture"), 1, 64)) throw fail("invalid_manifest");
  const instructionIDs = new Set(slots.filter((slot) => slot.artifactClass === "providerInstructions").map((slot) => slot.artifactID));
  if (instructionIDs.size !== 4 || !["instructions-provider-neutral", "instructions-chatgpt", "instructions-claude", "instructions-grok"].every((id) => instructionIDs.has(id))) throw fail("invalid_manifest");
  return Object.freeze(slots);
}

function validateAiArtifacts(value: unknown, slots: readonly AiArtifactSlot[]): readonly AiArtifact[] {
  const rawArtifacts = boundedArray(value, 1, MAX_COLLECTION_COUNT);
  if (rawArtifacts.length !== slots.length) throw fail("invalid_manifest");
  const artifacts: AiArtifact[] = [];
  const includedPaths = new Set<string>();
  for (const [index, rawArtifact] of rawArtifacts.entries()) {
    const record = closedObject(rawArtifact, ["artifactID", "artifactClass", "disposition"], ["relativePath", "sha256", "byteCount", "mediaType", "reasonCode"]);
    const artifactID = identifier(record.artifactID); const artifactClass = artifactClassValue(record.artifactClass);
    const slot = slots[index];
    if (slot === undefined || slot.artifactID !== artifactID || slot.artifactClass !== artifactClass) throw fail("invalid_manifest");
    const disposition = enumValue(record.disposition, ["included", "excluded", "skipped", "unavailable", "failed"] as const);
    if (disposition === "failed") throw fail("invalid_manifest");
    if (disposition === "included") {
      if (!("relativePath" in record) || !("sha256" in record) || !("byteCount" in record) || !("mediaType" in record) || "reasonCode" in record) throw fail("invalid_manifest");
      const relativePath = coreRelativePath(record.relativePath); const digest = hex(record.sha256, "invalid_manifest");
      const byteCount = positiveContractAsset(record.byteCount); const declaredMediaType = mediaType(record.mediaType);
      if (!allowedAiReadyArtifactPath(artifactClass, relativePath, declaredMediaType) || includedPaths.has(relativePath.toLowerCase())) throw fail("invalid_manifest");
      includedPaths.add(relativePath.toLowerCase());
      artifacts.push(Object.freeze({ artifactID, artifactClass, disposition, relativePath, sha256: digest, byteCount, mediaType: declaredMediaType }));
    } else {
      if ("relativePath" in record || "sha256" in record || "byteCount" in record || "mediaType" in record || !("reasonCode" in record)) throw fail("invalid_manifest");
      artifacts.push(Object.freeze({ artifactID, artifactClass, disposition, reasonCode: identifier(record.reasonCode) }));
    }
  }
  const included = (artifactClass: string): number => artifacts.filter((artifact) => artifact.artifactClass === artifactClass && artifact.disposition === "included").length;
  for (const artifactClass of ["normalizedSemantics", "revisionLineage", "orientation", "floorPlan", "roomBrief", "redesignIntent"]) {
    if (included(artifactClass) !== 1) throw fail("invalid_manifest");
  }
  if (included("canonicalView") !== 6 || included("providerInstructions") !== 4 || included("selectedReferenceImage") > 64) throw fail("invalid_manifest");
  return Object.freeze(artifacts);
}

function validateAiDisclosureReview(value: unknown, binding: SourceBinding, artifactPlanSHA256: string, selectionSHA256: string): void {
  const review = closedObject(value, ["reviewID", "reviewedAt", "decision", "sourceRevisionID", "sourceRevisionManifestSHA256", "reviewedSelectionSHA256", "preciseGPSExcluded", "rawEvidenceDisclosureAccepted"], ["reviewedArtifactPlanSHA256"]);
  identifier(review.reviewID); timestamp(review.reviewedAt);
  if (enumValue(review.decision, ["approved", "rejected"] as const) !== "approved" || review.preciseGPSExcluded !== true) throw fail("invalid_manifest");
  if (identifier(review.sourceRevisionID) !== binding.revisionID || hex(review.sourceRevisionManifestSHA256, "invalid_manifest") !== binding.revisionManifestSHA256
    || hex(review.reviewedSelectionSHA256, "invalid_manifest") !== selectionSHA256) throw fail("binding_mismatch");
  if (!("reviewedArtifactPlanSHA256" in review) || hex(review.reviewedArtifactPlanSHA256, "invalid_manifest") !== artifactPlanSHA256) throw fail("binding_mismatch");
  if (review.rawEvidenceDisclosureAccepted !== false) throw fail("forbidden_raw_artifact");
}

function allowedAiReadyArtifactPath(artifactClass: string, path: string, declaredMediaType: string): boolean {
  switch (artifactClass) {
    case "normalizedSemantics": return path === "truth/semantic-model.json" && declaredMediaType === "application/json";
    case "revisionLineage": return path === "truth/revision-lineage.json" && declaredMediaType === "application/json";
    case "orientation": return path === "truth/orientation.json" && declaredMediaType === "application/json";
    case "floorPlan": return path === "derivatives/floor-plan.png" && declaredMediaType === "image/png";
    case "canonicalView": return path.startsWith("derivatives/canonical-views/") && path.endsWith(".png") && declaredMediaType === "image/png";
    case "selectedReferenceImage": return path.startsWith("references/") && path.endsWith(".jpg") && declaredMediaType === "image/jpeg";
    case "materials": return path === "appearance/materials.json" && declaredMediaType === "application/json";
    case "qualityReport": return path === "quality/quality-report-carrier.json" && declaredMediaType === "application/json";
    case "roomBrief": return path === "brief/room-brief.txt" && declaredMediaType === "text/plain";
    case "redesignIntent": return path === "intent/redesign-intent.json" && declaredMediaType === "application/json";
    case "providerInstructions": return path.startsWith("instructions/") && path.endsWith(".txt") && declaredMediaType === "text/plain";
    case "mesh": return path.startsWith("geometry/") && ["model/vnd.usdz+zip", "model/gltf-binary", "model/obj", "text/plain", "application/octet-stream"].includes(declaredMediaType);
    case "texture": return path.startsWith("appearance/textures/") && path.endsWith(".png") && declaredMediaType === "image/png";
    default: return false;
  }
}

function validateNestedBackup(bytes: Uint8Array, descriptor: unknown, binding: SourceBinding): void {
  const validatedDescriptor = validateBackupDescriptor(descriptor);
  if (validatedDescriptor.projectID !== binding.projectID || validatedDescriptor.headRevisionID !== binding.revisionID
    || validatedDescriptor.projectSchemaVersion !== binding.packageSchemaVersion
    || validatedDescriptor.archiveSHA256 !== sha256(bytes) || validatedDescriptor.archiveByteCount !== bytes.byteLength) throw fail("binding_mismatch");
  const nested = readZip32Store(bytes);
  rejectForbiddenWorkingEntries(nested);
  const backupManifestEntry = required(nested, "backup-manifest.json");
  const manifest = object(strictJson(backupManifestEntry.bytes), "invalid_manifest");
  requireExactKeys(manifest, ["formatVersion", "projectID", "headRevisionID", "projectSchemaVersion", "revisionCount", "displayName", "sourceUpdatedAt", "integrityScope", "entries"]);
  if (manifest.formatVersion !== "roomscan-project-backup-v1" || manifest.projectID !== binding.projectID
    || manifest.headRevisionID !== binding.revisionID || manifest.projectSchemaVersion !== validatedDescriptor.projectSchemaVersion
    || manifest.revisionCount !== validatedDescriptor.revisionCount || manifest.displayName !== validatedDescriptor.displayName
    || timestamp(manifest.sourceUpdatedAt) !== validatedDescriptor.sourceUpdatedAt
    || manifest.integrityScope !== "allPackageEntriesExceptBackupManifest"
    || validatedDescriptor.manifestSHA256 !== sha256(backupManifestEntry.bytes)) throw fail("binding_mismatch");
  const listed = array(manifest.entries, "invalid_manifest").map((value) => object(value, "invalid_manifest"));
  if (listed.length !== validatedDescriptor.fileCount) throw fail("binding_mismatch");
  const paths = new Set<string>(["backup-manifest.json"]);
  let uncompressedByteCount = 0;
  for (const entry of listed) {
    requireExactKeys(entry, ["archivePath", "byteCount", "mediaType", "packageRelativePath", "sha256Hex"]);
    const path = string(entry.archivePath, "invalid_manifest");
    const actual = required(nested, path);
    const entryByteCount = positive(entry.byteCount, "invalid_manifest");
    uncompressedByteCount += entryByteCount;
    if (!Number.isSafeInteger(uncompressedByteCount) || uncompressedByteCount > 512 * 1_024 * 1_024
      || paths.has(path) || actual.bytes.byteLength !== entryByteCount
      || sha256(actual.bytes) !== hex(entry.sha256Hex, "invalid_manifest")) throw fail("entry_digest");
    paths.add(path);
  }
  if (uncompressedByteCount !== validatedDescriptor.uncompressedByteCount
    || paths.size !== nested.size || [...nested.keys()].some((path) => !paths.has(path))) throw fail("entry_closure");
  const revision = listed.find((entry) => entry.packageRelativePath === `revisions/${binding.revisionID}/revision.json`);
  const semantic = listed.find((entry) => entry.packageRelativePath === `revisions/${binding.revisionID}/semantic-model.json`);
  if (revision === undefined || semantic === undefined || revision.sha256Hex !== binding.revisionManifestSHA256 || semantic.sha256Hex !== binding.semanticSHA256) throw fail("binding_mismatch");
}

/** Complete `RoomCloudBackupDescriptor` grammar. The descriptor is a required
 * top-level working-set value, so comparing only its archive digest would let
 * malformed but otherwise unused values cross the hosted validation boundary. */
function validateBackupDescriptor(value: unknown): ValidatedBackupDescriptor {
  const record = object(value, "invalid_manifest");
  requireExactKeys(record, ["schemaVersion", "snapshotID", "projectID", "headRevisionID", "archiveFormat", "archiveSHA256", "archiveByteCount", "manifestSHA256", "projectSchemaVersion", "revisionCount", "fileCount", "uncompressedByteCount", "displayName", "sourceUpdatedAt", "complete"]);
  if (record.schemaVersion !== "rssb1" || record.archiveFormat !== "roomscan-zip32-store-v1" || record.complete !== true) throw fail("invalid_manifest");
  const snapshotID = hex(record.snapshotID, "invalid_manifest");
  const manifestSHA256 = hex(record.manifestSHA256, "invalid_manifest");
  // Preserve the established outer/nested binding result for a descriptor
  // whose content-addressed snapshot no longer matches its manifest claim.
  if (snapshotID !== manifestSHA256) throw fail("binding_mismatch");
  return Object.freeze({
    snapshotID,
    projectID: identifier(record.projectID),
    headRevisionID: identifier(record.headRevisionID),
    projectSchemaVersion: enumValue(record.projectSchemaVersion, ["room-scan-project-v1", "room-scan-project-v2"] as const),
    displayName: backupDisplayName(record.displayName),
    sourceUpdatedAt: timestamp(record.sourceUpdatedAt),
    revisionCount: backupPositiveInteger(record.revisionCount, Number.MAX_SAFE_INTEGER),
    fileCount: backupPositiveInteger(record.fileCount, 4_095),
    uncompressedByteCount: backupPositiveInteger(record.uncompressedByteCount, 512 * 1_024 * 1_024),
    manifestSHA256,
    archiveSHA256: hex(record.archiveSHA256, "invalid_manifest"),
    archiveByteCount: backupPositiveInteger(record.archiveByteCount, 512 * 1_024 * 1_024),
  });
}

function rejectForbiddenWorkingEntries(entries: ReadonlyMap<string, ZipEntry>): void {
  for (const [path, entry] of entries) {
    if (FORBIDDEN_RAW_PATH.test(path) || containsForbiddenRawBytes(entry.bytes)) throw fail("forbidden_raw_artifact");
  }
}

/** A ZIP32/STORE parser deliberately accepts no data descriptors, ZIP64,
 * compression, symlinks, aliases, duplicate/case-colliding entries, or bytes
 * outside the local+central closure. */
function readZip32Store(input: Uint8Array): ReadonlyMap<string, ZipEntry> {
  if (input.byteLength < 22 || input.byteLength > MAX_ARCHIVE_BYTES) throw fail("zip_structure");
  const eocd = findEocd(input);
  if (eocd < 0 || eocd + 22 !== input.byteLength || u32(input, eocd) !== 0x06054b50) throw fail("zip_structure");
  if (u16(input, eocd + 4) !== 0 || u16(input, eocd + 6) !== 0) throw fail("zip_structure");
  const entryCount = u16(input, eocd + 8);
  if (entryCount !== u16(input, eocd + 10) || entryCount === 0 || entryCount > MAX_ENTRY_COUNT) throw fail("zip_structure");
  const centralBytes = u32(input, eocd + 12);
  const centralOffset = u32(input, eocd + 16);
  if (centralOffset >= eocd || centralOffset + centralBytes !== eocd) throw fail("zip_structure");
  const central: Array<{ readonly path: string; readonly offset: number; readonly crc32: number; readonly bytes: Uint8Array }> = [];
  let cursor = centralOffset;
  const paths = new Set<string>(); const folded = new Set<string>();
  for (let index = 0; index < entryCount; index += 1) {
    if (cursor + 46 > eocd || u32(input, cursor) !== 0x02014b50) throw fail("zip_structure");
    const flags = u16(input, cursor + 8); const method = u16(input, cursor + 10);
    const crc = u32(input, cursor + 16); const compressed = u32(input, cursor + 20); const uncompressed = u32(input, cursor + 24);
    const nameLength = u16(input, cursor + 28); const extraLength = u16(input, cursor + 30); const commentLength = u16(input, cursor + 32);
    const disk = u16(input, cursor + 34); const external = u32(input, cursor + 38); const offset = u32(input, cursor + 42);
    const end = cursor + 46 + nameLength + extraLength + commentLength;
    if (end > eocd || (flags !== 0 && flags !== 0x0800) || method !== 0 || compressed !== uncompressed
      || compressed > MAX_ENTRY_BYTES || disk !== 0 || extraLength !== 0 || commentLength !== 0 || isSymlink(external)) throw fail("zip_structure");
    const path = decodePath(input.subarray(cursor + 46, cursor + 46 + nameLength));
    if (!safePath(path)) throw fail("unsafe_path");
    const key = path.toLocaleLowerCase("en-US");
    if (paths.has(path) || folded.has(key)) throw fail("duplicate_entry");
    paths.add(path); folded.add(key);
    central.push({ path, offset, crc32: crc, bytes: input.subarray(0, 0) });
    cursor = end;
  }
  if (cursor !== eocd) throw fail("zip_structure");
  let localCursor = 0;
  for (const meta of [...central].sort((left, right) => left.offset - right.offset)) {
    if (meta.offset !== localCursor || meta.offset + 30 > centralOffset || u32(input, meta.offset) !== 0x04034b50) throw fail("zip_structure");
    const flags = u16(input, meta.offset + 6); const method = u16(input, meta.offset + 8);
    const crc = u32(input, meta.offset + 14); const compressed = u32(input, meta.offset + 18); const uncompressed = u32(input, meta.offset + 22);
    const nameLength = u16(input, meta.offset + 26); const extraLength = u16(input, meta.offset + 28);
    const path = decodePath(input.subarray(meta.offset + 30, meta.offset + 30 + nameLength));
    const bodyStart = meta.offset + 30 + nameLength + extraLength; const bodyEnd = bodyStart + compressed;
    if ((flags !== 0 && flags !== 0x0800) || method !== 0 || extraLength !== 0 || path !== meta.path
      || crc !== meta.crc32 || compressed !== uncompressed || bodyEnd > centralOffset) throw fail("zip_structure");
    const bytes = input.subarray(bodyStart, bodyEnd);
    if (crc32(bytes) !== crc) throw fail("entry_digest");
    // `subarray` is a bounded view into the exact archive; copying every ZIP
    // entry would multiply a valid 64 MiB archive's worker memory footprint.
    (meta as { bytes: Uint8Array }).bytes = bytes;
    localCursor = bodyEnd;
  }
  if (localCursor !== centralOffset) throw fail("zip_structure");
  return new Map(central.map((entry) => [entry.path, Object.freeze({ path: entry.path, bytes: entry.bytes, crc32: entry.crc32 })]));
}

function findEocd(input: Uint8Array): number {
  for (let offset = input.byteLength - 22; offset >= Math.max(0, input.byteLength - 65_557); offset -= 1) {
    if (u32(input, offset) === 0x06054b50) return offset;
  }
  return -1;
}

function strictJson(bytes: Uint8Array): unknown {
  let source: string;
  try { source = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { throw fail("invalid_json"); }
  const parser = new StrictJsonParser(source);
  const value = parser.parse();
  // Foundation's historical backup encoder escapes solidus while the current
  // working-set encoder does not. Both are the same canonical value and must
  // remain readable; no whitespace, duplicate key, or alternate ordering is
  // accepted.
  const canonical = canonicalJson(value);
  if (canonical !== source && canonical.replaceAll("/", "\\/") !== source) throw fail("noncanonical_json");
  return value;
}

class StrictJsonParser {
  #offset = 0;
  constructor(private readonly source: string) {}

  parse(): unknown { const value = this.value(); if (this.#offset !== this.source.length) throw fail("invalid_json"); return value; }
  value(): unknown {
    const next = this.source[this.#offset];
    if (next === "{") return this.record(); if (next === "[") return this.list(); if (next === '"') return this.text();
    if (next === "t" && this.consume("true")) return true; if (next === "f" && this.consume("false")) return false; if (next === "n" && this.consume("null")) return null;
    if (next === "-" || (next !== undefined && next >= "0" && next <= "9")) return this.number();
    throw fail("invalid_json");
  }
  record(): Readonly<Record<string, unknown>> {
    this.#offset += 1; const output: Record<string, unknown> = {}; const keys = new Set<string>();
    if (this.source[this.#offset] === "}") { this.#offset += 1; return output; }
    while (true) {
      if (this.source[this.#offset] !== '"') throw fail("invalid_json"); const key = this.text();
      if (keys.has(key) || this.source[this.#offset] !== ":") throw fail("invalid_json"); keys.add(key); this.#offset += 1; output[key] = this.value();
      const next = this.source[this.#offset]; if (next === "}") { this.#offset += 1; return output; } if (next !== ",") throw fail("invalid_json"); this.#offset += 1;
    }
  }
  list(): readonly unknown[] {
    this.#offset += 1; const output: unknown[] = []; if (this.source[this.#offset] === "]") { this.#offset += 1; return output; }
    while (true) { output.push(this.value()); const next = this.source[this.#offset]; if (next === "]") { this.#offset += 1; return output; } if (next !== ",") throw fail("invalid_json"); this.#offset += 1; }
  }
  text(): string {
    const start = this.#offset; this.#offset += 1; let escaped = false;
    while (this.#offset < this.source.length) { const code = this.source.charCodeAt(this.#offset); const char = this.source[this.#offset]!; this.#offset += 1; if (escaped) { escaped = false; continue; } if (char === "\\") { escaped = true; continue; } if (char === '"') { try { return JSON.parse(this.source.slice(start, this.#offset)) as string; } catch { throw fail("invalid_json"); } } if (code < 0x20) throw fail("invalid_json"); }
    throw fail("invalid_json");
  }
  number(): number {
    const remaining = this.source.slice(this.#offset); const match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/u.exec(remaining);
    if (match?.[0] === undefined) throw fail("invalid_json"); this.#offset += match[0].length; const value = Number(match[0]); if (!Number.isFinite(value)) throw fail("invalid_json"); return value;
  }
  consume(value: string): boolean { if (!this.source.startsWith(value, this.#offset)) return false; this.#offset += value.length; return true; }
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "number" || typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const record = value as Readonly<Record<string, unknown>>;
    return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(",")}}`;
  }
  throw fail("invalid_json");
}

function workingManifestEntries(value: unknown): readonly ManifestEntry[] {
  const values = array(value, "invalid_manifest"); const paths = new Set<string>(); let previousPath = "";
  if (values.length === 0) throw fail("entry_closure");
  return values.map((entry) => {
    const record = object(entry, "invalid_manifest");
    requireExactKeys(record, ["path", "kind", "mediaType", "byteCount", "sha256"]);
    const path = string(record.path, "invalid_manifest");
    const mediaType = string(record.mediaType, "invalid_manifest");
    if (!safePath(path) || paths.has(path) || path <= previousPath || mediaType.trim().length === 0) throw fail("entry_closure");
    paths.add(path); previousPath = path;
    const kindRecord = object(record.kind, "invalid_manifest");
    // Core encodes an injected raw entry with `rawAssetClass`. Recognize that
    // exact shape only so it is rejected as raw, rather than accidentally
    // treating a well-formed hostile ledger as an unrelated schema error.
    if (kindRecord.type === "raw") {
      requireExactKeys(kindRecord, ["type", "rawAssetClass"]);
      if (!validRawClass(string(kindRecord.rawAssetClass, "invalid_manifest"))) throw fail("invalid_manifest");
      throw fail("forbidden_raw_artifact");
    }
    requireExactKeys(kindRecord, ["type"]);
    const kind = workingKind(kindRecord.type);
    if (!validWorkingPath(kind, path)) throw fail("entry_closure");
    return Object.freeze({ path, byteCount: positive(record.byteCount, "invalid_manifest"), sha256: hex(record.sha256, "invalid_manifest"), kind, mediaType });
  });
}

function rawManifestEntries(value: unknown): readonly ManifestEntry[] {
  const values = array(value, "invalid_manifest"); const paths = new Set<string>(); const assetIDs = new Set<string>(); let previousPath = "";
  if (values.length === 0) throw fail("invalid_manifest");
  return values.map((entry) => {
    const record = object(entry, "invalid_manifest");
    requireExactKeys(record, ["assetID", "assetClass", "path", "mediaType", "byteCount", "sha256"]);
    const assetClass = string(record.assetClass, "invalid_manifest"); const path = string(record.path, "invalid_manifest"); const assetID = identifier(record.assetID);
    const mediaType = string(record.mediaType, "invalid_manifest");
    if (!validRawClass(assetClass) || !safePath(path) || !path.startsWith(`raw/${assetClass}-`) || paths.has(path) || assetIDs.has(assetID)
      || path <= previousPath || mediaType.trim().length === 0) throw fail("invalid_manifest");
    paths.add(path); assetIDs.add(assetID); previousPath = path;
    return Object.freeze({ path, byteCount: positive(record.byteCount, "invalid_manifest"), sha256: hex(record.sha256, "invalid_manifest"), assetClass, assetID, mediaType });
  });
}

function sourceBinding(value: unknown): SourceBinding {
  const record = object(value, "invalid_manifest");
  requireExactKeys(record, ["projectID", "revisionID", "coordinateSpaceEpochID", "packageSchemaVersion", "revisionManifestSHA256", "semanticSHA256"]);
  const packageSchemaVersion = enumValue(record.packageSchemaVersion, ["room-scan-project-v1", "room-scan-project-v2"] as const);
  return Object.freeze({
    projectID: identifier(record.projectID), revisionID: identifier(record.revisionID), coordinateSpaceEpochID: identifier(record.coordinateSpaceEpochID),
    packageSchemaVersion, revisionManifestSHA256: hex(record.revisionManifestSHA256, "invalid_manifest"), semanticSHA256: hex(record.semanticSHA256, "invalid_manifest"),
  });
}

function sameBinding(left: SourceBinding, right: SourceBinding): boolean { return left.projectID === right.projectID && left.revisionID === right.revisionID && left.coordinateSpaceEpochID === right.coordinateSpaceEpochID && left.packageSchemaVersion === right.packageSchemaVersion && left.revisionManifestSHA256 === right.revisionManifestSHA256 && left.semanticSHA256 === right.semanticSHA256; }
function workingKind(value: unknown): WorkingEntryKind {
  if (value === "packageBackup" || value === "redesignCompanion" || value === "conceptSetManifest" || value === "conceptSetAttachment" || value === "conceptSourcePackageProvenance") return value;
  // A default working set must not silently accept a raw entry kind even if
  // its path happens to avoid a detector keyword.
  throw fail(value === "raw" ? "forbidden_raw_artifact" : "invalid_manifest");
}
function validWorkingPath(kind: WorkingEntryKind, path: string): boolean {
  if (kind === "packageBackup") return path === "package-backup.zip";
  if (kind === "redesignCompanion") return path === "companions/redesign.json";
  if (kind === "conceptSetManifest") return /^companions\/concept-sets\/[A-Za-z0-9_-]{1,128}\/manifest\.json$/u.test(path);
  if (kind === "conceptSetAttachment") return /^companions\/concept-sets\/[A-Za-z0-9_-]{1,128}\/attachments\/[A-Za-z0-9._-]{1,256}$/u.test(path);
  return /^companions\/concept-source-packages\/[A-Za-z0-9_-]{1,128}\/manifest\.json$/u.test(path);
}
function conceptSetIdFromManifestPath(path: string): string {
  const match = /^companions\/concept-sets\/([A-Za-z0-9_-]{1,128})\/manifest\.json$/u.exec(path);
  if (match?.[1] === undefined) throw fail("entry_closure");
  return match[1];
}
function conceptPackageIdFromProvenancePath(path: string): string {
  const match = /^companions\/concept-source-packages\/([A-Za-z0-9_-]{1,128})\/manifest\.json$/u.exec(path);
  if (match?.[1] === undefined) throw fail("entry_closure");
  return match[1];
}
function forbiddenArtifactRecord(record: Readonly<Record<string, unknown>>): boolean {
  const artifactClass = typeof record.artifactClass === "string" ? record.artifactClass : "";
  const relativePath = typeof record.relativePath === "string" ? record.relativePath : "";
  return /^(?:rgb|depth|confidence|diagnostic|worldMap)$/u.test(artifactClass) || FORBIDDEN_RAW_PATH.test(relativePath);
}
function validRawClass(value: string | undefined): boolean { return value === "rgb" || value === "depth" || value === "confidence" || value === "diagnostics" || value === "worldMap"; }
function required(entries: ReadonlyMap<string, ZipEntry>, path: string): ZipEntry { const entry = entries.get(path); if (entry === undefined) throw fail("entry_closure"); return entry; }
function validExpectation(value: unknown): value is ProjectSyncArchiveExpectation {
  if (value === null || typeof value !== "object") return false;
  const record = value as Readonly<Record<string, unknown>>;
  return typeof record.projectId === "string" && SAFE_ID.test(record.projectId)
    && typeof record.sourceRevisionId === "string" && SAFE_ID.test(record.sourceRevisionId)
    && typeof record.manifestSha256 === "string" && SHA256.test(record.manifestSha256)
    && (record.reviewSha256 === undefined || (typeof record.reviewSha256 === "string" && SHA256.test(record.reviewSha256)))
    && typeof record.sha256 === "string" && SHA256.test(record.sha256)
    && typeof record.byteCount === "number" && Number.isSafeInteger(record.byteCount)
    && record.byteCount > 0 && record.byteCount <= MAX_ARCHIVE_BYTES;
}
function bindingForCanonicalJson(binding: SourceBinding): Readonly<Record<string, string>> { return Object.freeze({ projectID: binding.projectID, revisionID: binding.revisionID, coordinateSpaceEpochID: binding.coordinateSpaceEpochID, packageSchemaVersion: binding.packageSchemaVersion, revisionManifestSHA256: binding.revisionManifestSHA256, semanticSHA256: binding.semanticSHA256 }); }
function requireExactKeys(record: Readonly<Record<string, unknown>>, keys: readonly string[]): void { const expected = new Set(keys); if (Object.keys(record).length !== expected.size || Object.keys(record).some((key) => !expected.has(key))) throw fail("invalid_manifest"); }
/** Match Core's strict JSON decoders: declared compatibility is a closed
 * schema, not an invitation to retain future opaque payload fields. */
function closedObject(value: unknown, required: readonly string[], optional: readonly string[] = []): Readonly<Record<string, unknown>> {
  const record = object(value, "invalid_manifest");
  const allowed = new Set([...required, ...optional]);
  if (Object.keys(record).some((key) => !allowed.has(key)) || required.some((key) => !(key in record))) throw fail("invalid_manifest");
  return record;
}
function optionalClosedObject(record: Readonly<Record<string, unknown>>, key: string, required: readonly string[], optional: readonly string[] = []): Readonly<Record<string, unknown>> | undefined {
  if (!(key in record)) return undefined;
  return closedObject(record[key], required, optional);
}
function enumValue<T extends string>(value: unknown, allowed: readonly T[]): T {
  if (typeof value !== "string" || !allowed.some((candidate) => candidate === value)) throw fail("invalid_manifest");
  return value as T;
}
function boundedArray(value: unknown, minimum: number, maximum: number): readonly unknown[] {
  const values = array(value, "invalid_manifest");
  if (values.length < minimum || values.length > maximum) throw fail("invalid_manifest");
  return values;
}
function unique<T>(values: readonly T[]): void { if (new Set(values).size !== values.length) throw fail("invalid_manifest"); }
function finiteRange(value: unknown, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) throw fail("invalid_manifest");
  return value;
}
function between(value: number, minimum: number, maximum: number): boolean { return value >= minimum && value <= maximum; }
function integerRange(value: unknown, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw fail("invalid_manifest");
  return value;
}
function point(value: unknown): Vector3 {
  const vector = closedObject(value, ["x", "y", "z"]);
  return Object.freeze({ x: finiteRange(vector.x, -10_000, 10_000), y: finiteRange(vector.y, -10_000, 10_000), z: finiteRange(vector.z, -10_000, 10_000) });
}
function length(vector: Vector3): number { return Math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z); }
function unit(value: unknown): Vector3 {
  const vector = point(value);
  if (Math.abs(length(vector) - 1) > 0.000_1) throw fail("invalid_manifest");
  return vector;
}
function horizontalUnit(value: unknown): Vector3 {
  const vector = unit(value);
  if (Math.abs(vector.y) > 0.000_1) throw fail("invalid_manifest");
  return vector;
}
function normalizedHorizontal(value: unknown): Vector3 {
  const vector = point(value); const magnitude = Math.sqrt(vector.x * vector.x + vector.z * vector.z);
  if (!Number.isFinite(magnitude) || magnitude <= 0.001) throw fail("invalid_manifest");
  return Object.freeze({ x: vector.x / magnitude, y: 0, z: vector.z / magnitude });
}
function cross(left: Vector3, right: Vector3): Vector3 { return Object.freeze({ x: left.y * right.z - left.z * right.y, y: left.z * right.x - left.x * right.z, z: left.x * right.y - left.y * right.x }); }
function approximatelyEqual(left: Vector3, right: Vector3): boolean { return Math.abs(left.x - right.x) <= 0.000_1 && Math.abs(left.y - right.y) <= 0.000_1 && Math.abs(left.z - right.z) <= 0.000_1; }
function spatialText(value: unknown, maximum: number): string {
  if (typeof value !== "string" || value.trim().length === 0 || Array.from(CORE_GRAPHEME_SEGMENTER.segment(value)).length > maximum || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) throw fail("invalid_manifest");
  return value;
}
function backupDisplayName(value: unknown): string {
  if (typeof value !== "string" || value.trim().length === 0 || Buffer.byteLength(value, "utf8") > 240 || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) throw fail("invalid_manifest");
  return value;
}
function conceptText(value: unknown, maximumUTF8Bytes: number): string {
  if (typeof value !== "string" || value.trim().length === 0 || Buffer.byteLength(value, "utf8") > maximumUTF8Bytes) throw fail("invalid_manifest");
  return value;
}
function portableFilename(value: unknown): string {
  if (typeof value !== "string" || Buffer.byteLength(value, "utf8") > 255 || value === "." || value === ".." || !/^[A-Za-z0-9._-]+$/u.test(value)) throw fail("invalid_manifest");
  return value;
}
function coreRelativePath(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || value.startsWith("/") || value.startsWith("\\") || value.includes("\\") || value.includes(":")
    || !Array.from(value).every((character) => {
      const code = character.codePointAt(0) ?? 0;
      return code <= 0x7f && code >= 0x20 && code !== 0x7f;
    }) || value.split("/").some((part) => part.length === 0 || part === "." || part === "..")) throw fail("invalid_manifest");
  return value;
}
function conceptAttachmentPath(value: unknown): string {
  const path = coreRelativePath(value);
  if (Buffer.byteLength(path, "utf8") > 255 || !/^[A-Za-z0-9._/-]+$/u.test(path) || !path.startsWith("attachments/") || path.split("/").length !== 2) throw fail("invalid_manifest");
  return path;
}
function mediaType(value: unknown): string {
  if (typeof value !== "string" || Array.from(value).length > 127 || !value.includes("/") || !/^[\x21-\x7e]+$/u.test(value)) throw fail("invalid_manifest");
  return value;
}
function positiveContractAsset(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0 || value > MAX_CONTRACT_ASSET_BYTES) throw fail("invalid_manifest");
  return value;
}
function positiveConceptAttachment(value: unknown): number {
  const byteCount = positiveContractAsset(value);
  if (byteCount > 32 * 1_024 * 1_024) throw fail("invalid_manifest");
  return byteCount;
}
function artifactClassValue(value: unknown): string { return enumValue(value, AI_ARTIFACT_CLASSES); }
function optionalIdentifier(record: Readonly<Record<string, unknown>>, key: string): string | undefined { return key in record ? identifier(record[key]) : undefined; }
function timestamp(value: unknown): number {
  if (typeof value !== "string" || !canonicalTimestamp(value)) throw fail("invalid_manifest");
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) throw fail("invalid_manifest");
  return milliseconds;
}
function canonicalTimestamp(value: unknown): boolean {
  if (typeof value !== "string") return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{3}))?Z$/u.exec(value);
  if (match === null) return false;
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) && parsed.getUTCFullYear() === Number(match[1]) && parsed.getUTCMonth() + 1 === Number(match[2])
    && parsed.getUTCDate() === Number(match[3]) && parsed.getUTCHours() === Number(match[4]) && parsed.getUTCMinutes() === Number(match[5]) && parsed.getUTCSeconds() === Number(match[6]);
}
function identifier(value: unknown): string { if (typeof value !== "string" || !SAFE_ID.test(value)) throw fail("invalid_manifest"); return value; }
function object(value: unknown, code: ProjectSyncArchiveValidationCode): Readonly<Record<string, unknown>> { if (value === null || typeof value !== "object" || Array.isArray(value)) throw fail(code); return value as Readonly<Record<string, unknown>>; }
function array(value: unknown, code: ProjectSyncArchiveValidationCode): readonly unknown[] { if (!Array.isArray(value)) throw fail(code); return value; }
function string(value: unknown, code: ProjectSyncArchiveValidationCode): string { if (typeof value !== "string" || value.length === 0 || value.length > 4096) throw fail(code); return value; }
function positive(value: unknown, code: ProjectSyncArchiveValidationCode): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0 || value > MAX_ENTRY_BYTES) throw fail(code); return value; }
function backupPositiveInteger(value: unknown, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0 || value > maximum) throw fail("invalid_manifest");
  return value;
}
function hex(value: unknown, code: ProjectSyncArchiveValidationCode): string { if (typeof value !== "string" || !SHA256.test(value)) throw fail(code); return value; }
function safePath(path: string): boolean { return path.length >= 1 && path.length <= 512 && /^[A-Za-z0-9._/-]+$/u.test(path) && !path.startsWith("/") && !path.endsWith("/") && !path.split("/").some((part) => part.length === 0 || part === "." || part === ".."); }
function safeRelativePath(path: string): boolean { return path.length >= 1 && path.length <= 256 && safePath(path); }
function decodePath(bytes: Uint8Array): string { try { const path = new TextDecoder("utf-8", { fatal: true }).decode(bytes); if (Buffer.byteLength(path, "utf8") !== bytes.byteLength) throw new Error(); return path; } catch { throw fail("unsafe_path"); } }
function isSymlink(external: number): boolean { return ((external >>> 16) & 0xf000) === 0xa000; }
function u16(bytes: Uint8Array, offset: number): number { return (bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8); }
function u32(bytes: Uint8Array, offset: number): number { return (((bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8) | ((bytes[offset + 2] ?? 0) << 16) | ((bytes[offset + 3] ?? 0) << 24)) >>> 0); }
function sha256(bytes: Uint8Array): string { return createHash("sha256").update(bytes).digest("hex"); }
function fail(code: ProjectSyncArchiveValidationCode): ProjectSyncArchiveValidationError { return new ProjectSyncArchiveValidationError(code); }

const CRC_TABLE = (() => { const table = new Uint32Array(256); for (let index = 0; index < 256; index += 1) { let current = index; for (let bit = 0; bit < 8; bit += 1) current = (current & 1) === 1 ? (current >>> 1) ^ 0xedb88320 : current >>> 1; table[index] = current >>> 0; } return table; })();
function crc32(bytes: Uint8Array): number { let current = 0xffffffff; for (const byte of bytes) current = (CRC_TABLE[(current ^ byte) & 0xff] ?? 0) ^ (current >>> 8); return (current ^ 0xffffffff) >>> 0; }
