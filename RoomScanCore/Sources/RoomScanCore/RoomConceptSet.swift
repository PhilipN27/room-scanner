import Foundation

public enum RoomConceptStoreFaultPoint: String, Codable, Sendable, Equatable {
    case beforePromotion
    case afterPromotionBeforeCommit
}

public enum RoomConceptSetError: Error, Sendable, Equatable {
    case invalidJSON
    case duplicateKey(path: String, key: String)
    case missingKey(path: String, key: String)
    case unknownKey(path: String, key: String)
    case unsupportedSchemaVersion(String)
    case invalidValue(path: String, reason: String)
    case noncanonicalJSON
    case invalidMedia(String)
    case limitExceeded(String)
    case invalidArchive(String)
    case sourceStoreOverlap
    case conceptAlreadyExists(String)
    case conceptNotFound(String)
    case unsafeStore(String)
    case injectedFailure(RoomConceptStoreFaultPoint)
    case cancelled
}

public enum RoomConceptMappingKind: String, Codable, Sendable, Equatable {
    case automatic
    case manual
    case unmatched
}

public struct RoomConceptAttachmentMapping: Codable, Sendable, Equatable {
    public var status: RoomConceptMappingKind
    public var cameraID: String?

    public init(status: RoomConceptMappingKind, cameraID: String? = nil) {
        self.status = status
        self.cameraID = cameraID
    }

    public static func automatic(cameraID: String) -> Self {
        .init(status: .automatic, cameraID: cameraID)
    }

    public static func manual(cameraID: String) -> Self {
        .init(status: .manual, cameraID: cameraID)
    }

    public static let unmatched = Self(status: .unmatched)
}

public enum RoomConceptSanitizationProvenance: String, Codable, Sendable, Equatable {
    case appReencodedLooseFile
    case appReencodedPackagedFile
}

public enum RoomConceptImportKind: String, Codable, Sendable, Equatable {
    case looseLocalFile
    case packagedOutput
}

public struct RoomConceptImportProvenance: Codable, Sendable, Equatable {
    public var kind: RoomConceptImportKind
    public var sourceFilename: String

    public init(kind: RoomConceptImportKind, sourceFilename: String) {
        self.kind = kind
        self.sourceFilename = sourceFilename
    }
}

public struct RoomConceptSourceAIRoomPackage: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var packageID: String

    public init(schemaVersion: String, packageID: String) {
        self.schemaVersion = schemaVersion
        self.packageID = packageID
    }
}

/// Authority for automatic Concept attachment mapping.  This value can only
/// be constructed from a canonical AI Room Package manifest that Core has
/// parsed and validated.  A Concept manifest's package ID is a claim; it
/// becomes automatic only when it matches one of these independently retained
/// package capabilities.
public struct RoomConceptValidatedSourcePackage: Sendable, Equatable {
    public let sourceRevision: RoomRedesignSourceRevision
    public let sourceAIRoomPackage: RoomConceptSourceAIRoomPackage
    /// Camera IDs are derived from the canonical-view paths in the validated
    /// package ledger, never supplied by the current room orientation.
    public let canonicalCameraIDs: [String]
    public let manifestSHA256: String

    public init(validatedManifestData: Data) throws {
        let package: RoomAIRoomPackage
        do {
            guard case let .aiRoomPackage(decoded) = try RoomRedesignContractValidator.validate(
                data: validatedManifestData
            ),
                try RoomRedesignCanonicalJSON.encode(decoded) == validatedManifestData
            else {
                throw RoomConceptSetError.invalidValue(
                    path: "validatedSourceAIRoomPackage",
                    reason: "Automatic mapping authority requires one canonical validated AI Room Package manifest."
                )
            }
            try decoded.validate()
            package = decoded
        } catch let error as RoomConceptSetError {
            throw error
        } catch {
            throw RoomConceptSetError.invalidValue(
                path: "validatedSourceAIRoomPackage",
                reason: "Automatic mapping authority requires one canonical validated AI Room Package manifest."
            )
        }
        try self.init(validatedPackage: package, manifestData: validatedManifestData)
    }

    public init(validatedPackage: RoomAIRoomPackage) throws {
        let manifestData = try RoomAIRoomPackageBuilder.canonicalManifestData(validatedPackage)
        try self.init(validatedPackage: validatedPackage, manifestData: manifestData)
    }

    /// Test-only construction for Core's local validation oracle. Production
    /// modules cannot manufacture this binding from a package-ID/camera tuple.
    init(
        testOnlySourceRevision: RoomRedesignSourceRevision,
        sourceAIRoomPackage: RoomConceptSourceAIRoomPackage,
        canonicalCameraIDs: [String]
    ) throws {
        try testOnlySourceRevision.validate()
        guard sourceAIRoomPackage.schemaVersion
            == RoomRedesignContractKind.aiRoomPackage.supportedSchemaVersion
        else {
            throw RoomConceptSetError.invalidValue(
                path: "sourceAIRoomPackage.schemaVersion",
                reason: "Concept package provenance must name the supported AI Room Package schema."
            )
        }
        try RoomConceptSetRules.requireIdentifier(
            sourceAIRoomPackage.packageID,
            at: "sourceAIRoomPackage.packageID"
        )
        _ = try RoomConceptSetRules.validatedIdentifiers(
            canonicalCameraIDs,
            at: "canonicalCameraIDs"
        )
        self.sourceRevision = testOnlySourceRevision
        self.sourceAIRoomPackage = sourceAIRoomPackage
        self.canonicalCameraIDs = canonicalCameraIDs.sorted()
        self.manifestSHA256 = String(repeating: "0", count: 64)
    }

