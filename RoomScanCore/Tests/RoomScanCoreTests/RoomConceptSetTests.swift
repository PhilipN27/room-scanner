import Foundation
import XCTest
@testable import RoomScanCore

final class RoomConceptSetTests: XCTestCase {
    func testCanonicalRoundTripPreservesExactSourceProvenanceAndPerAttachmentMappings() throws {
        let source = makeSource()
        let package = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-001"
        )
        let concept = try makeConceptSet(source: source, sourcePackage: package)
        let binding = try makeValidatedBinding(
            source: source,
            package: package,
            cameraIDs: ["canonical-front"]
        )
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: source,
            currentCanonicalCameraIDs: ["canonical-front", "canonical-side"],
            validatedSourceAIRoomPackages: [binding]
        )

        let encoded = try RoomConceptSetCanonicalJSON.encode(concept)
        let decoded = try RoomConceptSetDecoder.decodeCanonical(encoded, context: context)

        XCTAssertEqual(decoded, concept)
        XCTAssertEqual(try RoomConceptSetCanonicalJSON.encode(decoded), encoded)
        XCTAssertEqual(decoded.attachments.map(\.mapping.status), [.automatic, .manual, .unmatched])
        XCTAssertEqual(decoded.attachments.map(\.mapping.cameraID), ["canonical-front", "canonical-side", nil])
    }

    func testAutomaticMappingRequiresCurrentCameraAndExactPackageDeclaration() throws {
        let source = makeSource()
        let package = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-001"
        )
        let concept = try makeConceptSet(source: source, sourcePackage: package)
        let bytes = try RoomConceptSetCanonicalJSON.encode(concept)
        let binding = try makeValidatedBinding(
            source: source,
            package: package,
            cameraIDs: ["canonical-front"]
        )

        XCTAssertThrowsError(
            try RoomConceptSetDecoder.decodeCanonical(
                bytes,
                context: .init(
                    expectedSourceRevision: source,
                    currentCanonicalCameraIDs: ["canonical-side"],
                    validatedSourceAIRoomPackages: [binding]
                )
            )
        )
        XCTAssertThrowsError(
            try RoomConceptSetDecoder.decodeCanonical(
                bytes,
                context: .init(
                    expectedSourceRevision: source,
                    currentCanonicalCameraIDs: ["canonical-front", "canonical-side"],
                    validatedSourceAIRoomPackages: [
                        try makeValidatedBinding(
                            source: source,
                            package: package,
                            cameraIDs: ["canonical-other"]
                        ),
                    ]
                )
            )
        )
    }

    func testAutomaticMappingRequiresExactValidatedSourcePackageBinding() throws {
        let source = makeSource()
        let package = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-001"
        )
        let concept = try makeConceptSet(source: source, sourcePackage: package)
        let data = try RoomConceptSetCanonicalJSON.encode(concept)
        let currentCameraIDs = ["canonical-front", "canonical-side"]

        XCTAssertNoThrow(
            try RoomConceptSetDecoder.decodeCanonical(
                data,
                context: .init(
                    expectedSourceRevision: source,
                    currentCanonicalCameraIDs: currentCameraIDs,
                    validatedSourceAIRoomPackages: [
                        try makeValidatedBinding(
                            source: source,
                            package: package,
                            cameraIDs: ["canonical-front"]
                        ),
                    ]
                )
            )
        )

        var wrongSource = source
        wrongSource.revisionID = "revision-other"
        let wrongPackage = RoomConceptSourceAIRoomPackage(
            schemaVersion: package.schemaVersion,
            packageID: "ai-package-other"
        )
        for binding in [
            try makeValidatedBinding(
                source: wrongSource,
                package: package,
                cameraIDs: ["canonical-front"]
            ),
            try makeValidatedBinding(
                source: source,
                package: wrongPackage,
                cameraIDs: ["canonical-front"]
            ),
            try makeValidatedBinding(
                source: source,
                package: package,
                cameraIDs: ["canonical-other"]
            ),
        ] {
            XCTAssertThrowsError(
                try RoomConceptSetDecoder.decodeCanonical(
                    data,
                    context: .init(
                        expectedSourceRevision: source,
                        currentCanonicalCameraIDs: currentCameraIDs,
                        validatedSourceAIRoomPackages: [binding]
                    )
                )
            )
        }
    }

    func testPackagedManualAndUnmatchedMappingsRemainValidWithoutReviewedAIPackage() throws {
        let source = makeSource()
        let sourcePackage = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "provider-package-001"
        )
        let png = Self.safePNG
        let manual = RoomConceptSetAttachment(
            attachmentID: "attachment-001",
            relativePath: "attachments/attachment-001.png",
            sha256: RoomSHA256.hexDigest(of: png),
            byteCount: UInt64(png.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedPackagedFile,
            mapping: .manual(cameraID: "canonical-front")
        )
        let unmatched = RoomConceptSetAttachment(
            attachmentID: "attachment-001",
            relativePath: "attachments/attachment-001.png",
            sha256: RoomSHA256.hexDigest(of: png),
            byteCount: UInt64(png.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedPackagedFile,
            mapping: .unmatched
        )
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: source,
            currentCanonicalCameraIDs: ["canonical-front"]
        )

        for attachment in [manual, unmatched] {
            let concept = try makeConceptSet(
                source: source,
                sourcePackage: sourcePackage,
                attachments: [attachment]
            )
            XCTAssertNoThrow(
                try RoomConceptSetDecoder.decodeCanonical(
                    RoomConceptSetCanonicalJSON.encode(concept),
                    context: context
                )
            )
        }
    }

    func testAutomaticMappingCannotBorrowOnlyCurrentAndClaimedPackageCameraIDs() throws {
        let source = makeSource()
        let sourcePackage = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "unreviewed-package-001"
        )
        let concept = try makeConceptSet(source: source, sourcePackage: sourcePackage)

        XCTAssertThrowsError(
            try RoomConceptSetDecoder.decodeCanonical(
                RoomConceptSetCanonicalJSON.encode(concept),
                context: .init(
                    expectedSourceRevision: source,
                    currentCanonicalCameraIDs: ["canonical-front", "canonical-side"]
                )
            )
        ) { error in
            guard case RoomConceptSetError.invalidValue(let path, _) = error else {
                return XCTFail("Expected an automatic-mapping validation error, got \(error)")
            }
            XCTAssertEqual(path, "attachments[0].mapping")
        }
    }

    func testManualAndUnmatchedMappingsFailClosedOnInvalidCameraShapes() throws {
        let source = makeSource()
        let png = Self.safePNG
        let base = RoomConceptSetAttachment(
            attachmentID: "attachment-001",
            relativePath: "attachments/attachment-001.png",
            sha256: RoomSHA256.hexDigest(of: png),
            byteCount: UInt64(png.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedLooseFile,
            mapping: .manual(cameraID: "canonical-missing")
        )
        let manual = try makeConceptSet(
            source: source,
            sourcePackage: nil,
            provenance: .init(kind: .looseLocalFile, sourceFilename: "concept.png"),
            attachments: [base]
        )
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: source,
            currentCanonicalCameraIDs: ["canonical-front"]
        )
        XCTAssertThrowsError(
            try RoomConceptSetDecoder.decodeCanonical(
                RoomConceptSetCanonicalJSON.encode(manual),
                context: context
            )
        )

        let unmatchedWithCamera = replacingJSON(
            try RoomConceptSetCanonicalJSON.encode(
                makeConceptSet(
                    source: source,
                    sourcePackage: nil,
                    provenance: .init(kind: .looseLocalFile, sourceFilename: "concept.png"),
                    attachments: [
                        RoomConceptSetAttachment(
                            attachmentID: "attachment-001",
                            relativePath: "attachments/attachment-001.png",
                            sha256: RoomSHA256.hexDigest(of: png),
                            byteCount: UInt64(png.count),
                            mediaType: "image/png",
                            sanitizationProvenance: .appReencodedLooseFile,
                            mapping: .unmatched
                        )
                    ]
                )
            ),
            replacing: "\"status\":\"unmatched\"",
            with: "\"cameraID\":\"canonical-front\",\"status\":\"unmatched\""
        )
        XCTAssertThrowsError(try RoomConceptSetDecoder.decodeCanonical(unmatchedWithCamera, context: context))
    }

    func testLooseImportRequiresOneAttachmentAndCannotClaimPackageProvenance() throws {
        let source = makeSource()
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: source,
            currentCanonicalCameraIDs: ["canonical-front"]
        )
        var multipleAttachments = try makeLooseConceptSet(source: source)
        var second = try XCTUnwrap(multipleAttachments.attachments.first)
        second.attachmentID = "attachment-002"
        second.relativePath = "attachments/attachment-002.png"
        multipleAttachments.attachments.append(second)

        XCTAssertThrowsError(
            try RoomConceptSetDecoder.decodeCanonical(
                RoomConceptSetCanonicalJSON.encode(multipleAttachments),
                context: context
            )
        )

        let package = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-001"
        )
        var packageClaim = try makeLooseConceptSet(source: source)
        packageClaim.sourceAIRoomPackage = package
        XCTAssertThrowsError(
            try RoomConceptSetDecoder.decodeCanonical(
                RoomConceptSetCanonicalJSON.encode(packageClaim),
                context: .init(
                    expectedSourceRevision: source,
                    currentCanonicalCameraIDs: ["canonical-front"]
                )
            )
        )
    }

    func testPackageReviewContextAllowsLooseSetsButRequiresExactPackagedProvenance() throws {
        let source = makeSource()
        let reviewedPackage = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-001"
        )
        let binding = try makeValidatedBinding(
            source: source,
            package: reviewedPackage,
            cameraIDs: ["canonical-front"]
        )
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: source,
            currentCanonicalCameraIDs: ["canonical-front", "canonical-side"],
            validatedSourceAIRoomPackages: [binding]
        )

        let loose = try makeLooseConceptSet(source: source)
        XCTAssertEqual(
            try RoomConceptSetDecoder.decodeCanonical(
                RoomConceptSetCanonicalJSON.encode(loose),
                context: context
            ),
            loose
        )

        var mismatchedPackaged = try makeConceptSet(source: source, sourcePackage: reviewedPackage)
        mismatchedPackaged.sourceAIRoomPackage?.packageID = "ai-package-other"
        XCTAssertThrowsError(
            try RoomConceptSetDecoder.decodeCanonical(
                RoomConceptSetCanonicalJSON.encode(mismatchedPackaged),
                context: context
            )
        )
    }

    func testDecoderRejectsDuplicateUnknownAndNoncanonicalJSON() throws {
        let source = makeSource()
        let concept = try makeLooseConceptSet(source: source)
        let canonical = try RoomConceptSetCanonicalJSON.encode(concept)
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: source,
            currentCanonicalCameraIDs: ["canonical-front"]
        )

        let duplicate = replacingJSON(
            canonical,
            replacing: "\"schemaVersion\":\"roomscan-concept-set-v1\"",
            with: "\"schemaVersion\":\"roomscan-concept-set-v1\",\"schema\\u0056ersion\":\"roomscan-concept-set-v1\""
        )
        XCTAssertThrowsError(try RoomConceptSetDecoder.decodeCanonical(duplicate, context: context)) { error in
            guard case RoomConceptSetError.duplicateKey = error else {
                return XCTFail("Expected an escaped duplicate-key rejection, got \(error)")
            }
        }

        let unknownNested = replacingJSON(
            canonical,
            replacing: "\"status\":\"unmatched\"",
            with: "\"externalURL\":\"https://example.invalid/concept.png\",\"status\":\"unmatched\""
        )
        XCTAssertThrowsError(try RoomConceptSetDecoder.decodeCanonical(unknownNested, context: context)) { error in
            guard case RoomConceptSetError.unknownKey = error else {
                return XCTFail("Expected an unknown-key rejection, got \(error)")
            }
        }

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        let noncanonical = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        XCTAssertThrowsError(try RoomConceptSetDecoder.decodeCanonical(noncanonical, context: context)) { error in
            XCTAssertEqual(error as? RoomConceptSetError, .noncanonicalJSON)
        }
    }

    func testDecoderRejectsRebindingUnsafePathsAndMislabeledMedia() throws {
        let source = makeSource()
        let concept = try makeLooseConceptSet(source: source)
        let canonical = try RoomConceptSetCanonicalJSON.encode(concept)
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: source,
            currentCanonicalCameraIDs: ["canonical-front"]
        )
        let other = RoomRedesignSourceRevision(
            projectID: source.projectID,
            revisionID: "revision-other",
            coordinateSpaceEpochID: source.coordinateSpaceEpochID,
            packageSchemaVersion: source.packageSchemaVersion,
            semanticSHA256: source.semanticSHA256,
            revisionManifestSHA256: source.revisionManifestSHA256
        )
        XCTAssertThrowsError(
            try RoomConceptSetDecoder.decodeCanonical(
                canonical,
                context: .init(expectedSourceRevision: other, currentCanonicalCameraIDs: ["canonical-front"])
            )
        )

        let traversal = replacingJSON(
            canonical,
            replacing: "attachments/attachment-001.png",
            with: "attachments/../escape.png"
        )
        XCTAssertThrowsError(try RoomConceptSetDecoder.decodeCanonical(traversal, context: context))

        let mislabeled = replacingJSON(
            canonical,
            replacing: "\"mediaType\":\"image/png\"",
            with: "\"mediaType\":\"application/zip\""
        )
        XCTAssertThrowsError(try RoomConceptSetDecoder.decodeCanonical(mislabeled, context: context))
    }

    func testSanitizedImageValidatorAcceptsBoundedPNGAndJPEGAndRejectsTrailingContent() throws {
        let pngInfo = try RoomConceptImageValidator.validateSanitizedImage(
            Self.safePNG,
            mediaType: "image/png"
        )
        XCTAssertEqual(pngInfo, .init(pixelWidth: 1, pixelHeight: 1))

        let jpegInfo = try RoomConceptImageValidator.validateSanitizedImage(
            Self.safeJPEG,
            mediaType: "image/jpeg"
        )
        XCTAssertEqual(jpegInfo, .init(pixelWidth: 1, pixelHeight: 1))

        XCTAssertThrowsError(
            try RoomConceptImageValidator.validateSanitizedImage(
                Self.safePNG + Data([0x50, 0x4b, 0x03, 0x04]),
                mediaType: "image/png"
            )
        )
        XCTAssertThrowsError(
            try RoomConceptImageValidator.validateSanitizedImage(
                Self.safeJPEG + Data("hidden".utf8),
                mediaType: "image/jpeg"
            )
        )
        XCTAssertThrowsError(
            try RoomConceptImageValidator.validateSanitizedImage(
                Self.safePNG,
                mediaType: "image/jpeg"
            )
        )
    }

    func testSanitizedImageValidatorEnforcesByteDimensionAndPixelCaps() throws {
        XCTAssertThrowsError(
            try RoomConceptImageValidator.validateSanitizedImage(
                Self.safePNG,
                mediaType: "image/png",
                limits: .init(maxBytes: UInt64(Self.safePNG.count - 1), maxPixelDimension: 8, maxPixelCount: 64)
            )
        )
        XCTAssertThrowsError(
            try RoomConceptImageValidator.validateSanitizedImage(
                Self.safePNG,
                mediaType: "image/png",
                limits: .init(maxBytes: 1_024, maxPixelDimension: 0, maxPixelCount: 64)
            )
        )
        XCTAssertThrowsError(
            try RoomConceptImageValidator.validateSanitizedImage(
                Self.safePNG,
                mediaType: "image/png",
                limits: .init(maxBytes: 1_024, maxPixelDimension: 8, maxPixelCount: 0)
            )
        )
    }

    func testPackagedImportValidatesStoreArchiveClosureDigestsMediaAndSource() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = makeSource()
        let package = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-001"
        )
        var concept = try makeLooseConceptSet(
            source: source,
            provenance: .init(kind: .packagedOutput, sourceFilename: "provider-concepts.zip"),
            sanitization: .appReencodedPackagedFile
        )
        concept.sourceAIRoomPackage = package
        let archive = temporary.appendingPathComponent("concepts.zip")
        try await writeArchive(concept: concept, to: archive, root: temporary)
        let extraction = temporary.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)

        let result = try await RoomConceptSetArchive.validateImport(
            archiveURL: archive,
            extractionDirectoryURL: extraction,
            context: .init(
                expectedSourceRevision: source,
                currentCanonicalCameraIDs: ["canonical-front"]
            )
        )

        XCTAssertEqual(result.conceptSet, concept)
        XCTAssertEqual(Set(result.attachmentURLs.keys), Set(["attachment-001"]))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.attachmentURLs["attachment-001"])), Self.safePNG)
    }

    func testPackagedImportRejectsHiddenNestedArchiveWrongDigestAndWrongSource() async throws {
        let source = makeSource()
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: source,
            currentCanonicalCameraIDs: ["canonical-front"]
        )

        do {
            let temporary = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let concept = try makeLooseConceptSet(
                source: source,
                provenance: .init(kind: .packagedOutput, sourceFilename: "provider-concepts.zip"),
                sanitization: .appReencodedPackagedFile
            )
            let archive = temporary.appendingPathComponent("nested.zip")
            try await writeArchive(
                concept: concept,
                to: archive,
                root: temporary,
                extras: [("attachments/hidden.zip", Data([0x50, 0x4b, 0x03, 0x04]))]
            )
            let extraction = temporary.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
            await assertThrowsAsync {
                _ = try await RoomConceptSetArchive.validateImport(
                    archiveURL: archive,
                    extractionDirectoryURL: extraction,
                    context: context
                )
            }
        }

        do {
            let temporary = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            var concept = try makeLooseConceptSet(
                source: source,
                provenance: .init(kind: .packagedOutput, sourceFilename: "provider-concepts.zip"),
                sanitization: .appReencodedPackagedFile
            )
            concept.attachments[0].sha256 = String(repeating: "f", count: 64)
            let archive = temporary.appendingPathComponent("wrong-digest.zip")
            try await writeArchive(concept: concept, to: archive, root: temporary)
            let extraction = temporary.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
            await assertThrowsAsync {
                _ = try await RoomConceptSetArchive.validateImport(
                    archiveURL: archive,
                    extractionDirectoryURL: extraction,
                    context: context
                )
            }
        }

        do {
            let temporary = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let rebound = RoomRedesignSourceRevision(
                projectID: source.projectID,
                revisionID: "revision-other",
                coordinateSpaceEpochID: source.coordinateSpaceEpochID,
                packageSchemaVersion: source.packageSchemaVersion,
                semanticSHA256: source.semanticSHA256,
                revisionManifestSHA256: source.revisionManifestSHA256
            )
            let concept = try makeLooseConceptSet(
                source: rebound,
                provenance: .init(kind: .packagedOutput, sourceFilename: "provider-concepts.zip"),
                sanitization: .appReencodedPackagedFile
            )
            let archive = temporary.appendingPathComponent("rebound.zip")
            try await writeArchive(concept: concept, to: archive, root: temporary)
            let extraction = temporary.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
            await assertThrowsAsync {
                _ = try await RoomConceptSetArchive.validateImport(
                    archiveURL: archive,
                    extractionDirectoryURL: extraction,
                    context: context
                )
            }
        }
    }

    func testPackagedImportRejectsUnsupportedCompressionProfile() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = makeSource()
        let concept = try makeLooseConceptSet(
            source: source,
            provenance: .init(kind: .packagedOutput, sourceFilename: "provider-concepts.zip"),
            sanitization: .appReencodedPackagedFile
        )
        let archive = temporary.appendingPathComponent("compressed.zip")
        try await writeArchive(concept: concept, to: archive, root: temporary)
        var bytes = try Data(contentsOf: archive)
        bytes[8] = 8
        bytes[9] = 0
        guard let central = bytes.firstRange(of: Data([0x50, 0x4b, 0x01, 0x02]))?.lowerBound else {
            return XCTFail("Expected deterministic ZIP central directory")
        }
        bytes[central + 10] = 8
        bytes[central + 11] = 0
        try bytes.write(to: archive, options: .atomic)
        let extraction = temporary.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)

        await assertThrowsAsync {
            _ = try await RoomConceptSetArchive.validateImport(
                archiveURL: archive,
                extractionDirectoryURL: extraction,
                context: .init(
                    expectedSourceRevision: source,
                    currentCanonicalCameraIDs: ["canonical-front"]
                )
            )
        }
    }

    func testPackagedImportRejectsLimitsThatExpandTheV1ImageCaps() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = makeSource()
        let concept = try makeLooseConceptSet(
            source: source,
            provenance: .init(kind: .packagedOutput, sourceFilename: "provider-concepts.zip"),
            sanitization: .appReencodedPackagedFile
        )
        let archive = temporary.appendingPathComponent("concepts.zip")
        try await writeArchive(concept: concept, to: archive, root: temporary)
        let extraction = temporary.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)

        do {
            _ = try await RoomConceptSetArchive.validateImport(
                archiveURL: archive,
                extractionDirectoryURL: extraction,
                context: .init(
                    expectedSourceRevision: source,
                    currentCanonicalCameraIDs: ["canonical-front"]
                ),
                limits: .init(
                    imageLimits: .init(
                        maxBytes: 32 * 1_024 * 1_024,
                        maxPixelDimension: 8_193,
                        maxPixelCount: 40_000_000
                    )
                )
            )
            XCTFail("Expected the fixed v1 image cap to reject expanded caller limits")
        } catch {
            XCTAssertEqual(
                error as? RoomConceptSetError,
                .limitExceeded("Concept archive limits must remain inside the v1 profile caps.")
            )
        }
    }

    func testPreCancelledPackagedImportReturnsStableCancellationAndExtractsNothing() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = makeSource()
        let concept = try makeLooseConceptSet(
            source: source,
            provenance: .init(kind: .packagedOutput, sourceFilename: "provider-concepts.zip"),
            sanitization: .appReencodedPackagedFile
        )
        let archive = temporary.appendingPathComponent("concepts.zip")
        try await writeArchive(concept: concept, to: archive, root: temporary)
        let extraction = temporary.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RoomConceptSetArchive.validateImport(
                archiveURL: archive,
                extractionDirectoryURL: extraction,
                context: .init(
                    expectedSourceRevision: source,
                    currentCanonicalCameraIDs: ["canonical-front"]
                )
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected stable Concept Set cancellation")
        } catch {
            XCTAssertEqual(error as? RoomConceptSetError, .cancelled)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: extraction.path),
            []
        )
    }

    private func makeSource() -> RoomRedesignSourceRevision {
        RoomRedesignSourceRevision(
            projectID: "project-001",
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: "room-scan-project-v2",
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
    }

    private func makeValidatedBinding(
        source: RoomRedesignSourceRevision,
        package: RoomConceptSourceAIRoomPackage,
        cameraIDs: [String]
    ) throws -> RoomConceptValidatedSourcePackage {
        try .init(
            testOnlySourceRevision: source,
            sourceAIRoomPackage: package,
            canonicalCameraIDs: cameraIDs
        )
    }

    private func makeConceptSet(
        source: RoomRedesignSourceRevision,
        sourcePackage: RoomConceptSourceAIRoomPackage?,
        provenance: RoomConceptImportProvenance = .init(kind: .packagedOutput, sourceFilename: "provider-concepts.zip"),
        attachments: [RoomConceptSetAttachment]? = nil
    ) throws -> RoomConceptSet {
        let png = Self.safePNG
        let resolvedAttachments = attachments ?? [
            RoomConceptSetAttachment(
                attachmentID: "attachment-001",
                relativePath: "attachments/attachment-001.png",
                sha256: RoomSHA256.hexDigest(of: png),
                byteCount: UInt64(png.count),
                mediaType: "image/png",
                sanitizationProvenance: .appReencodedPackagedFile,
                mapping: .automatic(cameraID: "canonical-front")
            ),
            RoomConceptSetAttachment(
                attachmentID: "attachment-002",
                relativePath: "attachments/attachment-002.png",
                sha256: RoomSHA256.hexDigest(of: png),
                byteCount: UInt64(png.count),
                mediaType: "image/png",
                sanitizationProvenance: .appReencodedPackagedFile,
                mapping: .manual(cameraID: "canonical-side")
            ),
            RoomConceptSetAttachment(
                attachmentID: "attachment-003",
                relativePath: "attachments/attachment-003.png",
                sha256: RoomSHA256.hexDigest(of: png),
                byteCount: UInt64(png.count),
                mediaType: "image/png",
                sanitizationProvenance: .appReencodedPackagedFile,
                mapping: .unmatched
            ),
        ]
        return RoomConceptSet(
            conceptSetID: "concept-set-001",
            sourceRevision: source,
            request: "Make the room warmer without moving the windows.",
            scope: .renovate,
            provider: "Example Provider",
            sourceAIRoomPackage: sourcePackage,
            importProvenance: provenance,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            importedAt: Date(timeIntervalSince1970: 1_700_000_100),
            attachments: resolvedAttachments,
            comments: ["Keep the first concept for comparison."],
            approvalState: .pending,
            archiveState: .active
        )
    }

    private func makeLooseConceptSet(
        source: RoomRedesignSourceRevision,
        provenance: RoomConceptImportProvenance = .init(kind: .looseLocalFile, sourceFilename: "concept.png"),
        sanitization: RoomConceptSanitizationProvenance = .appReencodedLooseFile
    ) throws -> RoomConceptSet {
        let png = Self.safePNG
        return RoomConceptSet(
            conceptSetID: "concept-set-001",
            sourceRevision: source,
            request: "A lighter material direction.",
            scope: .stage,
            provider: nil,
            sourceAIRoomPackage: nil,
            importProvenance: provenance,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            importedAt: Date(timeIntervalSince1970: 1_700_000_100),
            attachments: [
                RoomConceptSetAttachment(
                    attachmentID: "attachment-001",
                    relativePath: "attachments/attachment-001.png",
                    sha256: RoomSHA256.hexDigest(of: png),
                    byteCount: UInt64(png.count),
                    mediaType: "image/png",
                    sanitizationProvenance: sanitization,
                    mapping: .unmatched
                )
            ],
            comments: [],
            approvalState: .pending,
            archiveState: .active
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomConceptSetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func writeArchive(
        concept: RoomConceptSet,
        to archiveURL: URL,
        root: URL,
        extras: [(String, Data)] = []
    ) async throws {
        let materialization = root.appendingPathComponent("materialization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: materialization, withIntermediateDirectories: false)
        let manifestURL = materialization.appendingPathComponent("manifest.json")
        try RoomConceptSetCanonicalJSON.encode(concept).write(to: manifestURL, options: .withoutOverwriting)
        var inputs = [
            RoomZIPInput(
                sourceURL: manifestURL,
                entryPath: try RoomExportEntryPath("manifest.json"),
                mediaType: "application/json"
            )
        ]
        for attachment in concept.attachments {
            let fileURL = materialization.appendingPathComponent(attachment.relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.safePNG.write(to: fileURL, options: .withoutOverwriting)
            inputs.append(
                RoomZIPInput(
                    sourceURL: fileURL,
                    entryPath: try RoomExportEntryPath(attachment.relativePath),
                    mediaType: attachment.mediaType
                )
            )
        }
        for (index, extra) in extras.enumerated() {
            let fileURL = materialization.appendingPathComponent("extra-\(index)")
            try extra.1.write(to: fileURL, options: .withoutOverwriting)
            inputs.append(
                RoomZIPInput(
                    sourceURL: fileURL,
                    entryPath: try RoomExportEntryPath(extra.0),
                    mediaType: "application/octet-stream"
                )
            )
        }
        _ = try await RoomDeterministicZIP.write(inputs: inputs, to: archiveURL)
    }

    private func replacingJSON(_ data: Data, replacing needle: String, with replacement: String) -> Data {
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(string.contains(needle), "Fixture mutation did not reach the intended JSON member")
        return Data(string.replacingOccurrences(of: needle, with: replacement).utf8)
    }

    private func assertThrowsAsync(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {}
    }

    private static let safePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    /// A structurally complete one-pixel baseline JPEG. Core deliberately
    /// verifies framing and dimensions only; the app's ImageIO boundary owns
    /// the required decode and fresh metadata-free re-encode.
    private static let safeJPEG = Data([
        0xff, 0xd8,
        0xff, 0xe0, 0x00, 0x04, 0x00, 0x00,
        0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00,
        0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00,
        0x00,
        0xff, 0xd9,
    ])
}
