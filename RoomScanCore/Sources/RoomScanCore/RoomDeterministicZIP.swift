import Foundation

/// One frozen source file destined for one app-owned ZIP entry.
public struct RoomZIPInput: Sendable, Equatable {
    public var sourceURL: URL
    public var entryPath: RoomExportEntryPath
    public var mediaType: String

    public init(sourceURL: URL, entryPath: RoomExportEntryPath, mediaType: String) {
        self.sourceURL = sourceURL
        self.entryPath = entryPath
        self.mediaType = mediaType
    }
}

public struct RoomZIPEntryDigest: Sendable, Equatable {
    public var entryPath: RoomExportEntryPath
    public var mediaType: String
    public var byteCount: UInt64
    public var crc32: UInt32
    public var sha256Hex: String

    public init(
        entryPath: RoomExportEntryPath,
        mediaType: String,
        byteCount: UInt64,
        crc32: UInt32,
        sha256Hex: String
    ) {
        self.entryPath = entryPath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.crc32 = crc32
        self.sha256Hex = sha256Hex
    }
}

public struct RoomZIPArchiveReceipt: Sendable, Equatable {
    public var profileVersion: String
    public var archiveSHA256: String
    public var archiveByteCount: UInt64
    public var entries: [RoomZIPEntryDigest]

    public init(
        profileVersion: String,
        archiveSHA256: String,
        archiveByteCount: UInt64,
        entries: [RoomZIPEntryDigest]
    ) {
        self.profileVersion = profileVersion
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
        self.entries = entries
    }
}

public enum RoomZIPWritingFaultPoint: Sendable, Equatable {
    case afterPreflight
    case beforePromotion
}

public protocol RoomZIPFaultInjecting: Sendable {
    func throwIfNeeded(at point: RoomZIPWritingFaultPoint) throws
}

public struct NoRoomZIPFaultInjector: RoomZIPFaultInjecting {
    public init() {}
    public func throwIfNeeded(at point: RoomZIPWritingFaultPoint) throws {}
}

/// A test-only observability seam for bounded reads. It observes byte sizes,
/// not content, and is never persisted.
public protocol RoomZIPReadObserving: Sendable {
    func didRead(byteCount: Int, from entryPath: RoomExportEntryPath)
}

/// A strict, classic ZIP32 STORE writer. It intentionally avoids compression,
/// data descriptors, directory entries, comments, extras, encryption, and
/// ZIP64 so inspection is simple and byte order is reproducible.
public enum RoomDeterministicZIP {
    public static let profileVersion = "roomscan-zip32-store-v1"
    public static let defaultChunkSize = 64 * 1024

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endSignature: UInt32 = 0x0605_4b50
    private static let utf8Flag: UInt16 = 0x0800
    private static let storeMethod: UInt16 = 0
    private static let versionNeeded: UInt16 = 20
    // DOS timestamp 1980-01-01 00:00:00. Date bits: (1980 - 1980) << 9 | 1 << 5 | 1.
    private static let fixedDOSDate: UInt16 = 0x0021
    private static let fixedDOSTime: UInt16 = 0

    public static func preflight(
        inputs: [RoomZIPInput],
        chunkSize: Int = defaultChunkSize,
        limits: RoomZIPLimits = RoomZIPLimits(),
        readObserver: (any RoomZIPReadObserving)? = nil
    ) async throws -> [RoomZIPEntryDigest] {
        try validateInputs(inputs, chunkSize: chunkSize, limits: limits)
        var result: [RoomZIPEntryDigest] = []
        var estimatedArchiveBytes: UInt64 = 22
        for input in inputs.sorted(by: { $0.entryPath < $1.entryPath }) {
            try Task.checkCancellation()
            let digest = try await digest(
                input,
                chunkSize: chunkSize,
                maximumEntryBytes: limits.maxEntryBytes,
                readObserver: readObserver
            )
            let nameLength = try checkedUInt64(input.entryPath.value.utf8.count)
            // 30 local header bytes plus 46 central header bytes, no extras;
            // the entry name appears once in each record.
            estimatedArchiveBytes = try checkedAdding(
                estimatedArchiveBytes,
                try checkedAdding(
                    digest.byteCount,
                    try checkedAdding(76, try checkedAdding(nameLength, nameLength))
                )
            )
            guard estimatedArchiveBytes <= limits.maxArchiveBytes,
                  estimatedArchiveBytes <= UInt64(UInt32.max)
            else {
                throw RoomExportError.archiveLimitExceeded
            }
            result.append(digest)
        }
        return result
    }