    private init(validatedPackage: RoomAIRoomPackage, manifestData: Data) throws {
        let canonicalManifestData = try RoomAIRoomPackageBuilder.canonicalManifestData(validatedPackage)
        guard canonicalManifestData == manifestData else {
            throw RoomConceptSetError.invalidValue(
                path: "validatedSourceAIRoomPackage",
                reason: "Automatic mapping authority requires canonical manifest bytes for the exact validated package."
            )
        }
        let canonicalViews = validatedPackage.artifacts.filter {
            $0.artifactClass == .canonicalView && $0.disposition == .included
        }
        guard canonicalViews.count == 6 else {
            throw RoomConceptSetError.invalidValue(
                path: "validatedSourceAIRoomPackage.artifacts",
                reason: "Automatic mapping authority requires the package's complete canonical-view ledger."
            )
        }
        let prefix = "derivatives/canonical-views/"
        let cameraIDs = try canonicalViews.map { artifact -> String in
            guard let relativePath = artifact.relativePath,
                  relativePath.hasPrefix(prefix),
                  relativePath.hasSuffix(".png")
            else {
                throw RoomConceptSetError.invalidValue(
                    path: "validatedSourceAIRoomPackage.artifacts",
                    reason: "Automatic mapping authority requires canonical-view paths from the validated package ledger."
                )
            }
            let cameraID = String(relativePath.dropFirst(prefix.count).dropLast(4))
            try RoomConceptSetRules.requireIdentifier(
                cameraID,
                at: "validatedSourceAIRoomPackage.canonicalCameraIDs"
            )
            return cameraID
        }
        _ = try RoomConceptSetRules.validatedIdentifiers(
            cameraIDs,
            at: "validatedSourceAIRoomPackage.canonicalCameraIDs"
        )
        self.sourceRevision = validatedPackage.sourceRevision
        self.sourceAIRoomPackage = .init(
            schemaVersion: validatedPackage.schemaVersion,
            packageID: validatedPackage.packageID
        )
        self.canonicalCameraIDs = cameraIDs.sorted()
        self.manifestSHA256 = RoomSHA256.hexDigest(of: manifestData)
    }
}

public struct RoomConceptSetAttachment: Codable, Sendable, Equatable {
    public var attachmentID: String
    public var relativePath: String
    public var sha256: String
    public var byteCount: UInt64
    public var mediaType: String
    public var sanitizationProvenance: RoomConceptSanitizationProvenance
    public var mapping: RoomConceptAttachmentMapping

    public init(
        attachmentID: String,
        relativePath: String,
        sha256: String,
        byteCount: UInt64,
        mediaType: String,
        sanitizationProvenance: RoomConceptSanitizationProvenance,
        mapping: RoomConceptAttachmentMapping
    ) {
        self.attachmentID = attachmentID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.sanitizationProvenance = sanitizationProvenance
        self.mapping = mapping
    }
}

public struct RoomConceptSet: Encodable, Sendable, Equatable {
    public static let schemaVersionValue = "roomscan-concept-set-v1"

    public var schemaVersion: String
    public var conceptSetID: String
    public var sourceRevision: RoomRedesignSourceRevision
    public var request: String
    public var scope: RoomRedesignScope
    public var provider: String?
    public var sourceAIRoomPackage: RoomConceptSourceAIRoomPackage?
    public var importProvenance: RoomConceptImportProvenance
    public var createdAt: Date
    public var importedAt: Date
    public var attachments: [RoomConceptSetAttachment]
    public var comments: [String]
    public var approvalState: RoomConceptApprovalState
    public var archiveState: RoomConceptArchiveState

    public init(
        schemaVersion: String = Self.schemaVersionValue,
        conceptSetID: String,
        sourceRevision: RoomRedesignSourceRevision,
        request: String,
        scope: RoomRedesignScope,
        provider: String?,
        sourceAIRoomPackage: RoomConceptSourceAIRoomPackage?,
        importProvenance: RoomConceptImportProvenance,
        createdAt: Date,
        importedAt: Date,
        attachments: [RoomConceptSetAttachment],
        comments: [String],
        approvalState: RoomConceptApprovalState,
        archiveState: RoomConceptArchiveState
    ) {
        self.schemaVersion = schemaVersion
        self.conceptSetID = conceptSetID
        self.sourceRevision = sourceRevision
        self.request = request
        self.scope = scope
        self.provider = provider
        self.sourceAIRoomPackage = sourceAIRoomPackage
        self.importProvenance = importProvenance
        self.createdAt = createdAt
        self.importedAt = importedAt
        self.attachments = attachments
        self.comments = comments
        self.approvalState = approvalState
        self.archiveState = archiveState
    }

