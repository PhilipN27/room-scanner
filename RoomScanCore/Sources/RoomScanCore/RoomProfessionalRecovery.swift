import Foundation

/// Fail-closed errors for the additive, local-only companion recovery
/// primitives. These values never recover or rewrite a room package; they
/// only stage revision-bound redesign and Concept Set companion state.
public enum RoomProfessionalRecoveryError: Error, Sendable, Equatable {
    case invalidMapping(String)
    case invalidSnapshot(String)
    case sourceRevisionMismatch(String)
    case existingStateConflict(String)
}

/// Explicit caller intent for recover-as-copy. The public initializer proves
/// only distinct safe project IDs; it deliberately cannot authorize a source
/// rebind by itself. A rebind additionally requires the internal, validated
/// source-pair proof made from the actual promoted package by
/// `LocalRoomProjectStore`.
public struct RoomProfessionalRecoveredCopyMapping: Sendable, Equatable {
    public let originalProjectID: String
    public let recoveredCopyProjectID: String
    private let originalSourceRevision: RoomRedesignSourceRevision?
    private let recoveredCopySourceRevision: RoomRedesignSourceRevision?

    public init(
        originalProjectID: String,
        recoveredCopyProjectID: String
    ) throws {
        guard RoomPathValidation.isSafeStableIdentifier(originalProjectID),
              RoomPathValidation.isSafeStableIdentifier(recoveredCopyProjectID),
              originalProjectID != recoveredCopyProjectID
        else {
            throw RoomProfessionalRecoveryError.invalidMapping(
                "Recovered-copy mappings require distinct stable project identifiers."
            )
        }
        self.originalProjectID = originalProjectID
        self.recoveredCopyProjectID = recoveredCopyProjectID
        originalSourceRevision = nil
        recoveredCopySourceRevision = nil
    }

    private init(
        originalSourceRevision: RoomRedesignSourceRevision,
        recoveredCopySourceRevision: RoomRedesignSourceRevision
    ) {
        originalProjectID = originalSourceRevision.projectID
        recoveredCopyProjectID = recoveredCopySourceRevision.projectID
        self.originalSourceRevision = originalSourceRevision
        self.recoveredCopySourceRevision = recoveredCopySourceRevision
    }

    /// Only Core's package-first coordinator can create this authority after
    /// it reads the recovered copy from the real validated package boundary.
    /// Copy promotion changes the project ID inside semantic/revision JSON, so
    /// those two digests are intentionally derived here rather than supplied
    /// by a caller or assumed to equal the original values.
    static func storeDerived(
        original: RoomRedesignSourceRevision,
        recoveredCopy: RoomRedesignSourceRevision
    ) throws -> RoomProfessionalRecoveredCopyMapping {
        try original.validate()
        try recoveredCopy.validate()
        guard RoomPathValidation.isSafeStableIdentifier(original.projectID),
              RoomPathValidation.isSafeStableIdentifier(recoveredCopy.projectID),
              original.projectID != recoveredCopy.projectID,
              original.revisionID == recoveredCopy.revisionID,
              original.coordinateSpaceEpochID == recoveredCopy.coordinateSpaceEpochID,
              original.packageSchemaVersion == recoveredCopy.packageSchemaVersion
        else {
            throw RoomProfessionalRecoveryError.invalidMapping(
                "A recovered-copy binding must come from distinct projects with the same validated revision, epoch, and schema."
            )
        }
        return RoomProfessionalRecoveredCopyMapping(
            originalSourceRevision: original,
            recoveredCopySourceRevision: recoveredCopy
        )
    }

    func reboundSourceRevision(
        from original: RoomRedesignSourceRevision,
        expectedRecoveredCopy: RoomRedesignSourceRevision
    ) throws -> RoomRedesignSourceRevision {
        try original.validate()
        try expectedRecoveredCopy.validate()
        guard let originalSourceRevision,
              let recoveredCopySourceRevision,
              originalSourceRevision == original,
              recoveredCopySourceRevision == expectedRecoveredCopy,
              original.projectID == originalProjectID,
              expectedRecoveredCopy.projectID == recoveredCopyProjectID,
              original.revisionID == expectedRecoveredCopy.revisionID,
              original.coordinateSpaceEpochID == expectedRecoveredCopy.coordinateSpaceEpochID,
              original.packageSchemaVersion == expectedRecoveredCopy.packageSchemaVersion
        else {
            throw RoomProfessionalRecoveryError.invalidMapping(
                "Recovered-copy rebinding requires the exact store-derived source and destination package bindings."
            )
        }
        return expectedRecoveredCopy
    }
}

