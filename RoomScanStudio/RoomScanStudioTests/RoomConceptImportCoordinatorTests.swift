import CoreGraphics
import ImageIO
@testable import RoomScanCore
import UniformTypeIdentifiers
import XCTest
@testable import RoomScanStudio

@MainActor
final class RoomConceptImportCoordinatorTests: XCTestCase {
    func testLooseImportCanonicalizesSubsecondClockBeforeExactPersistence() async throws {
        let fixture = try Fixture()
        try fixture.jpeg(withPrivateComment: nil).write(to: fixture.looseURL)
        let coordinator = RoomConceptImportCoordinator(
            store: LocalRoomConceptStore(
                rootURL: fixture.conceptRoot,
                sourcePackageRootURL: fixture.packageRoot
            ),
            scratchRootURL: fixture.scratchRoot,
            now: { Date(timeIntervalSinceReferenceDate: 100.75) },
            makeIdentifier: { "canonical-time-concept" }
        )

        let imported = try await coordinator.importLoose(
            from: fixture.looseURL,
            request: "Canonical local import",
            scope: .stage,
            context: fixture.context
        )

        XCTAssertEqual(
            imported.createdAt,
            Date(timeIntervalSinceReferenceDate: 100)
        )
        XCTAssertEqual(imported.importedAt, imported.createdAt)
    }