    public func validate(context: RoomConceptSetValidationContext) throws {
        guard schemaVersion == Self.schemaVersionValue else {
            throw RoomConceptSetError.unsupportedSchemaVersion(schemaVersion)
        }
        try RoomConceptSetRules.requireIdentifier(conceptSetID, at: "conceptSetID")
        try sourceRevision.validate()
        guard sourceRevision == context.expectedSourceRevision else {
            throw RoomConceptSetError.invalidValue(
                path: "sourceRevision",
                reason: "A Concept Set must bind to the exact immutable source revision."
            )
        }
        try RoomConceptSetRules.requireText(request, maximum: 8_000, at: "request")
        if let provider {
            try RoomConceptSetRules.requireText(provider, maximum: 500, at: "provider")
        }
        if let sourceAIRoomPackage {
            guard sourceAIRoomPackage.schemaVersion == RoomRedesignContractKind.aiRoomPackage.supportedSchemaVersion else {
                throw RoomConceptSetError.invalidValue(
                    path: "sourceAIRoomPackage.schemaVersion",
                    reason: "Concept package provenance must name the supported AI Room Package schema."
                )
            }
            try RoomConceptSetRules.requireIdentifier(
                sourceAIRoomPackage.packageID,
                at: "sourceAIRoomPackage.packageID"
            )
        }
        switch importProvenance.kind {
        case .looseLocalFile:
            guard sourceAIRoomPackage == nil else {
                throw RoomConceptSetError.invalidValue(
                    path: "sourceAIRoomPackage",
                    reason: "A loose local-file import cannot claim AI Room Package provenance."
                )
            }
        case .packagedOutput:
            guard sourceAIRoomPackage != nil else {
                throw RoomConceptSetError.invalidValue(
                    path: "sourceAIRoomPackage",
                    reason: "Packaged concept output must identify its claimed AI Room Package."
                )
            }
        }
        try RoomConceptSetRules.requirePortableFilename(
            importProvenance.sourceFilename,
            at: "importProvenance.sourceFilename"
        )
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              importedAt.timeIntervalSinceReferenceDate.isFinite,
              importedAt >= createdAt
        else {
            throw RoomConceptSetError.invalidValue(
                path: "importedAt",
                reason: "Concept timestamps must be finite and importedAt cannot precede createdAt."
            )
        }
        guard !attachments.isEmpty, attachments.count <= RoomConceptSetRules.maximumAttachmentCount else {
            throw RoomConceptSetError.limitExceeded("A Concept Set must contain 1...64 attachments.")
        }
        if importProvenance.kind == .looseLocalFile {
            guard attachments.count == 1 else {
                throw RoomConceptSetError.invalidValue(
                    path: "attachments",
                    reason: "A loose local-file import contains exactly one sanitized image."
                )
            }
        }
        guard attachments.map(\.attachmentID) == attachments.map(\.attachmentID).sorted() else {
            throw RoomConceptSetError.invalidValue(
                path: "attachments",
                reason: "Attachments must be in stable ASCII attachment-ID order."
            )
        }
        try RoomConceptSetRules.requireUnique(attachments.map(\.attachmentID), at: "attachments.attachmentID")
        try RoomConceptSetRules.requireUniqueCaseFolded(attachments.map(\.relativePath), at: "attachments.relativePath")

        let currentCameras = try RoomConceptSetRules.validatedIdentifiers(
            context.currentCanonicalCameraIDs,
            at: "context.currentCanonicalCameraIDs"
        )
        let validatedSourcePackage = context.validatedSourceAIRoomPackage(
            matching: sourceAIRoomPackage
        )
        let packageCameras = Set(validatedSourcePackage?.canonicalCameraIDs ?? [])
        let hasExactReviewedSourcePackage = validatedSourcePackage != nil
        for (index, attachment) in attachments.enumerated() {
            try attachment.validate(
                importKind: importProvenance.kind,
                hasExactReviewedSourcePackage: hasExactReviewedSourcePackage,
                currentCanonicalCameraIDs: currentCameras,
                packageCanonicalCameraIDs: packageCameras,
                at: "attachments[\(index)]"
            )
        }
        guard comments.count <= RoomConceptSetRules.maximumCommentCount else {
            throw RoomConceptSetError.limitExceeded("A Concept Set may contain at most 1,000 comments.")
        }
        for (index, comment) in comments.enumerated() {
            try RoomConceptSetRules.requireText(comment, maximum: 2_000, at: "comments[\(index)]")
        }
    }
}

public struct RoomConceptSetValidationContext: Sendable, Equatable {
    public var expectedSourceRevision: RoomRedesignSourceRevision
    public var currentCanonicalCameraIDs: [String]
    /// Independently validated package capabilities retained by the app for
    /// this immutable source revision. Absent or ambiguous capability matches
    /// fail closed for automatic mappings; manual and unmatched mappings stay
    /// importable.
    public var validatedSourceAIRoomPackages: [RoomConceptValidatedSourcePackage]