/// A deliberate transport/recovery downgrade of an automatic Concept mapping.
/// It is presentation metadata for the caller, while the enclosing canonical
/// Concept manifest remains the persisted source of truth.
public struct RoomProfessionalConceptMappingAdjustment: Codable, Sendable, Equatable {
    public let conceptSetID: String
    public let attachmentID: String
    public let from: RoomConceptAttachmentMapping
    public let to: RoomConceptAttachmentMapping

    public init(
        conceptSetID: String,
        attachmentID: String,
        from: RoomConceptAttachmentMapping,
        to: RoomConceptAttachmentMapping
    ) throws {
        self.conceptSetID = conceptSetID
        self.attachmentID = attachmentID
        self.from = from
        self.to = to
        try validate()
    }

    public func validate() throws {
        guard RoomPathValidation.isSafeStableIdentifier(conceptSetID),
              RoomPathValidation.isSafeStableIdentifier(attachmentID),
              from.status == .automatic,
              let cameraID = from.cameraID
        else {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Concept mapping adjustment must identify one automatic source attachment."
            )
        }
        switch to.status {
        case .manual:
            guard to.cameraID == cameraID else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Automatic-to-manual adjustment must retain the claimed camera identifier."
                )
            }
        case .unmatched:
            guard to.cameraID == nil else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Automatic-to-unmatched adjustment must omit its camera identifier."
                )
            }
        case .automatic:
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "An automatic mapping adjustment must make a non-automatic result explicit."
            )
        }
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["conceptSetID", "attachmentID", "from", "to"],
            required: ["conceptSetID", "attachmentID", "from", "to"]
        )
        conceptSetID = try container.decode(String.self, forKey: .init("conceptSetID"))
        attachmentID = try container.decode(String.self, forKey: .init("attachmentID"))
        from = try container.decode(RoomConceptAttachmentMapping.self, forKey: .init("from"))
        to = try container.decode(RoomConceptAttachmentMapping.self, forKey: .init("to"))
        try validate()
    }
}

/// Exact canonical AI-ready package-manifest bytes retained solely as the
/// independently validated authority for automatic Concept mappings. It never
/// carries package artifacts; `.complete` manifests are intentionally refused
/// because their raw ledger is forbidden from the default working-set path.
public struct RoomProfessionalConceptSourcePackageProvenanceSnapshot: Sendable, Equatable {
    public let sourceRevision: RoomRedesignSourceRevision
    public let sourceAIRoomPackage: RoomConceptSourceAIRoomPackage
    public let canonicalManifestData: Data
    public let manifestSHA256: String

    public init(
        sourceRevision: RoomRedesignSourceRevision,
        canonicalManifestData: Data
    ) throws {
        self.sourceRevision = sourceRevision
        self.canonicalManifestData = canonicalManifestData
        manifestSHA256 = RoomSHA256.hexDigest(of: canonicalManifestData)
        let validated = try Self.validatedPackage(from: canonicalManifestData)
        guard validated.package.sourceRevision == sourceRevision,
              validated.package.profile == .aiReady
        else {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Working-set Concept provenance must be one exact source-bound AI-ready package manifest."
            )
        }
        sourceAIRoomPackage = validated.capability.sourceAIRoomPackage
    }

    public func validatedSourcePackage() throws -> RoomConceptValidatedSourcePackage {
        let validated = try Self.validatedPackage(from: canonicalManifestData)
        guard manifestSHA256 == RoomSHA256.hexDigest(of: canonicalManifestData),
              validated.package.profile == .aiReady,
              validated.package.sourceRevision == sourceRevision,
              validated.capability.sourceAIRoomPackage == sourceAIRoomPackage
        else {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "AI-ready Concept provenance bytes no longer match their validated binding."
            )
        }
        return validated.capability
    }

    public func workingSetCompanion() throws -> RoomProfessionalWorkingSetCompanion {
        _ = try validatedSourcePackage()
        return try RoomProfessionalWorkingSetCompanion(
            sourceRevision: sourceRevision,
            path: "companions/concept-source-packages/\(sourceAIRoomPackage.packageID)/manifest.json",
            kind: .conceptSourcePackageProvenance,
            mediaType: "application/json",
            data: canonicalManifestData
        )
    }

    static func validatedPackage(
        from data: Data
    ) throws -> (package: RoomAIRoomPackage, capability: RoomConceptValidatedSourcePackage) {
        do {
            guard case let .aiRoomPackage(package) = try RoomRedesignContractValidator.validate(data: data),
                  try RoomRedesignCanonicalJSON.encode(package) == data
            else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Concept provenance must be a canonical AI Room Package manifest."
                )
            }
            let capability = try RoomConceptValidatedSourcePackage(validatedManifestData: data)
            guard capability.sourceRevision == package.sourceRevision,
                  capability.sourceAIRoomPackage.schemaVersion == package.schemaVersion,
                  capability.sourceAIRoomPackage.packageID == package.packageID
            else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Concept provenance capability does not match its canonical AI Room Package manifest."
                )
            }
            return (package, capability)
        } catch let error as RoomProfessionalRecoveryError {
            throw error
        } catch {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Concept provenance must be duplicate-safe canonical AI Room Package bytes."
            )
        }
    }
}

