import Foundation

public struct RoomConceptSetArchiveLimits: Sendable, Equatable {
    public var zipLimits: RoomZIPLimits
    public var maximumManifestBytes: UInt64
    public var imageLimits: RoomConceptImageLimits

    public init(
        zipLimits: RoomZIPLimits = RoomZIPLimits(maxEntries: 65, maxEntryBytes: 32 * 1_024 * 1_024, maxArchiveBytes: 512 * 1_024 * 1_024),
        maximumManifestBytes: UInt64 = 1 * 1_024 * 1_024,
        imageLimits: RoomConceptImageLimits = RoomConceptImageLimits()
    ) {
        self.zipLimits = zipLimits
        self.maximumManifestBytes = maximumManifestBytes
        self.imageLimits = imageLimits
    }
}

public struct RoomConceptSetArchiveImport: Sendable, Equatable {
    public var conceptSet: RoomConceptSet
    public var attachmentURLs: [String: URL]

    public init(conceptSet: RoomConceptSet, attachmentURLs: [String: URL]) {
        self.conceptSet = conceptSet
        self.attachmentURLs = attachmentURLs
    }
}

public enum RoomConceptSetArchive {
    public static func validateImport(
        archiveURL: URL,
        extractionDirectoryURL: URL,
        context: RoomConceptSetValidationContext,
        limits: RoomConceptSetArchiveLimits = RoomConceptSetArchiveLimits()
    ) async throws -> RoomConceptSetArchiveImport {
        guard limits.zipLimits.maxEntries >= 2,
              limits.zipLimits.maxEntries <= 65,
              limits.zipLimits.maxEntryBytes > 0,
              limits.zipLimits.maxEntryBytes <= 32 * 1_024 * 1_024,
              limits.zipLimits.maxArchiveBytes > 0,
              limits.zipLimits.maxArchiveBytes <= 512 * 1_024 * 1_024,
              limits.maximumManifestBytes > 0,
              limits.maximumManifestBytes <= 1 * 1_024 * 1_024,
              limits.imageLimits.maxBytes > 0,
              limits.imageLimits.maxBytes <= RoomConceptImageLimits.v1MaximumBytes,
              limits.imageLimits.maxPixelDimension > 0,
              limits.imageLimits.maxPixelDimension <= RoomConceptImageLimits.v1MaximumPixelDimension,
              limits.imageLimits.maxPixelCount > 0,
              limits.imageLimits.maxPixelCount <= RoomConceptImageLimits.v1MaximumPixelCount
        else {
            throw RoomConceptSetError.limitExceeded("Concept archive limits must remain inside the v1 profile caps.")
        }
        try checkCancellation()

        let entries: [RoomZIPEntryDigest]
        do {
            entries = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
                from: archiveURL,
                into: extractionDirectoryURL,
                limits: limits.zipLimits,
                maximumByteCountByEntryPath: ["manifest.json": limits.maximumManifestBytes]
            )
        } catch is CancellationError {
            throw RoomConceptSetError.cancelled
        } catch let error as RoomExportError {
            if error == .cancelled { throw RoomConceptSetError.cancelled }
            throw RoomConceptSetError.invalidArchive("ZIP32 STORE validation failed: \(error)")
        } catch {
            throw RoomConceptSetError.invalidArchive("ZIP32 STORE validation failed.")
        }
        try checkCancellation()

        guard entries.count >= 2,
              entries.count <= 65,
              entries.filter({ $0.entryPath.value == "manifest.json" }).count == 1
        else {
            throw RoomConceptSetError.invalidArchive("A concept archive needs one manifest and at least one attachment.")
        }
        let manifestURL = extractionDirectoryURL.appendingPathComponent("manifest.json")
        let manifestData: Data
        do {
            let values = try manifestURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  UInt64(size) <= limits.maximumManifestBytes
            else {
                throw RoomConceptSetError.invalidArchive("The concept manifest is not one bounded regular file.")
            }
            manifestData = try Data(contentsOf: manifestURL)
        } catch let error as RoomConceptSetError {
            throw error
        } catch {
            throw RoomConceptSetError.invalidArchive("The extracted concept manifest is unreadable.")
        }
        let conceptSet = try RoomConceptSetDecoder.decodeCanonical(manifestData, context: context)
        guard conceptSet.importProvenance.kind == .packagedOutput else {
            throw RoomConceptSetError.invalidValue(
                path: "importProvenance.kind",
                reason: "A ZIP import must declare packagedOutput provenance."
            )
        }

        let expectedPaths = Set(["manifest.json"] + conceptSet.attachments.map(\.relativePath))
        let actualPaths = Set(entries.map { $0.entryPath.value })
        guard expectedPaths == actualPaths,
              expectedPaths.count == conceptSet.attachments.count + 1
        else {
            throw RoomConceptSetError.invalidArchive(
                "The archive must close exactly over its manifest and declared attachments; nested or hidden entries are forbidden."
            )
        }
        let entriesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.entryPath.value, $0) })
        var attachmentURLs: [String: URL] = [:]
        for attachment in conceptSet.attachments {
            try checkCancellation()
            guard let entry = entriesByPath[attachment.relativePath],
                  entry.byteCount == attachment.byteCount,
                  entry.sha256Hex == attachment.sha256
            else {
                throw RoomConceptSetError.invalidArchive(
                    "Every attachment path, byte count, and SHA-256 must match the archive payload."
                )
            }
            let attachmentURL = extractionDirectoryURL.appendingPathComponent(attachment.relativePath)
            let values: URLResourceValues
            do {
                values = try attachmentURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
            } catch {
                throw RoomConceptSetError.invalidArchive("An extracted attachment is unreadable.")
            }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  UInt64(fileSize) == attachment.byteCount,
                  UInt64(fileSize) <= limits.imageLimits.maxBytes
            else {
                throw RoomConceptSetError.invalidArchive("An extracted attachment is not one bounded regular file.")
            }
            let bytes: Data
            do {
                bytes = try Data(contentsOf: attachmentURL)
            } catch {
                throw RoomConceptSetError.invalidArchive("An extracted attachment is unreadable.")
            }
            _ = try RoomConceptImageValidator.validateSanitizedImage(
                bytes,
                mediaType: attachment.mediaType,
                limits: limits.imageLimits
            )
            guard attachmentURLs.updateValue(attachmentURL, forKey: attachment.attachmentID) == nil else {
                throw RoomConceptSetError.invalidArchive("Attachment identifiers must be unique.")
            }
        }
        return RoomConceptSetArchiveImport(
            conceptSet: conceptSet,
            attachmentURLs: attachmentURLs
        )
    }

    private static func checkCancellation() throws {
        guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
    }
}