    public init(
        expectedSourceRevision: RoomRedesignSourceRevision,
        currentCanonicalCameraIDs: [String],
        validatedSourceAIRoomPackages: [RoomConceptValidatedSourcePackage] = []
    ) {
        self.expectedSourceRevision = expectedSourceRevision
        self.currentCanonicalCameraIDs = currentCanonicalCameraIDs
        self.validatedSourceAIRoomPackages = validatedSourceAIRoomPackages
    }

    public func validatedSourceAIRoomPackage(
        matching claimedPackage: RoomConceptSourceAIRoomPackage?
    ) -> RoomConceptValidatedSourcePackage? {
        guard let claimedPackage else { return nil }
        let matches = validatedSourceAIRoomPackages.filter {
            $0.sourceRevision == expectedSourceRevision
                && $0.sourceAIRoomPackage == claimedPackage
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

public enum RoomConceptSetCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try RoomRedesignCanonicalJSON.encode(value)
    }

    public static func sha256<T: Encodable>(_ value: T) throws -> String {
        RoomSHA256.hexDigest(of: try encode(value))
    }
}

public enum RoomConceptSetDecoder {
    public static func decodeCanonical(
        _ data: Data,
        context: RoomConceptSetValidationContext
    ) throws -> RoomConceptSet {
        try RoomConceptJSONMemberScanner.rejectDuplicateObjectMembers(in: data)

        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RoomConceptSetError.invalidJSON
            }
            root = object
        } catch let error as RoomConceptSetError {
            throw error
        } catch {
            throw RoomConceptSetError.invalidJSON
        }
        try RoomConceptStrictJSON.validate(root)

        let validatedData: Data
        do {
            validatedData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.withoutEscapingSlashes]
            )
        } catch {
            throw RoomConceptSetError.invalidJSON
        }
        let model: RoomConceptSet
        do {
            model = try RoomJSONCoding.makeDecoder()
                .decode(RoomConceptSetWire.self, from: validatedData)
                .model
        } catch {
            throw RoomConceptSetError.invalidJSON
        }
        try model.validate(context: context)
        guard try RoomConceptSetCanonicalJSON.encode(model) == data else {
            throw RoomConceptSetError.noncanonicalJSON
        }
        return model
    }
}

public struct RoomConceptImageLimits: Sendable, Equatable {
    public static let v1MaximumBytes: UInt64 = 32 * 1_024 * 1_024
    public static let v1MaximumPixelDimension: UInt64 = 8_192
    public static let v1MaximumPixelCount: UInt64 = 40_000_000

    public var maxBytes: UInt64
    public var maxPixelDimension: UInt64
    public var maxPixelCount: UInt64

    public init(
        maxBytes: UInt64 = Self.v1MaximumBytes,
        maxPixelDimension: UInt64 = Self.v1MaximumPixelDimension,
        maxPixelCount: UInt64 = Self.v1MaximumPixelCount
    ) {
        self.maxBytes = maxBytes
        self.maxPixelDimension = maxPixelDimension
        self.maxPixelCount = maxPixelCount
    }
}

public struct RoomConceptImageInfo: Sendable, Equatable {
    public var pixelWidth: UInt64
    public var pixelHeight: UInt64