/// A source-bound envelope input that keeps transformed Concept companion
/// bytes and their UI-visible mapping adjustments together until the outer
/// working-set manifest commits both facts.
public struct RoomProfessionalWorkingSetCompanionPreparation: Sendable, Equatable {
    public let sourceRevision: RoomRedesignSourceRevision
    public let companions: [RoomProfessionalWorkingSetCompanion]
    public let conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]

    public init(
        sourceRevision: RoomRedesignSourceRevision,
        companions: [RoomProfessionalWorkingSetCompanion],
        conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]
    ) throws {
        self.sourceRevision = sourceRevision
        self.companions = companions.sorted { $0.path < $1.path }
        self.conceptMappingAdjustments = conceptMappingAdjustments.sorted {
            if $0.conceptSetID != $1.conceptSetID { return $0.conceptSetID < $1.conceptSetID }
            return $0.attachmentID < $1.attachmentID
        }
        try validate()
    }

    public func validate() throws {
        try sourceRevision.validate()
        var paths = Set<String>()
        for companion in companions {
            try companion.validate()
            guard companion.sourceRevision == sourceRevision,
                  paths.insert(companion.path.lowercased()).inserted
            else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Working-set companion preparation has mismatched source bindings or colliding paths."
                )
            }
        }
        guard conceptMappingAdjustments == conceptMappingAdjustments.sorted(by: {
            if $0.conceptSetID != $1.conceptSetID { return $0.conceptSetID < $1.conceptSetID }
            return $0.attachmentID < $1.attachmentID
        })
        else {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Working-set Concept mapping adjustments must use stable Concept Set and attachment order."
            )
        }
        var adjustmentIDs = Set<String>()
        for adjustment in conceptMappingAdjustments {
            try adjustment.validate()
            guard adjustmentIDs.insert("\(adjustment.conceptSetID)/\(adjustment.attachmentID)").inserted else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Working-set Concept mapping adjustments must be unique."
                )
            }
        }
    }
}