    public static func write(
        inputs: [RoomZIPInput],
        to destinationURL: URL,
        chunkSize: Int = defaultChunkSize,
        limits: RoomZIPLimits = RoomZIPLimits(),
        readObserver: (any RoomZIPReadObserving)? = nil,
        expectedDigests: [RoomZIPEntryDigest]? = nil,
        faultInjector: any RoomZIPFaultInjecting = NoRoomZIPFaultInjector()
    ) async throws -> RoomZIPArchiveReceipt {
        let fileManager = FileManager.default
        try validateArchiveDestination(destinationURL, fileManager: fileManager)
        let partialURL = destinationURL.appendingPathExtension("partial")
        guard !pathExists(partialURL, fileManager: fileManager) else {
            throw RoomExportError.destinationAlreadyExists(partialURL.path)
        }

        let digests: [RoomZIPEntryDigest]
        if let expectedDigests {
            try validateInputs(inputs, chunkSize: chunkSize, limits: limits)
            try validateExpectedDigests(expectedDigests, for: inputs)
            digests = expectedDigests.sorted { $0.entryPath < $1.entryPath }
        } else {
            digests = try await preflight(
                inputs: inputs,
                chunkSize: chunkSize,
                limits: limits,
                readObserver: readObserver
            )
        }
        try faultInjector.throwIfNeeded(at: .afterPreflight)
        try Task.checkCancellation()

        var createdPartial = false
        do {
            guard !pathExists(destinationURL, fileManager: fileManager),
                  !pathExists(partialURL, fileManager: fileManager)
            else {
                throw RoomExportError.destinationAlreadyExists(destinationURL.path)
            }
            guard !isSymbolicLink(destinationURL), !isSymbolicLink(partialURL) else {
                throw RoomExportError.unsafeDestination(destinationURL.path)
            }
            try Data().write(to: partialURL, options: [.withoutOverwriting])
            createdPartial = true
            let handle = try FileHandle(forWritingTo: partialURL)
            var centralEntries: [CentralEntry] = []
            var offset: UInt64 = 0

            do {
                for (input, expected) in zip(inputs.sorted(by: { $0.entryPath < $1.entryPath }), digests) {
                    try Task.checkCancellation()
                    let localOffset = offset
                    let nameData = Data(input.entryPath.value.utf8)
                    let localHeader = try localHeader(
                        nameData: nameData,
                        crc32: expected.crc32,
                        byteCount: expected.byteCount
                    )
                    try handle.write(contentsOf: localHeader)
                    offset = try checkedAdding(offset, UInt64(localHeader.count))

                    let actual = try await copyAndDigest(
                        sourceURL: input.sourceURL,
                        to: handle,
                        entryPath: input.entryPath,
                        mediaType: input.mediaType,
                        chunkSize: chunkSize,
                        maximumEntryBytes: limits.maxEntryBytes,
                        readObserver: readObserver
                    )
                    guard actual == expected else {
                        throw RoomExportError.sourceChangedAfterPreflight(input.entryPath.value)
                    }
                    offset = try checkedAdding(offset, actual.byteCount)
                    guard offset <= limits.maxArchiveBytes, offset <= UInt64(UInt32.max) else {
                        throw RoomExportError.archiveLimitExceeded
                    }
                    centralEntries.append(CentralEntry(digest: expected, localOffset: localOffset))
                }

                let centralOffset = offset
                for entry in centralEntries {
                    let record = try centralHeader(entry)
                    try handle.write(contentsOf: record)
                    offset = try checkedAdding(offset, UInt64(record.count))
                }
                let centralSize = offset - centralOffset
                let end = try endOfCentralDirectory(
                    entryCount: centralEntries.count,
                    centralDirectorySize: centralSize,
                    centralDirectoryOffset: centralOffset
                )
                try handle.write(contentsOf: end)
                offset = try checkedAdding(offset, UInt64(end.count))
                guard offset <= limits.maxArchiveBytes, offset <= UInt64(UInt32.max) else {
                    throw RoomExportError.archiveLimitExceeded
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            try inspect(url: partialURL, expectedEntries: digests)
            try faultInjector.throwIfNeeded(at: .beforePromotion)
            try Task.checkCancellation()
            guard !pathExists(destinationURL, fileManager: fileManager) else {
                throw RoomExportError.destinationAlreadyExists(destinationURL.path)
            }
            try fileManager.moveItem(at: partialURL, to: destinationURL)
            createdPartial = false
            let archiveByteCount = try fileByteCount(of: destinationURL, fileManager: fileManager)
            return RoomZIPArchiveReceipt(
                profileVersion: profileVersion,
                archiveSHA256: try RoomSHA256.hexDigest(ofFile: destinationURL),
                archiveByteCount: archiveByteCount,
                entries: digests
            )
        } catch is CancellationError {
            if createdPartial { try? removeOwnedPartial(partialURL, fileManager: fileManager) }
            throw RoomExportError.cancelled
        } catch {
            if createdPartial { try? removeOwnedPartial(partialURL, fileManager: fileManager) }
            if let exportError = error as? RoomExportError {
                throw exportError
            }
            throw RoomExportError.zipStructureInvalid("Unable to write a deterministic ZIP archive.")
        }
    }

    /// A narrow structural inspection of the classic profile. It does not rely
    /// on platform ZIP APIs and deliberately rejects ZIP64, extras, comments,
    /// compression, or data-descriptor flags.
    public static func inspect(
        url: URL,
        expectedEntries: [RoomZIPEntryDigest]? = nil
    ) throws {
        let fileManager = FileManager.default
        guard try isRegularFile(url, fileManager: fileManager), !isSymbolicLink(url) else {
            throw RoomExportError.zipStructureInvalid("Archive is not a regular file.")
        }
        let size = try fileByteCount(of: url, fileManager: fileManager)
        guard size >= 22 else {
            throw RoomExportError.zipStructureInvalid("Archive is too short.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: size - 22)
        let endData = try readExactly(handle, count: 22)
        guard readUInt32(endData, at: 0) == endSignature,
              readUInt16(endData, at: 4) == 0,
              readUInt16(endData, at: 6) == 0,
              readUInt16(endData, at: 20) == 0
        else {
            throw RoomExportError.zipStructureInvalid("Archive is not the fixed ZIP32 profile.")
        }
        let count = Int(readUInt16(endData, at: 8))
        guard count == Int(readUInt16(endData, at: 10)) else {
            throw RoomExportError.zipStructureInvalid("Multi-disk ZIP is not supported.")
        }
        let centralSize = UInt64(readUInt32(endData, at: 12))
        let centralOffset = UInt64(readUInt32(endData, at: 16))
        let expectedCentralEnd = try checkedAdding(centralOffset, centralSize)
        guard expectedCentralEnd == size - 22 else {
            throw RoomExportError.zipStructureInvalid("Central directory bounds are invalid.")
        }
        if let expectedEntries, expectedEntries.count != count {
            throw RoomExportError.zipStructureInvalid("Archive entry count changed.")
        }

        var offset = centralOffset
        var names: [String] = []
        var previousLocalEnd: UInt64 = 0
        for index in 0..<count {
            try handle.seek(toOffset: offset)
            let header = try readExactly(handle, count: 46)
            guard readUInt32(header, at: 0) == centralHeaderSignature,
                  readUInt16(header, at: 4) == 20,
                  readUInt16(header, at: 6) == versionNeeded,
                  readUInt16(header, at: 8) == utf8Flag,
                  readUInt16(header, at: 10) == storeMethod,
                  readUInt16(header, at: 12) == fixedDOSTime,
                  readUInt16(header, at: 14) == fixedDOSDate,
                  readUInt16(header, at: 30) == 0,
                  readUInt16(header, at: 32) == 0,
                  readUInt16(header, at: 34) == 0,
                  readUInt16(header, at: 36) == 0,
                  readUInt32(header, at: 38) == 0,
                  readUInt32(header, at: 42) != UInt32.max
            else {
                throw RoomExportError.zipStructureInvalid("Central entry violates the ZIP32 STORE profile.")
            }
            let nameLength = Int(readUInt16(header, at: 28))
            let nameData = try readExactly(handle, count: nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw RoomExportError.zipStructureInvalid("Entry name is not UTF-8.")
            }
            _ = try RoomExportEntryPath(name)
            names.append(name)
            let localOffset = UInt64(readUInt32(header, at: 42))
            let centralCRC = readUInt32(header, at: 16)
            let centralCompressedSize = UInt64(readUInt32(header, at: 20))
            let centralUncompressedSize = UInt64(readUInt32(header, at: 24))
            try handle.seek(toOffset: localOffset)
            let local = try readExactly(handle, count: 30)
            guard readUInt32(local, at: 0) == localHeaderSignature,
                  readUInt16(local, at: 4) == versionNeeded,
                  readUInt16(local, at: 6) == utf8Flag,
                  readUInt16(local, at: 8) == storeMethod,
                  readUInt16(local, at: 10) == fixedDOSTime,
                  readUInt16(local, at: 12) == fixedDOSDate,
                  readUInt32(local, at: 14) == centralCRC,
                  UInt64(readUInt32(local, at: 18)) == centralCompressedSize,
                  UInt64(readUInt32(local, at: 22)) == centralUncompressedSize,
                  readUInt16(local, at: 26) == UInt16(nameLength),
                  readUInt16(local, at: 28) == 0,
                  localOffset == previousLocalEnd
            else {
                throw RoomExportError.zipStructureInvalid("Local entry violates the ZIP32 STORE profile.")
            }
            let localName = try readExactly(handle, count: nameLength)
            guard localName == nameData else {
                throw RoomExportError.zipStructureInvalid("Local and central entry names differ.")
            }
            let localHeaderEnd = try checkedAdding(
                localOffset,
                UInt64(30 + nameLength)
            )
            let localEnd = try checkedAdding(localHeaderEnd, centralCompressedSize)
            guard localEnd <= centralOffset else {
                throw RoomExportError.zipStructureInvalid("Local entry exceeds the central directory boundary.")
            }
            previousLocalEnd = localEnd
            if let expectedEntries {
                let expected = expectedEntries[index]
                guard
                    expected.entryPath.value == name,
                    readUInt32(header, at: 16) == expected.crc32,
                    UInt64(readUInt32(header, at: 20)) == expected.byteCount,
                    UInt64(readUInt32(header, at: 24)) == expected.byteCount
                else {
                    throw RoomExportError.zipStructureInvalid("Archive entry differs from the preflight.")
                }
            }
            offset = try checkedAdding(offset, UInt64(46 + nameLength))
        }
        guard offset == expectedCentralEnd,
              previousLocalEnd == centralOffset,
              names == names.sorted()
        else {
            throw RoomExportError.zipStructureInvalid("Central directory is not stably ordered.")
        }
        let validatedNames = try names.map { try RoomExportEntryPath($0) }
        try RoomExportEntryPath.validateUnique(validatedNames)
    }

    /// Streams a fully inspected ZIP32 STORE archive into an already-owned
    /// empty directory. Unlike `inspect`, this recomputes each entry's CRC-32
    /// and SHA-256 while copying it, so recovery never trusts central-directory
    /// metadata alone. Entry paths are the strict app-owned export grammar;
    /// callers must map them to any package-specific names separately.
    public static func extractVerifiedStoreEntries(
        from archiveURL: URL,
        into destinationURL: URL,
        chunkSize: Int = defaultChunkSize,
        limits: RoomZIPLimits = RoomZIPLimits(),
        maximumByteCountByEntryPath: [String: UInt64] = [:],
        readObserver: (any RoomZIPReadObserving)? = nil
    ) async throws -> [RoomZIPEntryDigest] {
        guard chunkSize > 0 else {
            throw RoomExportError.zipStructureInvalid("ZIP chunk size must be positive.")
        }
        let fileManager = FileManager.default
        guard !isSymbolicLink(destinationURL), directoryExists(destinationURL, fileManager: fileManager) else {
            throw RoomExportError.unsafeDestination(destinationURL.path)
        }
        let existingChildren = try fileManager.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard existingChildren.isEmpty else {
            throw RoomExportError.unsafeDestination("ZIP extraction destination must be empty.")
        }
        let archiveSize = try fileByteCount(of: archiveURL, fileManager: fileManager)
        guard archiveSize <= limits.maxArchiveBytes else {
            throw RoomExportError.archiveLimitExceeded
        }
        let entries = try parsedStoreEntriesForExtraction(
            archiveURL,
            limits: limits,
            maximumByteCountByEntryPath: maximumByteCountByEntryPath,
            fileManager: fileManager
        )
        let source = try FileHandle(forReadingFrom: archiveURL)
        defer { try? source.close() }
        var digests: [RoomZIPEntryDigest] = []

        for entry in entries {
            try Task.checkCancellation()
            let destination = destinationURL.appendingPathComponent(entry.entryPath.value)
            try validateExtractionDestination(destination, root: destinationURL, fileManager: fileManager)
            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try validateExtractionDestination(destination, root: destinationURL, fileManager: fileManager)
            guard !pathExists(destination, fileManager: fileManager) else {
                throw RoomExportError.destinationAlreadyExists(destination.path)
            }
            try Data().write(to: destination, options: [.withoutOverwriting])
            let output = try FileHandle(forWritingTo: destination)
            var removeDestination = true
            do {
                try source.seek(toOffset: entry.dataOffset)
                var remaining = entry.byteCount
                var crc = RoomCRC32.Stream()
                var hash = RoomSHA256.Stream()
                while remaining > 0 {
                    try Task.checkCancellation()
                    let requestedCount = min(UInt64(chunkSize), remaining)
                    guard requestedCount <= UInt64(Int.max),
                          let chunk = try source.read(upToCount: Int(requestedCount)),
                          !chunk.isEmpty
                    else {
                        throw RoomExportError.zipStructureInvalid("Archive ended during an entry payload.")
                    }
                    guard UInt64(chunk.count) <= remaining else {
                        throw RoomExportError.zipStructureInvalid("Archive entry exceeds its declared size.")
                    }
                    try output.write(contentsOf: chunk)
                    crc.update(chunk)
                    hash.update(chunk)
                    readObserver?.didRead(byteCount: chunk.count, from: entry.entryPath)
                    remaining -= UInt64(chunk.count)
                }
                try output.synchronize()
                try output.close()
                let digest = RoomZIPEntryDigest(
                    entryPath: entry.entryPath,
                    mediaType: entry.entryPath.value == "backup-manifest.json"
                        ? "application/json"
                        : "application/octet-stream",
                    byteCount: entry.byteCount,
                    crc32: crc.finalizedValue,
                    sha256Hex: hash.finalizedHexDigest()
                )
                guard digest.crc32 == entry.crc32 else {
                    throw RoomExportError.zipStructureInvalid("Archive entry CRC does not match its local and central records.")
                }
                removeDestination = false
                digests.append(digest)
            } catch {
                try? output.close()
                if removeDestination, pathExists(destination, fileManager: fileManager), !isSymbolicLink(destination) {
                    try? fileManager.removeItem(at: destination)
                }
                throw error
            }
        }
        return digests
    }

    private struct ParsedStoreEntry {
        let entryPath: RoomExportEntryPath
        let crc32: UInt32
        let byteCount: UInt64
        let dataOffset: UInt64
    }

    /// `inspect` is deliberately called first so this focused parser only
    /// extracts offsets from a canonical, already-validated STORE profile.
    private static func parsedStoreEntriesForExtraction(
        _ archiveURL: URL,
        limits: RoomZIPLimits,
        maximumByteCountByEntryPath: [String: UInt64],
        fileManager: FileManager
    ) throws -> [ParsedStoreEntry] {
        try inspect(url: archiveURL)
        let size = try fileByteCount(of: archiveURL, fileManager: fileManager)
        guard size >= 22 else {
            throw RoomExportError.zipStructureInvalid("Archive is too short.")
        }
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: size - 22)
        let endData = try readExactly(handle, count: 22)
        let count = Int(readUInt16(endData, at: 8))
        guard count <= limits.maxEntries else {
            throw RoomExportError.entryLimitExceeded
        }
        let centralOffset = UInt64(readUInt32(endData, at: 16))
        var offset = centralOffset
        var entries: [ParsedStoreEntry] = []
        for _ in 0..<count {
            try handle.seek(toOffset: offset)
            let header = try readExactly(handle, count: 46)
            let nameLength = Int(readUInt16(header, at: 28))
            let nameData = try readExactly(handle, count: nameLength)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw RoomExportError.zipStructureInvalid("Entry name is not UTF-8.")
            }
            let entryPath = try RoomExportEntryPath(name)
            let byteCount = UInt64(readUInt32(header, at: 24))
            guard byteCount <= limits.maxEntryBytes else {
                throw RoomExportError.sizeLimitExceeded(name)
            }
            if let specialMaximum = maximumByteCountByEntryPath[name],
               byteCount > specialMaximum {
                throw RoomExportError.sizeLimitExceeded(name)
            }
            let localOffset = UInt64(readUInt32(header, at: 42))
            let dataOffset = try checkedAdding(localOffset, UInt64(30 + nameLength))
            entries.append(ParsedStoreEntry(
                entryPath: entryPath,
                crc32: readUInt32(header, at: 16),
                byteCount: byteCount,
                dataOffset: dataOffset
            ))
            offset = try checkedAdding(offset, UInt64(46 + nameLength))
        }
        return entries
    }

    private static func validateExtractionDestination(
        _ destination: URL,
        root: URL,
        fileManager: FileManager
    ) throws {
        let rootComponents = root.standardizedFileURL.pathComponents
        let destinationComponents = destination.standardizedFileURL.pathComponents
        guard destinationComponents.count >= rootComponents.count,
              zip(rootComponents, destinationComponents).allSatisfy({ $0 == $1 })
        else {
            throw RoomExportError.unsafeDestination(destination.path)
        }
        var current = root
        for component in destinationComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component)
            if isSymbolicLink(current) {
                throw RoomExportError.unsafeDestination(destination.path)
            }
        }
        _ = fileManager
    }