    public init(pixelWidth: UInt64, pixelHeight: UInt64) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum RoomConceptImageValidator {
    public static func validateSanitizedImage(
        _ data: Data,
        mediaType: String,
        limits: RoomConceptImageLimits = RoomConceptImageLimits()
    ) throws -> RoomConceptImageInfo {
        guard limits.maxBytes > 0,
              limits.maxBytes <= RoomConceptImageLimits.v1MaximumBytes,
              limits.maxPixelDimension > 0,
              limits.maxPixelDimension <= RoomConceptImageLimits.v1MaximumPixelDimension,
              limits.maxPixelCount > 0,
              limits.maxPixelCount <= RoomConceptImageLimits.v1MaximumPixelCount,
              !data.isEmpty,
              UInt64(data.count) <= limits.maxBytes
        else {
            throw RoomConceptSetError.limitExceeded("Concept image exceeds its byte or pixel budget.")
        }
        let info: RoomConceptImageInfo
        switch mediaType {
        case "image/png":
            info = try validatePNG(data)
        case "image/jpeg":
            info = try validateJPEG(data)
        default:
            throw RoomConceptSetError.invalidMedia("Only byte-verified JPEG and PNG are accepted.")
        }
        guard info.pixelWidth > 0,
              info.pixelHeight > 0,
              info.pixelWidth <= limits.maxPixelDimension,
              info.pixelHeight <= limits.maxPixelDimension,
              info.pixelWidth <= UInt64.max / info.pixelHeight,
              info.pixelWidth * info.pixelHeight <= limits.maxPixelCount
        else {
            throw RoomConceptSetError.limitExceeded("Concept image exceeds its byte or pixel budget.")
        }
        return info
    }

    private static func validatePNG(_ data: Data) throws -> RoomConceptImageInfo {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        guard bytes.count >= signature.count, Array(bytes[0..<8]) == signature else {
            throw RoomConceptSetError.invalidMedia("PNG signature does not match its declaration.")
        }
        var offset = 8
        var info: RoomConceptImageInfo?
        var sawImageData = false
        var sawEnd = false
        var chunkIndex = 0
        while offset < bytes.count {
            guard !sawEnd, offset <= bytes.count - 12 else {
                throw RoomConceptSetError.invalidMedia("PNG framing is incomplete or has trailing content.")
            }
            let length = Int(readBigEndianUInt32(bytes, at: offset))
            guard length <= bytes.count - offset - 12 else {
                throw RoomConceptSetError.invalidMedia("PNG chunk exceeds the input boundary.")
            }
            let typeStart = offset + 4
            let typeBytes = Array(bytes[typeStart..<(typeStart + 4)])
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
                throw RoomConceptSetError.invalidMedia("PNG chunk type is invalid.")
            }
            let type = String(decoding: typeBytes, as: UTF8.self)
            let payloadStart = typeStart + 4
            let payloadEnd = payloadStart + length
            var crc = RoomCRC32.Stream()
            crc.update(Data(bytes[typeStart..<payloadEnd]))
            let declaredCRC = readBigEndianUInt32(bytes, at: payloadEnd)
            guard crc.finalizedValue == declaredCRC else {
                throw RoomConceptSetError.invalidMedia("PNG chunk CRC does not match its bytes.")
            }

            switch type {
            case "IHDR":
                guard chunkIndex == 0, length == 13, info == nil else {
                    throw RoomConceptSetError.invalidMedia("PNG must contain exactly one leading IHDR chunk.")
                }
                let width = UInt64(readBigEndianUInt32(bytes, at: payloadStart))
                let height = UInt64(readBigEndianUInt32(bytes, at: payloadStart + 4))
                let bitDepth = bytes[payloadStart + 8]
                let colorType = bytes[payloadStart + 9]
                let validDepth: Bool
                switch colorType {
                case 0: validDepth = [1, 2, 4, 8, 16].contains(bitDepth)
                case 2, 4, 6: validDepth = [8, 16].contains(bitDepth)
                case 3: validDepth = [1, 2, 4, 8].contains(bitDepth)
                default: validDepth = false
                }
                guard width > 0,
                      height > 0,
                      validDepth,
                      bytes[payloadStart + 10] == 0,
                      bytes[payloadStart + 11] == 0,
                      bytes[payloadStart + 12] <= 1
                else {
                    throw RoomConceptSetError.invalidMedia("PNG IHDR is unsupported or invalid.")
                }
                info = .init(pixelWidth: width, pixelHeight: height)
            case "IDAT":
                guard info != nil, !sawEnd else {
                    throw RoomConceptSetError.invalidMedia("PNG image data is out of order.")
                }
                sawImageData = true
            case "IEND":
                guard info != nil, sawImageData, length == 0 else {
                    throw RoomConceptSetError.invalidMedia("PNG end marker is invalid.")
                }
                sawEnd = true
            case "acTL", "fcTL", "fdAT", "eXIf", "iTXt", "tEXt", "zTXt":
                throw RoomConceptSetError.invalidMedia("Animated or metadata-bearing PNG content is not sanitized input.")
            default:
                // Unknown critical chunks cannot be interpreted safely. Safe
                // ancillary chunks remain framing data; ImageIO still owns the
                // mandatory decode and fresh re-encode before Core receives a
                // loose import.
                guard typeBytes[0] & 0x20 != 0 else {
                    throw RoomConceptSetError.invalidMedia("PNG contains an unsupported critical chunk.")
                }
            }
            offset = payloadEnd + 4
            chunkIndex += 1
        }
        guard sawEnd, offset == bytes.count, let info else {
            throw RoomConceptSetError.invalidMedia("PNG framing is incomplete or has trailing content.")
        }
        return info
    }