/// Transport-only Concept snapshot preparation. It uses exact canonical
/// package manifests for AI-ready automatic mappings and never mutates the
/// caller's live Concept snapshot. Any automatic mapping without transportable
/// AI-ready authority is downgraded deterministically.
public struct RoomProfessionalConceptTransportSnapshot: Sendable, Equatable {
    public let conceptSnapshot: RoomProfessionalConceptSnapshot
    public let sourcePackageProvenance: [RoomProfessionalConceptSourcePackageProvenanceSnapshot]
    public let conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]

    public init(
        sourceSnapshot: RoomProfessionalConceptSnapshot,
        sourcePackageManifestData: [Data],
        currentCanonicalCameraIDs: [String]
    ) throws {
        try sourceSnapshot.validateStructure()
        let sourceRevision = sourceSnapshot.sourceRevision
        let cameraIDs = try Self.validatedCameraIDs(currentCanonicalCameraIDs)
        var packagesByID: [String: (RoomAIRoomPackage, RoomConceptValidatedSourcePackage, Data)] = [:]
        for data in sourcePackageManifestData {
            let validated = try RoomProfessionalConceptSourcePackageProvenanceSnapshot.validatedPackage(from: data)
            guard validated.package.sourceRevision == sourceRevision else {
                throw RoomProfessionalRecoveryError.sourceRevisionMismatch(
                    "Concept transport provenance must bind the Concept snapshot's exact source revision."
                )
            }
            let key = validated.package.packageID.lowercased()
            guard packagesByID[key] == nil else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Concept transport provenance package identifiers must be unique without case collisions."
                )
            }
            packagesByID[key] = (validated.package, validated.capability, data)
        }

        var transportSets: [RoomProfessionalConceptSetSnapshot] = []
        var requiredAIReadyPackageIDs = Set<String>()
        var adjustments: [RoomProfessionalConceptMappingAdjustment] = []
        for snapshot in sourceSnapshot.conceptSets {
            let concept = try snapshot.validatedConcept()
            var transformedAttachments: [RoomConceptSetAttachment] = []
            for attachment in concept.attachments {
                guard attachment.mapping.status == .automatic,
                      let cameraID = attachment.mapping.cameraID
                else {
                    transformedAttachments.append(attachment)
                    continue
                }
                let claimedPackage = concept.sourceAIRoomPackage
                let candidate = claimedPackage.flatMap { packagesByID[$0.packageID.lowercased()] }
                let preservesAutomatic = candidate.map { package, capability, _ in
                    package.profile == .aiReady
                        && capability.sourceAIRoomPackage == claimedPackage
                        && capability.canonicalCameraIDs.contains(cameraID)
                        && cameraIDs.contains(cameraID)
                } ?? false
                if preservesAutomatic {
                    requiredAIReadyPackageIDs.insert(claimedPackage!.packageID.lowercased())
                    transformedAttachments.append(attachment)
                    continue
                }

                let replacement: RoomConceptAttachmentMapping = cameraIDs.contains(cameraID)
                    ? .manual(cameraID: cameraID)
                    : .unmatched
                adjustments.append(try RoomProfessionalConceptMappingAdjustment(
                    conceptSetID: concept.conceptSetID,
                    attachmentID: attachment.attachmentID,
                    from: attachment.mapping,
                    to: replacement
                ))
                transformedAttachments.append(RoomConceptSetAttachment(
                    attachmentID: attachment.attachmentID,
                    relativePath: attachment.relativePath,
                    sha256: attachment.sha256,
                    byteCount: attachment.byteCount,
                    mediaType: attachment.mediaType,
                    sanitizationProvenance: attachment.sanitizationProvenance,
                    mapping: replacement
                ))
            }
            let transported = RoomConceptSet(
                schemaVersion: concept.schemaVersion,
                conceptSetID: concept.conceptSetID,
                sourceRevision: concept.sourceRevision,
                request: concept.request,
                scope: concept.scope,
                provider: concept.provider,
                sourceAIRoomPackage: concept.sourceAIRoomPackage,
                importProvenance: concept.importProvenance,
                createdAt: concept.createdAt,
                importedAt: concept.importedAt,
                attachments: transformedAttachments,
                comments: concept.comments,
                approvalState: concept.approvalState,
                archiveState: concept.archiveState
            )
            try transported.validateIntrinsic(expectedSourceRevision: sourceRevision)
            let canonicalData = try RoomConceptSetCanonicalJSON.encode(transported)
            transportSets.append(try RoomProfessionalConceptSetSnapshot(
                sourceRevision: sourceRevision,
                conceptSetID: transported.conceptSetID,
                canonicalManifestData: canonicalData,
                manifestSHA256: RoomSHA256.hexDigest(of: canonicalData),
                attachments: snapshot.attachments
            ))
        }
        conceptSnapshot = try RoomProfessionalConceptSnapshot(
            sourceRevision: sourceRevision,
            conceptSets: transportSets.sorted { $0.conceptSetID < $1.conceptSetID }
        )
        sourcePackageProvenance = try requiredAIReadyPackageIDs.sorted().map { key in
            guard let value = packagesByID[key] else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Automatic Concept transport mapping lost its required AI-ready package capability."
                )
            }
            return try RoomProfessionalConceptSourcePackageProvenanceSnapshot(
                sourceRevision: sourceRevision,
                canonicalManifestData: value.2
            )
        }
        conceptMappingAdjustments = adjustments.sorted {
            if $0.conceptSetID != $1.conceptSetID { return $0.conceptSetID < $1.conceptSetID }
            return $0.attachmentID < $1.attachmentID
        }
    }

    public func workingSetCompanionPreparation(
        additionalCompanions: [RoomProfessionalWorkingSetCompanion] = []
    ) throws -> RoomProfessionalWorkingSetCompanionPreparation {
        let companions = try additionalCompanions
            + conceptSnapshot.workingSetCompanions()
            + sourcePackageProvenance.map { try $0.workingSetCompanion() }
        return try RoomProfessionalWorkingSetCompanionPreparation(
            sourceRevision: conceptSnapshot.sourceRevision,
            companions: companions,
            conceptMappingAdjustments: conceptMappingAdjustments
        )
    }

    private static func validatedCameraIDs(_ values: [String]) throws -> Set<String> {
        guard values.allSatisfy(RoomPathValidation.isSafeStableIdentifier),
              Set(values).count == values.count
        else {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Concept transport requires a unique validated canonical-camera set."
            )
        }
        return Set(values)
    }
}