    func testLooseImportReencodesMetadataBindsExactRevisionAndReopens() async throws {
        let fixture = try Fixture()
        let source = try fixture.jpeg(withPrivateComment: "private-exif-note")
        try source.write(to: fixture.looseURL)

        let coordinator = fixture.coordinator()
        let imported = try await coordinator.importLoose(
            from: fixture.looseURL,
            request: "Warm minimal living room",
            scope: .reimagine,
            context: fixture.context
        )

        XCTAssertEqual(imported.sourceRevision, fixture.sourceRevision)
        XCTAssertNil(imported.provider)
        XCTAssertNil(imported.sourceAIRoomPackage)
        XCTAssertEqual(imported.attachments.single?.mapping, .unmatched)
        XCTAssertEqual(imported.attachments.single?.sanitizationProvenance, .appReencodedLooseFile)
        let reopened = try await coordinator.load(imported.conceptSetID, context: fixture.context)
        let bytes = try await coordinator.attachmentData(
            conceptSetID: imported.conceptSetID,
            attachmentID: try XCTUnwrap(imported.attachments.single?.attachmentID),
            context: fixture.context
        )
        XCTAssertEqual(reopened, imported)
        XCTAssertFalse(bytes.contains(Data("private-exif-note".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.scratchRoot.path))
    }

    func testWrongRevisionAndUnsupportedLooseInputPublishNothing() async throws {
        let fixture = try Fixture()
        try Data("<svg><script/></svg>".utf8).write(to: fixture.looseURL)
        let coordinator = fixture.coordinator()
        var wrong = fixture.context
        wrong.expectedSourceRevision.revisionID = "other-revision"

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.importLoose(
                from: fixture.looseURL,
                request: "Safe request",
                scope: .stage,
                context: wrong
            )
        }
        let concepts = try await coordinator.list(context: fixture.context)
        XCTAssertEqual(concepts, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.scratchRoot.path))
    }

    func testManualReviewArchiveAndDeleteRemainRevisionIsolated() async throws {
        let fixture = try Fixture()
        try fixture.jpeg(withPrivateComment: nil).write(to: fixture.looseURL)
        let coordinator = fixture.coordinator()
        let imported = try await coordinator.importLoose(
            from: fixture.looseURL,
            request: "Brighten the space",
            scope: .renovate,
            context: fixture.context
        )
        let attachmentID = try XCTUnwrap(imported.attachments.single?.attachmentID)
        let reviewed = try await coordinator.updateReview(
            conceptSetID: imported.conceptSetID,
            attachmentMappings: [attachmentID: .manual(cameraID: "camera-1")],
            approvalState: .approved,
            comments: ["Checked locally"],
            context: fixture.context
        )
        XCTAssertEqual(reviewed.approvalState, .approved)
        XCTAssertEqual(reviewed.attachments.single?.mapping, .manual(cameraID: "camera-1"))
        let archived = try await coordinator.archive(imported.conceptSetID, context: fixture.context)
        XCTAssertEqual(archived.archiveState, .archived)
        let unarchived = try await coordinator.unarchive(imported.conceptSetID, context: fixture.context)
        XCTAssertEqual(unarchived.archiveState, .active)
        try await coordinator.delete(imported.conceptSetID, context: fixture.context)
        let concepts = try await coordinator.list(context: fixture.context)
        XCTAssertEqual(concepts, [])
    }

    func testPackagedImportRetainsOnlyExactAutomaticMappingAndDoesNotMutateArchive() async throws {
        let fixture = try Fixture()
        let package = try await fixture.packagedConceptArchive(mapping: .automatic(cameraID: "camera-1"))
        let originalDigest = try RoomSHA256.hexDigest(ofFile: package)
        let packageProvenance = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-1"
        )
        let validatedPackage = try RoomConceptValidatedSourcePackage(
            testOnlySourceRevision: fixture.sourceRevision,
            sourceAIRoomPackage: packageProvenance,
            canonicalCameraIDs: ["camera-1"]
        )
        let context = RoomConceptSetValidationContext(
            expectedSourceRevision: fixture.sourceRevision,
            currentCanonicalCameraIDs: ["camera-1"],
            validatedSourceAIRoomPackages: [validatedPackage]
        )

        let imported = try await fixture.coordinator().importPackage(from: package, context: context)

        XCTAssertEqual(imported.attachments.single?.mapping, .automatic(cameraID: "camera-1"))
        XCTAssertEqual(imported.attachments.single?.sanitizationProvenance, .appReencodedPackagedFile)
        XCTAssertNil(imported.provider)
        XCTAssertEqual(try RoomSHA256.hexDigest(ofFile: package), originalDigest)
    }

    func testPackagedWrongRevisionAndUnmatchedMappingFailClosedOrStayUnmatched() async throws {
        let fixture = try Fixture()
        let package = try await fixture.packagedConceptArchive(mapping: .unmatched)
        let packageProvenance = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-1"
        )
        let validatedPackage = try RoomConceptValidatedSourcePackage(
            testOnlySourceRevision: fixture.sourceRevision,
            sourceAIRoomPackage: packageProvenance,
            canonicalCameraIDs: ["camera-1"]
        )
        let matchingContext = RoomConceptSetValidationContext(
            expectedSourceRevision: fixture.sourceRevision,
            currentCanonicalCameraIDs: ["camera-1"],
            validatedSourceAIRoomPackages: [validatedPackage]
        )
        let imported = try await fixture.coordinator().importPackage(from: package, context: matchingContext)
        XCTAssertEqual(imported.attachments.single?.mapping, .unmatched)

        var wrongRevision = matchingContext
        wrongRevision.expectedSourceRevision.revisionID = "revision-2"
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.coordinator().importPackage(from: package, context: wrongRevision)
        }
        let all = try await fixture.coordinator().list(context: matchingContext)
        XCTAssertEqual(all.map(\.conceptSetID), [imported.conceptSetID])
    }

    func testPromotionFailureAndCancellationPublishNothingAndCleanOwnedScratch() async throws {
        let fixture = try Fixture()
        try fixture.jpeg(withPrivateComment: nil).write(to: fixture.looseURL)
        let coordinator = fixture.coordinator()
        _ = try await coordinator.importLoose(from: fixture.looseURL, request: "One", scope: .stage, context: fixture.context)
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.importLoose(from: fixture.looseURL, request: "Two", scope: .stage, context: fixture.context)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.scratchRoot.path))

        let cancelled = Task { @MainActor in
            try await coordinator.importLoose(from: fixture.looseURL, request: "Three", scope: .stage, context: fixture.context)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.scratchRoot.path))
        let all = try await coordinator.list(context: fixture.context)
        XCTAssertEqual(all.count, 1)
    }

    func testSymlinkInputIsRejectedBeforeReadAndTwoConceptArchivesAreIsolated() async throws {
        let fixture = try Fixture()
        try fixture.jpeg(withPrivateComment: nil).write(to: fixture.looseURL)
        let link = fixture.root.appendingPathComponent("linked.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.looseURL)
        let coordinator = fixture.coordinator(identifier: "concept-1")
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.importLoose(from: link, request: "No link", scope: .stage, context: fixture.context)
        }
        let afterLink = try await coordinator.list(context: fixture.context)
        XCTAssertEqual(afterLink, [])

        let first = try await coordinator.importLoose(from: fixture.looseURL, request: "First", scope: .stage, context: fixture.context)
        let second = try await fixture.coordinator(identifier: "concept-2").importLoose(from: fixture.looseURL, request: "Second", scope: .stage, context: fixture.context)
        _ = try await coordinator.archive(first.conceptSetID, context: fixture.context)
        try await coordinator.delete(first.conceptSetID, context: fixture.context)
        let remaining = try await coordinator.load(second.conceptSetID, context: fixture.context)
        XCTAssertEqual(remaining.conceptSetID, second.conceptSetID)
        XCTAssertEqual(remaining.archiveState, .active)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

@MainActor
private final class Fixture {
    let root: URL
    let conceptRoot: URL
    let packageRoot: URL
    let scratchRoot: URL
    let looseURL: URL
    let sourceRevision = RoomRedesignSourceRevision(
        projectID: "project-1",
        revisionID: "revision-1",
        coordinateSpaceEpochID: "epoch-1",
        packageSchemaVersion: "room-scan-project-v2",
        semanticSHA256: String(repeating: "a", count: 64),
        revisionManifestSHA256: String(repeating: "b", count: 64)
    )

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        conceptRoot = root.appendingPathComponent("Concepts", isDirectory: true)
        packageRoot = root.appendingPathComponent("Projects", isDirectory: true)
        scratchRoot = root.appendingPathComponent("Scratch", isDirectory: true)
        looseURL = root.appendingPathComponent("loose.jpg")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var context: RoomConceptSetValidationContext {
        .init(expectedSourceRevision: sourceRevision, currentCanonicalCameraIDs: ["camera-1"])
    }

    func coordinator(identifier: String = "concept-1") -> RoomConceptImportCoordinator {
        RoomConceptImportCoordinator(
            store: LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: packageRoot),
            scratchRootURL: scratchRoot,
            now: { Date(timeIntervalSinceReferenceDate: 100) },
            makeIdentifier: { identifier }
        )
    }

    func jpeg(withPrivateComment comment: String?) throws -> Data {
        let pixels = Data([20, 30, 40, 255, 60, 70, 80, 255, 90, 100, 110, 255, 120, 130, 140, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = comment.map { [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: $0]] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func packagedConceptArchive(mapping: RoomConceptAttachmentMapping) async throws -> URL {
        let unsafeImage = try jpeg(withPrivateComment: "package-private-note")
        let image = try RoomAIImageSanitizer.sanitize(
            unsafeImage,
            declaredFilename: "attachment-1.jpg"
        ).data
        let attachment = RoomConceptSetAttachment(
            attachmentID: "attachment-1",
            relativePath: "attachments/attachment-1.jpg",
            sha256: RoomSHA256.hexDigest(of: image),
            byteCount: UInt64(image.count),
            mediaType: "image/jpeg",
            sanitizationProvenance: .appReencodedPackagedFile,
            mapping: mapping
        )
        let sourcePackage = RoomConceptSourceAIRoomPackage(
            schemaVersion: "roomscan-ai-room-package-v1",
            packageID: "ai-package-1"
        )
        let concept = RoomConceptSet(
            conceptSetID: "packaged-concept-1",
            sourceRevision: sourceRevision,
            request: "Package request",
            scope: .stage,
            provider: "untrusted-provider",
            sourceAIRoomPackage: sourcePackage,
            importProvenance: .init(kind: .packagedOutput, sourceFilename: "provider.zip"),
            createdAt: Date(timeIntervalSinceReferenceDate: 50),
            importedAt: Date(timeIntervalSinceReferenceDate: 60),
            attachments: [attachment],
            comments: [],
            approvalState: .pending,
            archiveState: .active
        )
        let materialization = root.appendingPathComponent("materialization", isDirectory: true)
        try FileManager.default.createDirectory(at: materialization.appendingPathComponent("attachments", isDirectory: true), withIntermediateDirectories: true)
        let manifest = materialization.appendingPathComponent("manifest.json")
        let payload = materialization.appendingPathComponent(attachment.relativePath)
        try RoomConceptSetCanonicalJSON.encode(concept).write(to: manifest, options: .withoutOverwriting)
        try image.write(to: payload, options: .withoutOverwriting)
        let archive = root.appendingPathComponent("concept.zip")
        _ = try await RoomDeterministicZIP.write(inputs: [
            .init(sourceURL: manifest, entryPath: try RoomExportEntryPath("manifest.json"), mediaType: "application/json"),
            .init(sourceURL: payload, entryPath: try RoomExportEntryPath(attachment.relativePath), mediaType: attachment.mediaType),
        ], to: archive)
        return archive
    }
}