    private static func validateJPEG(_ data: Data) throws -> RoomConceptImageInfo {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw RoomConceptSetError.invalidMedia("JPEG signature does not match its declaration.")
        }
        var offset = 2
        var info: RoomConceptImageInfo?
        var sawScan = false
        while offset < bytes.count {
            guard offset < bytes.count, bytes[offset] == 0xff else {
                throw RoomConceptSetError.invalidMedia("JPEG marker framing is invalid.")
            }
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else {
                throw RoomConceptSetError.invalidMedia("JPEG ended inside a marker.")
            }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xd9 {
                guard sawScan, info != nil, offset == bytes.count else {
                    throw RoomConceptSetError.invalidMedia("JPEG EOI is missing, early, or followed by content.")
                }
                return info!
            }
            guard marker != 0xd8,
                  marker != 0x01,
                  !(0xd0...0xd7).contains(marker),
                  offset <= bytes.count - 2
            else {
                throw RoomConceptSetError.invalidMedia("JPEG contains an unsupported standalone marker.")
            }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset else {
                throw RoomConceptSetError.invalidMedia("JPEG segment exceeds the input boundary.")
            }
            let payloadStart = offset + 2
            let payloadEnd = offset + length
            if marker == 0xc0 {
                guard info == nil, length >= 11, bytes[payloadStart] == 8 else {
                    throw RoomConceptSetError.invalidMedia("JPEG must contain one supported baseline frame.")
                }
                let height = UInt64(Int(bytes[payloadStart + 1]) << 8 | Int(bytes[payloadStart + 2]))
                let width = UInt64(Int(bytes[payloadStart + 3]) << 8 | Int(bytes[payloadStart + 4]))
                let components = Int(bytes[payloadStart + 5])
                guard [1, 3].contains(components), length == 8 + components * 3 else {
                    throw RoomConceptSetError.invalidMedia("JPEG frame component declaration is invalid.")
                }
                info = .init(pixelWidth: width, pixelHeight: height)
            } else if (0xc1...0xcf).contains(marker), marker != 0xc4, marker != 0xc8, marker != 0xcc {
                throw RoomConceptSetError.invalidMedia("Only a single baseline JPEG frame is accepted.")
            } else if marker == 0xda {
                guard info != nil, !sawScan else {
                    throw RoomConceptSetError.invalidMedia("JPEG scan is missing its frame or is repeated.")
                }
                sawScan = true
                offset = payloadEnd
                while offset < bytes.count {
                    if bytes[offset] != 0xff {
                        offset += 1
                        continue
                    }
                    guard offset + 1 < bytes.count else {
                        throw RoomConceptSetError.invalidMedia("JPEG ended inside entropy-coded data.")
                    }
                    let next = bytes[offset + 1]
                    if next == 0x00 || (0xd0...0xd7).contains(next) {
                        offset += 2
                        continue
                    }
                    if next == 0xff {
                        offset += 1
                        continue
                    }
                    guard next == 0xd9, offset + 2 == bytes.count else {
                        throw RoomConceptSetError.invalidMedia("JPEG contains multiple scans or trailing content.")
                    }
                    return info!
                }
                throw RoomConceptSetError.invalidMedia("JPEG is missing its final EOI marker.")
            } else if marker == 0xe1 || marker == 0xe2 || marker == 0xed || marker == 0xfe {
                throw RoomConceptSetError.invalidMedia("JPEG metadata segments are not sanitized input.")
            }
            offset = payloadEnd
        }
        throw RoomConceptSetError.invalidMedia("JPEG is missing its final EOI marker.")
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}

private extension RoomConceptSetAttachment {
    func validate(
        importKind: RoomConceptImportKind,
        hasExactReviewedSourcePackage: Bool,
        currentCanonicalCameraIDs: Set<String>,
        packageCanonicalCameraIDs: Set<String>,
        at path: String
    ) throws {
        try RoomConceptSetRules.requireIdentifier(attachmentID, at: "\(path).attachmentID")
        let portablePath: RoomExportEntryPath
        do {
            portablePath = try RoomExportEntryPath(relativePath)
        } catch {
            throw RoomConceptSetError.invalidValue(
                path: "\(path).relativePath",
                reason: "Concept attachments require portable ASCII package-relative paths."
            )
        }
        guard portablePath.value.hasPrefix("attachments/"),
              portablePath.value.split(separator: "/").count == 2
        else {
            throw RoomConceptSetError.invalidValue(
                path: "\(path).relativePath",
                reason: "Concept attachments must use the flat attachments/ namespace."
            )
        }
        try RoomConceptSetRules.requireSHA256(sha256, at: "\(path).sha256")
        guard byteCount > 0, byteCount <= RoomConceptSetRules.maximumAttachmentBytes else {
            throw RoomConceptSetError.limitExceeded("Concept attachment byte count is outside the v1 limit.")
        }
        switch mediaType {
        case "image/png":
            guard relativePath.lowercased().hasSuffix(".png") else {
                throw RoomConceptSetError.invalidMedia("PNG declarations require a .png attachment path.")
            }
        case "image/jpeg":
            let lower = relativePath.lowercased()
            guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") else {
                throw RoomConceptSetError.invalidMedia("JPEG declarations require a .jpg or .jpeg attachment path.")
            }
        default:
            throw RoomConceptSetError.invalidMedia("Concept attachments are limited to image/jpeg and image/png.")
        }
        let expectedSanitization: RoomConceptSanitizationProvenance = importKind == .looseLocalFile
            ? .appReencodedLooseFile
            : .appReencodedPackagedFile
        guard sanitizationProvenance == expectedSanitization else {
            throw RoomConceptSetError.invalidValue(
                path: "\(path).sanitizationProvenance",
                reason: "Sanitization provenance must identify the actual import boundary."
            )
        }
        switch mapping.status {
        case .automatic:
            guard let cameraID = mapping.cameraID,
                  hasExactReviewedSourcePackage,
                  currentCanonicalCameraIDs.contains(cameraID),
                  packageCanonicalCameraIDs.contains(cameraID)
            else {
                throw RoomConceptSetError.invalidValue(
                    path: "\(path).mapping",
                    reason: "Automatic mapping requires one current canonical camera declared by an exact independently reviewed source AI package."
                )
            }
        case .manual:
            guard let cameraID = mapping.cameraID,
                  currentCanonicalCameraIDs.contains(cameraID)
            else {
                throw RoomConceptSetError.invalidValue(
                    path: "\(path).mapping",
                    reason: "Manual mapping requires an explicit current canonical camera."
                )
            }
        case .unmatched:
            guard mapping.cameraID == nil else {
                throw RoomConceptSetError.invalidValue(
                    path: "\(path).mapping.cameraID",
                    reason: "Unmatched attachments cannot carry a camera ID."
                )
            }
        }
    }
}