/// Canonical redesign companion bytes captured from a local companion store.
/// The value carries the source binding and digest so it can enter the strict
/// professional working-set envelope without a parallel format.
public struct RoomProfessionalRedesignSnapshot: Sendable, Equatable {
    public var sourceRevision: RoomRedesignSourceRevision
    public var canonicalDocumentData: Data
    public var documentSHA256: String

    public init(
        sourceRevision: RoomRedesignSourceRevision,
        canonicalDocumentData: Data,
        documentSHA256: String
    ) throws {
        self.sourceRevision = sourceRevision
        self.canonicalDocumentData = canonicalDocumentData
        self.documentSHA256 = documentSHA256
        _ = try validatedDocument()
    }

    public func workingSetCompanions() throws -> [RoomProfessionalWorkingSetCompanion] {
        _ = try validatedDocument()
        return [try RoomProfessionalWorkingSetCompanion(
            sourceRevision: sourceRevision,
            path: "companions/redesign.json",
            kind: .redesignCompanion,
            mediaType: "application/json",
            data: canonicalDocumentData
        )]
    }

    func validatedDocument() throws -> RoomLocalRedesignExtensionV2 {
        do {
            try sourceRevision.validate()
            guard RoomProfessionalRecoveryValidation.isLowercaseSHA256(documentSHA256),
                  RoomSHA256.hexDigest(of: canonicalDocumentData) == documentSHA256,
                  case let .localRedesignExtensionV2(document) = try RoomRedesignContractValidator.validate(
                      data: canonicalDocumentData
                  ),
                  document.sourceRevision == sourceRevision,
                  try RoomRedesignCanonicalJSON.encode(document) == canonicalDocumentData
            else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Redesign snapshot bytes are not a canonical source-bound local redesign extension v2."
                )
            }
            return document
        } catch let error as RoomProfessionalRecoveryError {
            throw error
        } catch {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Redesign snapshot bytes are not a canonical source-bound local redesign extension v2."
            )
        }
    }
}

/// Exact copied image bytes declared by one Concept Set manifest. The source
/// snapshot accepts no unlisted path or image format.
public struct RoomProfessionalConceptAttachmentSnapshot: Sendable, Equatable {
    public var attachmentID: String
    public var relativePath: String
    public var mediaType: String
    public var data: Data
    public var byteCount: UInt64
    public var sha256: String

    public init(
        attachmentID: String,
        relativePath: String,
        mediaType: String,
        data: Data,
        byteCount: UInt64,
        sha256: String
    ) throws {
        self.attachmentID = attachmentID
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.data = data
        self.byteCount = byteCount
        self.sha256 = sha256
        try validateFields()
    }

    func validateFields() throws {
        guard RoomPathValidation.isSafeStableIdentifier(attachmentID),
              !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              byteCount > 0,
              UInt64(data.count) == byteCount,
              RoomProfessionalRecoveryValidation.isLowercaseSHA256(sha256),
              RoomSHA256.hexDigest(of: data) == sha256
        else {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Concept attachment snapshot bytes, digest, or metadata are invalid."
            )
        }
        do {
            let path = try RoomExportEntryPath(relativePath)
            guard path.value.hasPrefix("attachments/"),
                  path.value.split(separator: "/").count == 2
            else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Concept attachment snapshots require one flat attachments/ path."
                )
            }
            _ = try RoomConceptImageValidator.validateSanitizedImage(data, mediaType: mediaType)
        } catch let error as RoomProfessionalRecoveryError {
            throw error
        } catch {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Concept attachment snapshot is not one sanitized declared image."
            )
        }
    }
}