    private struct CentralEntry {
        var digest: RoomZIPEntryDigest
        var localOffset: UInt64
    }

    private static func validateInputs(
        _ inputs: [RoomZIPInput],
        chunkSize: Int,
        limits: RoomZIPLimits
    ) throws {
        guard chunkSize > 0 else {
            throw RoomExportError.zipStructureInvalid("ZIP chunk size must be positive.")
        }
        guard
            inputs.count <= limits.maxEntries,
            inputs.count <= RoomExportLimits.maximumEntries
        else {
            throw RoomExportError.entryLimitExceeded
        }
        try RoomExportEntryPath.validateUnique(inputs.map(\.entryPath))
        for input in inputs {
            guard !input.mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RoomExportError.zipStructureInvalid("An export media type is missing.")
            }
            guard !isSymbolicLink(input.sourceURL),
                  try isRegularFile(input.sourceURL, fileManager: .default)
            else {
                throw RoomExportError.unsafeDestination(input.sourceURL.path)
            }
        }
    }

    private static func validateExpectedDigests(
        _ expected: [RoomZIPEntryDigest],
        for inputs: [RoomZIPInput]
    ) throws {
        guard expected.count == inputs.count else {
            throw RoomExportError.zipStructureInvalid("Preflight count does not match ZIP inputs.")
        }
        let inputByPath = Dictionary(uniqueKeysWithValues: inputs.map { ($0.entryPath, $0) })
        for digest in expected {
            guard let input = inputByPath[digest.entryPath], input.mediaType == digest.mediaType else {
                throw RoomExportError.zipStructureInvalid("Preflight entry does not match ZIP input.")
            }
        }
    }

    private static func digest(
        _ input: RoomZIPInput,
        chunkSize: Int,
        maximumEntryBytes: UInt64,
        readObserver: (any RoomZIPReadObserving)?
    ) async throws -> RoomZIPEntryDigest {
        let handle = try FileHandle(forReadingFrom: input.sourceURL)
        defer { try? handle.close() }
        var crc = RoomCRC32.Stream()
        var hash = RoomSHA256.Stream()
        var count: UInt64 = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            let next = try checkedAdding(count, UInt64(chunk.count))
            guard next <= maximumEntryBytes else {
                throw RoomExportError.sizeLimitExceeded(input.entryPath.value)
            }
            crc.update(chunk)
            hash.update(chunk)
            readObserver?.didRead(byteCount: chunk.count, from: input.entryPath)
            count = next
        }
        return RoomZIPEntryDigest(
            entryPath: input.entryPath,
            mediaType: input.mediaType,
            byteCount: count,
            crc32: crc.finalizedValue,
            sha256Hex: hash.finalizedHexDigest()
        )
    }

    private static func copyAndDigest(
        sourceURL: URL,
        to handle: FileHandle,
        entryPath: RoomExportEntryPath,
        mediaType: String,
        chunkSize: Int,
        maximumEntryBytes: UInt64,
        readObserver: (any RoomZIPReadObserving)?
    ) async throws -> RoomZIPEntryDigest {
        guard !isSymbolicLink(sourceURL),
              try isRegularFile(sourceURL, fileManager: .default)
        else {
            throw RoomExportError.sourceChangedAfterPreflight(entryPath.value)
        }
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        var crc = RoomCRC32.Stream()
        var hash = RoomSHA256.Stream()
        var count: UInt64 = 0
        while let chunk = try source.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            let next = try checkedAdding(count, UInt64(chunk.count))
            guard next <= maximumEntryBytes else {
                throw RoomExportError.sizeLimitExceeded(entryPath.value)
            }
            try handle.write(contentsOf: chunk)
            crc.update(chunk)
            hash.update(chunk)
            readObserver?.didRead(byteCount: chunk.count, from: entryPath)
            count = next
        }
        return RoomZIPEntryDigest(
            entryPath: entryPath,
            mediaType: mediaType,
            byteCount: count,
            crc32: crc.finalizedValue,
            sha256Hex: hash.finalizedHexDigest()
        )
    }

    private static func localHeader(
        nameData: Data,
        crc32: UInt32,
        byteCount: UInt64
    ) throws -> Data {
        guard byteCount <= UInt64(UInt32.max), nameData.count <= Int(UInt16.max) else {
            throw RoomExportError.archiveLimitExceeded
        }
        var data = Data()
        data.appendLE(localHeaderSignature)
        data.appendLE(versionNeeded)
        data.appendLE(utf8Flag)
        data.appendLE(storeMethod)
        data.appendLE(fixedDOSTime)
        data.appendLE(fixedDOSDate)
        data.appendLE(crc32)
        data.appendLE(UInt32(byteCount))
        data.appendLE(UInt32(byteCount))
        data.appendLE(UInt16(nameData.count))
        data.appendLE(UInt16(0))
        data.append(nameData)
        return data
    }

    private static func centralHeader(_ entry: CentralEntry) throws -> Data {
        let nameData = Data(entry.digest.entryPath.value.utf8)
        guard
            entry.digest.byteCount <= UInt64(UInt32.max),
            entry.localOffset <= UInt64(UInt32.max),
            nameData.count <= Int(UInt16.max)
        else {
            throw RoomExportError.archiveLimitExceeded
        }
        var data = Data()
        data.appendLE(centralHeaderSignature)
        data.appendLE(UInt16(20)) // made by: DOS/FAT, version 2.0
        data.appendLE(versionNeeded)
        data.appendLE(utf8Flag)
        data.appendLE(storeMethod)
        data.appendLE(fixedDOSTime)
        data.appendLE(fixedDOSDate)
        data.appendLE(entry.digest.crc32)
        data.appendLE(UInt32(entry.digest.byteCount))
        data.appendLE(UInt32(entry.digest.byteCount))
        data.appendLE(UInt16(nameData.count))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(entry.localOffset))
        data.append(nameData)
        return data
    }

    private static func endOfCentralDirectory(
        entryCount: Int,
        centralDirectorySize: UInt64,
        centralDirectoryOffset: UInt64
    ) throws -> Data {
        guard
            entryCount <= Int(UInt16.max),
            centralDirectorySize <= UInt64(UInt32.max),
            centralDirectoryOffset <= UInt64(UInt32.max)
        else {
            throw RoomExportError.archiveLimitExceeded
        }
        var data = Data()
        data.appendLE(endSignature)
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(entryCount))
        data.appendLE(UInt16(entryCount))
        data.appendLE(UInt32(centralDirectorySize))
        data.appendLE(UInt32(centralDirectoryOffset))
        data.appendLE(UInt16(0))
        return data
    }

    private static func validateArchiveDestination(_ destination: URL, fileManager: FileManager) throws {
        var parentIsDirectory = ObjCBool(false)
        guard destination.isFileURL,
              !destination.lastPathComponent.isEmpty,
              !isSymbolicLink(destination),
              !isSymbolicLink(destination.deletingLastPathComponent()),
              !pathExists(destination, fileManager: fileManager),
              fileManager.fileExists(
                atPath: destination.deletingLastPathComponent().path,
                isDirectory: &parentIsDirectory
              ),
              parentIsDirectory.boolValue
        else {
            throw RoomExportError.unsafeDestination(destination.path)
        }
    }

    private static func removeOwnedPartial(_ url: URL, fileManager: FileManager) throws {
        guard url.pathExtension == "partial", !isSymbolicLink(url), pathExists(url, fileManager: fileManager) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private static func pathExists(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !isSymbolicLink(url)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func isRegularFile(_ url: URL, fileManager: FileManager) throws -> Bool {
        guard !isSymbolicLink(url) else { return false }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private static func fileByteCount(of url: URL, fileManager: FileManager) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
            throw RoomExportError.zipStructureInvalid("File size is unavailable.")
        }
        return UInt64(size.int64Value)
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw RoomExportError.zipStructureInvalid("Archive ended unexpectedly.")
        }
        return data
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func checkedUInt64(_ value: Int) throws -> UInt64 {
        guard value >= 0 else { throw RoomExportError.archiveLimitExceeded }
        return UInt64(value)
    }

    private static func checkedAdding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw RoomExportError.archiveLimitExceeded }
        return value
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