private struct RoomConceptSetWire: Decodable {
    var schemaVersion: String
    var conceptSetID: String
    var sourceRevision: RoomRedesignSourceRevision
    var request: String
    var scope: RoomRedesignScope
    var provider: String?
    var sourceAIRoomPackage: RoomConceptSourceAIRoomPackage?
    var importProvenance: RoomConceptImportProvenance
    var createdAt: Date
    var importedAt: Date
    var attachments: [RoomConceptSetAttachment]
    var comments: [String]
    var approvalState: RoomConceptApprovalState
    var archiveState: RoomConceptArchiveState

    var model: RoomConceptSet {
        RoomConceptSet(
            schemaVersion: schemaVersion,
            conceptSetID: conceptSetID,
            sourceRevision: sourceRevision,
            request: request,
            scope: scope,
            provider: provider,
            sourceAIRoomPackage: sourceAIRoomPackage,
            importProvenance: importProvenance,
            createdAt: createdAt,
            importedAt: importedAt,
            attachments: attachments,
            comments: comments,
            approvalState: approvalState,
            archiveState: archiveState
        )
    }
}

private enum RoomConceptSetRules {
    static let maximumAttachmentCount = 64
    static let maximumAttachmentBytes: UInt64 = 32 * 1_024 * 1_024
    static let maximumCommentCount = 1_000

    static func requireIdentifier(_ value: String, at path: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(value) else {
            throw RoomConceptSetError.invalidValue(path: path, reason: "Value must be a stable ASCII identifier.")
        }
    }

    static func requireSHA256(_ value: String, at path: String) throws {
        guard value.utf8.count == 64,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) })
        else {
            throw RoomConceptSetError.invalidValue(path: path, reason: "Value must be lowercase SHA-256 hex.")
        }
    }

    static func requireText(_ value: String, maximum: Int, at path: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.utf8.count <= maximum else {
            throw RoomConceptSetError.invalidValue(path: path, reason: "Text must be nonempty and bounded.")
        }
    }

    static func requirePortableFilename(_ value: String, at path: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains(":"),
              value != ".",
              value != "..",
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 95:
                      return true
                  default:
                      return false
                  }
              })
        else {
            throw RoomConceptSetError.invalidValue(path: path, reason: "Source filename must be one portable ASCII basename.")
        }
    }

    static func requireUnique<T: Hashable>(_ values: [T], at path: String) throws {
        guard Set(values).count == values.count else {
            throw RoomConceptSetError.invalidValue(path: path, reason: "Values must be unique.")
        }
    }

    static func requireUniqueCaseFolded(_ values: [String], at path: String) throws {
        let folded = values.map { $0.lowercased() }
        guard Set(folded).count == folded.count else {
            throw RoomConceptSetError.invalidValue(path: path, reason: "Paths must not collide by ASCII case.")
        }
    }

    static func validatedIdentifiers(_ values: [String], at path: String) throws -> Set<String> {
        try requireUnique(values, at: path)
        for (index, value) in values.enumerated() {
            try requireIdentifier(value, at: "\(path)[\(index)]")
        }
        return Set(values)
    }
}

private enum RoomConceptStrictJSON {
    static func validate(_ root: [String: Any]) throws {
        try keys(
            root,
            required: [
                "schemaVersion", "conceptSetID", "sourceRevision", "request", "scope",
                "importProvenance", "createdAt", "importedAt", "attachments", "comments",
                "approvalState", "archiveState",
            ],
            optional: ["provider", "sourceAIRoomPackage"],
            path: "$"
        )
        guard let schemaVersion = root["schemaVersion"] as? String else {
            throw RoomConceptSetError.invalidJSON
        }
        guard schemaVersion == RoomConceptSet.schemaVersionValue else {
            throw RoomConceptSetError.unsupportedSchemaVersion(schemaVersion)
        }
        let source = try object(root, key: "sourceRevision", path: "$")
        try keys(
            source,
            required: [
                "projectID", "revisionID", "coordinateSpaceEpochID", "packageSchemaVersion",
                "semanticSHA256", "revisionManifestSHA256",
            ],
            path: "$.sourceRevision"
        )
        let provenance = try object(root, key: "importProvenance", path: "$")
        try keys(
            provenance,
            required: ["kind", "sourceFilename"],
            path: "$.importProvenance"
        )
        if let packageValue = root["sourceAIRoomPackage"] {
            guard let package = packageValue as? [String: Any] else {
                throw RoomConceptSetError.invalidJSON
            }
            try keys(
                package,
                required: ["schemaVersion", "packageID"],
                path: "$.sourceAIRoomPackage"
            )
        }
        guard let attachments = root["attachments"] as? [Any] else {
            throw RoomConceptSetError.invalidJSON
        }
        for (index, rawAttachment) in attachments.enumerated() {
            guard let attachment = rawAttachment as? [String: Any] else {
                throw RoomConceptSetError.invalidJSON
            }
            let path = "$.attachments[\(index)]"
            try keys(
                attachment,
                required: [
                    "attachmentID", "relativePath", "sha256", "byteCount", "mediaType",
                    "sanitizationProvenance", "mapping",
                ],
                path: path
            )
            let mapping = try object(attachment, key: "mapping", path: path)
            try keys(
                mapping,
                required: ["status"],
                optional: ["cameraID"],
                path: "\(path).mapping"
            )
        }
    }