/// One strict canonical Concept Set manifest and its complete declared image
/// closure. `attachments` is kept in manifest attachment-ID order.
public struct RoomProfessionalConceptSetSnapshot: Sendable, Equatable {
    public var sourceRevision: RoomRedesignSourceRevision
    public var conceptSetID: String
    public var canonicalManifestData: Data
    public var manifestSHA256: String
    public var attachments: [RoomProfessionalConceptAttachmentSnapshot]

    public init(
        sourceRevision: RoomRedesignSourceRevision,
        conceptSetID: String,
        canonicalManifestData: Data,
        manifestSHA256: String,
        attachments: [RoomProfessionalConceptAttachmentSnapshot]
    ) throws {
        self.sourceRevision = sourceRevision
        self.conceptSetID = conceptSetID
        self.canonicalManifestData = canonicalManifestData
        self.manifestSHA256 = manifestSHA256
        self.attachments = attachments
        _ = try validatedConcept()
    }

    func validatedConcept() throws -> RoomConceptSet {
        do {
            try sourceRevision.validate()
            guard RoomPathValidation.isSafeStableIdentifier(conceptSetID),
                  RoomProfessionalRecoveryValidation.isLowercaseSHA256(manifestSHA256),
                  RoomSHA256.hexDigest(of: canonicalManifestData) == manifestSHA256
            else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Concept Set snapshot manifest digest or identifier is invalid."
                )
            }
            let concept = try RoomConceptSetDecoder.decodeCanonicalIntrinsic(
                canonicalManifestData,
                expectedSourceRevision: sourceRevision
            )
            guard concept.conceptSetID == conceptSetID,
                  concept.sourceRevision == sourceRevision,
                  attachments.map(\.attachmentID) == concept.attachments.map(\.attachmentID)
            else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Concept Set snapshot attachment IDs do not exactly close its manifest."
                )
            }
            for (snapshot, declaration) in zip(attachments, concept.attachments) {
                try snapshot.validateFields()
                guard snapshot.relativePath == declaration.relativePath,
                      snapshot.mediaType == declaration.mediaType,
                      snapshot.byteCount == declaration.byteCount,
                      snapshot.sha256 == declaration.sha256
                else {
                    throw RoomProfessionalRecoveryError.invalidSnapshot(
                        "Concept Set snapshot attachment metadata disagrees with its canonical manifest."
                    )
                }
            }
            return concept
        } catch let error as RoomProfessionalRecoveryError {
            throw error
        } catch {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Concept Set snapshot is not canonical, source-bound, and intrinsically valid."
            )
        }
    }
}

/// Every Concept Set companion bound to one immutable source revision. This
/// is directly convertible to the professional working-set companion ledger.
public struct RoomProfessionalConceptSnapshot: Sendable, Equatable {
    public var sourceRevision: RoomRedesignSourceRevision
    public var conceptSets: [RoomProfessionalConceptSetSnapshot]

    public init(
        sourceRevision: RoomRedesignSourceRevision,
        conceptSets: [RoomProfessionalConceptSetSnapshot]
    ) throws {
        self.sourceRevision = sourceRevision
        self.conceptSets = conceptSets
        try validateStructure()
    }