    private static func object(_ object: [String: Any], key: String, path: String) throws -> [String: Any] {
        guard let result = object[key] as? [String: Any] else {
            throw RoomConceptSetError.invalidJSON
        }
        return result
    }

    private static func keys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = [],
        path: String
    ) throws {
        for key in required where object[key] == nil {
            throw RoomConceptSetError.missingKey(path: path, key: key)
        }
        let allowed = required.union(optional)
        if let unknown = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw RoomConceptSetError.unknownKey(path: path, key: unknown)
        }
    }
}

private enum RoomConceptJSONMemberScanner {
    private enum Container {
        case object(keys: Set<String>, expectsKey: Bool)
        case array
    }

    static func rejectDuplicateObjectMembers(in data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw RoomConceptSetError.invalidJSON
        }
        let scalars = Array(source.unicodeScalars)
        var stack: [Container] = []
        var index = 0
        while index < scalars.count {
            switch scalars[index].value {
            case 0x22:
                let start = index
                let value = try parseString(scalars, index: &index)
                if case let .object(keys, expectsKey)? = stack.last, expectsKey {
                    var lookahead = index
                    skipWhitespace(scalars, index: &lookahead)
                    guard lookahead < scalars.count, scalars[lookahead].value == 0x3a else {
                        index = max(index, start + 1)
                        continue
                    }
                    guard !keys.contains(value) else {
                        throw RoomConceptSetError.duplicateKey(
                            path: stack.count <= 1 ? "$" : "$<object-depth-\(stack.count)>",
                            key: value
                        )
                    }
                    var updated = keys
                    updated.insert(value)
                    stack[stack.count - 1] = .object(keys: updated, expectsKey: false)
                }
            case 0x7b:
                stack.append(.object(keys: [], expectsKey: true))
                index += 1
            case 0x7d:
                if !stack.isEmpty { stack.removeLast() }
                index += 1
            case 0x5b:
                stack.append(.array)
                index += 1
            case 0x5d:
                if !stack.isEmpty { stack.removeLast() }
                index += 1
            case 0x2c:
                if case let .object(keys, _)? = stack.last {
                    stack[stack.count - 1] = .object(keys: keys, expectsKey: true)
                }
                index += 1
            default:
                index += 1
            }
        }
    }

    private static func parseString(_ scalars: [UnicodeScalar], index: inout Int) throws -> String {
        index += 1
        var output = ""
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x22 {
                index += 1
                return output
            }
            if scalar.value != 0x5c {
                output.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { throw RoomConceptSetError.invalidJSON }
            switch scalars[index].value {
            case 0x22, 0x5c, 0x2f:
                output.unicodeScalars.append(scalars[index])
                index += 1
            case 0x62:
                output.unicodeScalars.append("\u{8}")
                index += 1
            case 0x66:
                output.unicodeScalars.append("\u{c}")
                index += 1
            case 0x6e:
                output.unicodeScalars.append("\n")
                index += 1
            case 0x72:
                output.unicodeScalars.append("\r")
                index += 1
            case 0x74:
                output.unicodeScalars.append("\t")
                index += 1
            case 0x75:
                index += 1
                let first = try parseHexQuad(scalars, index: &index)
                if (0xd800...0xdbff).contains(first) {
                    guard index + 1 < scalars.count,
                          scalars[index].value == 0x5c,
                          scalars[index + 1].value == 0x75
                    else { throw RoomConceptSetError.invalidJSON }
                    index += 2
                    let second = try parseHexQuad(scalars, index: &index)
                    guard (0xdc00...0xdfff).contains(second),
                          let scalar = UnicodeScalar(0x10000 + ((first - 0xd800) << 10) + second - 0xdc00)
                    else { throw RoomConceptSetError.invalidJSON }
                    output.unicodeScalars.append(scalar)
                } else {
                    guard !(0xdc00...0xdfff).contains(first), let scalar = UnicodeScalar(first) else {
                        throw RoomConceptSetError.invalidJSON
                    }
                    output.unicodeScalars.append(scalar)
                }
            default:
                throw RoomConceptSetError.invalidJSON
            }
        }
        throw RoomConceptSetError.invalidJSON
    }

    private static func parseHexQuad(_ scalars: [UnicodeScalar], index: inout Int) throws -> UInt32 {
        guard index + 4 <= scalars.count else { throw RoomConceptSetError.invalidJSON }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt32
            switch scalars[index].value {
            case 0x30...0x39: digit = scalars[index].value - 0x30
            case 0x41...0x46: digit = scalars[index].value - 0x41 + 10
            case 0x61...0x66: digit = scalars[index].value - 0x61 + 10
            default: throw RoomConceptSetError.invalidJSON
            }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }

    private static func skipWhitespace(_ scalars: [UnicodeScalar], index: inout Int) {
        while index < scalars.count, [0x20, 0x09, 0x0a, 0x0d].contains(scalars[index].value) {
            index += 1
        }
    }
}