    public func validateStructure() throws {
        do {
            try sourceRevision.validate()
            let conceptSetIDs = conceptSets.map(\.conceptSetID)
            let caseFoldedConceptSetIDs = conceptSetIDs.map { $0.lowercased() }
            guard conceptSetIDs == conceptSetIDs.sorted(),
                  Set(conceptSetIDs).count == conceptSets.count,
                  Set(caseFoldedConceptSetIDs).count == conceptSets.count
            else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Concept Set snapshots must be unique by ASCII case and stably ordered by Concept Set ID."
                )
            }
            for snapshot in conceptSets {
                guard snapshot.sourceRevision == sourceRevision else {
                    throw RoomProfessionalRecoveryError.sourceRevisionMismatch(
                        "Every Concept Set snapshot must bind the collection's exact immutable source revision."
                    )
                }
                _ = try snapshot.validatedConcept()
            }
        } catch let error as RoomProfessionalRecoveryError {
            throw error
        } catch {
            throw RoomProfessionalRecoveryError.invalidSnapshot(
                "Concept snapshot structure is invalid."
            )
        }
    }

    public func workingSetCompanions() throws -> [RoomProfessionalWorkingSetCompanion] {
        try validateStructure()
        var companions: [RoomProfessionalWorkingSetCompanion] = []
        for snapshot in conceptSets {
            let concept = try snapshot.validatedConcept()
            let basePath = "companions/concept-sets/\(concept.conceptSetID)"
            companions.append(try RoomProfessionalWorkingSetCompanion(
                sourceRevision: sourceRevision,
                path: "\(basePath)/manifest.json",
                kind: .conceptSetManifest,
                mediaType: "application/json",
                data: snapshot.canonicalManifestData
            ))
            for attachment in snapshot.attachments {
                companions.append(try RoomProfessionalWorkingSetCompanion(
                    sourceRevision: sourceRevision,
                    path: "\(basePath)/\(attachment.relativePath)",
                    kind: .conceptSetAttachment,
                    mediaType: attachment.mediaType,
                    data: attachment.data
                ))
            }
        }
        return companions.sorted { $0.path < $1.path }
    }

    func restoreImports(
        context: RoomConceptSetValidationContext,
        recoveredCopyMapping: RoomProfessionalRecoveredCopyMapping?
    ) throws -> RoomProfessionalConceptRestorePlan {
        let targetSourceRevision = try RoomProfessionalRecoveryRebinding.targetSourceRevision(
            original: sourceRevision,
            expected: context.expectedSourceRevision,
            mapping: recoveredCopyMapping
        )
        var imports: [RoomConceptSetImport] = []
        var adjustments: [RoomProfessionalConceptMappingAdjustment] = []
        for snapshot in conceptSets {
            let original = try snapshot.validatedConcept()
            let rebound: RoomConceptSet
            if targetSourceRevision == sourceRevision {
                rebound = original
            } else {
                guard let recoveredCopyMapping else {
                    throw RoomProfessionalRecoveryError.sourceRevisionMismatch(
                        "A different destination source revision requires an explicit recovered-copy mapping."
                    )
                }
                let reboundResult = try RoomProfessionalRecoveryRebinding.rebind(
                    conceptSet: original,
                    targetSourceRevision: targetSourceRevision,
                    mapping: recoveredCopyMapping,
                    currentCanonicalCameraIDs: Set(context.currentCanonicalCameraIDs)
                )
                rebound = reboundResult.conceptSet
                adjustments.append(contentsOf: reboundResult.adjustments)
            }
            let canonicalData = try RoomConceptSetCanonicalJSON.encode(rebound)
            let validated = try RoomConceptSetDecoder.decodeCanonical(canonicalData, context: context)
            guard validated == rebound else {
                throw RoomProfessionalRecoveryError.invalidSnapshot(
                    "Rebound Concept Set did not validate canonically for the destination source revision."
                )
            }
            imports.append(RoomConceptSetImport(
                conceptSet: validated,
                attachments: snapshot.attachments.map {
                    RoomConceptSetAttachmentBytes(attachmentID: $0.attachmentID, data: $0.data)
                }
            ))
        }
        return RoomProfessionalConceptRestorePlan(
            imports: imports,
            conceptMappingAdjustments: adjustments.sorted {
                if $0.conceptSetID != $1.conceptSetID { return $0.conceptSetID < $1.conceptSetID }
                return $0.attachmentID < $1.attachmentID
            }
        )
    }
}

/// Outcome metadata from one companion-store restore. Existing callers may
/// ignore it; professional recovery returns it to the UI so copy downgrades
/// are never silent.
public struct RoomProfessionalConceptRestoreResult: Sendable, Equatable {
    public let conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]

    public init(conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]) {
        self.conceptMappingAdjustments = conceptMappingAdjustments
    }
}

struct RoomProfessionalConceptRestorePlan {
    let imports: [RoomConceptSetImport]
    let conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]
}

enum RoomProfessionalRecoveryRebinding {
    static func targetSourceRevision(
        original: RoomRedesignSourceRevision,
        expected: RoomRedesignSourceRevision,
        mapping: RoomProfessionalRecoveredCopyMapping?
    ) throws -> RoomRedesignSourceRevision {
        try original.validate()
        try expected.validate()
        if original == expected {
            return original
        }
        guard let mapping else {
            throw RoomProfessionalRecoveryError.sourceRevisionMismatch(
                "Companion recovery cannot implicitly rebind to another project or source revision."
            )
        }
        return try mapping.reboundSourceRevision(from: original, expectedRecoveredCopy: expected)
    }

    static func rebind(
        redesign: RoomLocalRedesignExtensionV2,
        targetSourceRevision: RoomRedesignSourceRevision,
        mapping: RoomProfessionalRecoveredCopyMapping
    ) throws -> RoomLocalRedesignExtensionV2 {
        let propertyMembership = redesign.propertyMembership.map { membership in
            RoomPropertyMembershipContract(
                propertyID: membership.propertyID,
                roomProjectIDs: membership.roomProjectIDs.map { projectID in
                    projectID == mapping.originalProjectID
                        ? mapping.recoveredCopyProjectID
                        : projectID
                }
            )
        }
        let conceptMetadata = redesign.conceptMetadata.map { metadata in
            RoomConceptMetadataV2(
                conceptSetID: metadata.conceptSetID,
                sourceRevision: targetSourceRevision,
                request: metadata.request,
                scope: metadata.scope,
                provider: metadata.provider,
                sourceAIRoomPackageSchemaVersion: metadata.sourceAIRoomPackageSchemaVersion,
                sourceAIRoomPackageID: metadata.sourceAIRoomPackageID,
                createdAt: metadata.createdAt,
                importedAt: metadata.importedAt,
                mappingStatus: metadata.mappingStatus,
                attachments: metadata.attachments,
                comments: metadata.comments,
                approvalState: metadata.approvalState,
                archiveState: metadata.archiveState
            )
        }
        let rebound = RoomLocalRedesignExtensionV2(
            schemaVersion: redesign.schemaVersion,
            contractKind: redesign.contractKind,
            sourceRevision: targetSourceRevision,
            orientation: redesign.orientation,
            redesignIntent: redesign.redesignIntent,
            propertyMembership: propertyMembership,
            conceptMetadata: conceptMetadata
        )
        try rebound.validate()
        return rebound
    }

    static func rebind(
        conceptSet: RoomConceptSet,
        targetSourceRevision: RoomRedesignSourceRevision,
        mapping: RoomProfessionalRecoveredCopyMapping,
        currentCanonicalCameraIDs: Set<String>
    ) throws -> (conceptSet: RoomConceptSet, adjustments: [RoomProfessionalConceptMappingAdjustment]) {
        _ = mapping
        var adjustments: [RoomProfessionalConceptMappingAdjustment] = []
        let reboundAttachments = try conceptSet.attachments.map { attachment -> RoomConceptSetAttachment in
            guard attachment.mapping.status == .automatic,
                  let cameraID = attachment.mapping.cameraID
            else {
                return attachment
            }
            let replacement: RoomConceptAttachmentMapping = currentCanonicalCameraIDs.contains(cameraID)
                ? .manual(cameraID: cameraID)
                : .unmatched
            adjustments.append(try RoomProfessionalConceptMappingAdjustment(
                conceptSetID: conceptSet.conceptSetID,
                attachmentID: attachment.attachmentID,
                from: attachment.mapping,
                to: replacement
            ))
            return RoomConceptSetAttachment(
                attachmentID: attachment.attachmentID,
                relativePath: attachment.relativePath,
                sha256: attachment.sha256,
                byteCount: attachment.byteCount,
                mediaType: attachment.mediaType,
                sanitizationProvenance: attachment.sanitizationProvenance,
                mapping: replacement
            )
        }
        let rebound = RoomConceptSet(
            schemaVersion: conceptSet.schemaVersion,
            conceptSetID: conceptSet.conceptSetID,
            sourceRevision: targetSourceRevision,
            request: conceptSet.request,
            scope: conceptSet.scope,
            provider: conceptSet.provider,
            sourceAIRoomPackage: conceptSet.sourceAIRoomPackage,
            importProvenance: conceptSet.importProvenance,
            createdAt: conceptSet.createdAt,
            importedAt: conceptSet.importedAt,
            attachments: reboundAttachments,
            comments: conceptSet.comments,
            approvalState: conceptSet.approvalState,
            archiveState: conceptSet.archiveState
        )
        try rebound.validateIntrinsic(expectedSourceRevision: targetSourceRevision)
        return (rebound, adjustments)
    }
}

private enum RoomProfessionalRecoveryValidation {
    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }
}
