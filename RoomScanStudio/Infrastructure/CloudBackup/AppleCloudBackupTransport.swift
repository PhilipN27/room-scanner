import CloudKit
import Foundation
import RoomScanCore

/// The only Phase-6 production file that imports CloudKit. It uses an exact
/// operator-supplied container identifier, a private custom zone, and current
/// bulk Result-returning APIs. It is never invoked at app launch.
@MainActor
final class AppleCloudBackupTransport: RoomCloudBackupTransport {
    private static let zoneName = "RoomScanStudioBackupsV1"
    private static let recordType = "RSSProjectBackupV1"
    private static let descriptorDesiredKeys: [CKRecord.FieldKey] = [
        "schemaVersion", "snapshotID", "projectID", "headRevisionID",
        "projectSchemaVersion", "displayName", "sourceUpdatedAt",
        "revisionCount", "fileCount", "uncompressedByteCount",
        "manifestSHA256", "archiveSHA256", "archiveByteCount",
        "archiveFormat", "complete",
    ]

    func checkAccount(containerIdentifier: String) async throws -> RoomCloudBackupAccountStatus {
        do {
            switch try await container(named: containerIdentifier).accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine: return .unavailable("The iCloud account status could not be determined.")
            @unknown default: return .unavailable("The iCloud account returned an unsupported status.")
            }
        } catch { throw mapped(error) }
    }

    func listBackups(containerIdentifier: String) async throws -> RoomCloudBackupListResult {
        let database = database(named: containerIdentifier)
        let zoneID = backupZoneID
        do {
            let zoneResults = try await database.recordZones(for: [zoneID])
            guard let result = zoneResults[zoneID] else { return .zoneMissing }
            switch result {
            case .success: break
            case let .failure(error):
                if isZoneMissing(error) { return .zoneMissing }
                throw mapped(error)
            }
        } catch let error as RoomCloudBackupTransportError {
            throw error
        } catch {
            if isZoneMissing(error) { return .zoneMissing }
            throw mapped(error)
        }

        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        do {
            var response = try await database.records(
                matching: query,
                inZoneWith: zoneID,
                desiredKeys: Self.descriptorDesiredKeys,
                resultsLimit: 100
            )
            var accumulator = RoomCloudBackupListingAccumulator()
            var page = try decodedListingPage(from: response.matchResults)
            accumulator.append(
                records: page.records,
                skippedMalformedRecordCount: page.skippedMalformedRecordCount,
                hasMorePages: response.queryCursor != nil
            )
            // The accumulator marks truncation as soon as a page fills either
            // bounded representation. This intentionally avoids fetching a
            // third 100-record page after retaining 200 valid records.
            while accumulator.shouldRequestNextPage, let cursor = response.queryCursor {
                response = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: Self.descriptorDesiredKeys,
                    resultsLimit: 100
                )
                page = try decodedListingPage(from: response.matchResults)
                accumulator.append(
                    records: page.records,
                    skippedMalformedRecordCount: page.skippedMalformedRecordCount,
                    hasMorePages: response.queryCursor != nil
                )
            }
            let listing = accumulator.listing
            return .backups(RoomCloudBackupListedRecords(
                records: listing.records.sorted { $0.descriptor.sourceUpdatedAt > $1.descriptor.sourceUpdatedAt },
                isTruncated: listing.isTruncated,
                skippedMalformedRecordCount: listing.skippedMalformedRecordCount
            ))
        } catch let error as RoomCloudBackupTransportError {
            throw error
        } catch { throw mapped(error) }
    }

    func ensureBackupZone(containerIdentifier: String) async throws {
        let database = database(named: containerIdentifier)
        let zoneID = backupZoneID
        do {
            let results = try await database.recordZones(for: [zoneID])
            if case .success? = results[zoneID] { return }
            if let result = results[zoneID], case let .failure(error) = result,
               !isZoneMissing(error) {
                throw mapped(error)
            }
            let zone = CKRecordZone(zoneID: zoneID)
            let modified = try await database.modifyRecordZones(saving: [zone], deleting: [])
            guard let outcome = modified.saveResults[zoneID] else {
                throw RoomCloudBackupTransportError.transportFailure("CloudKit did not return a zone save result.")
            }
            switch outcome {
            case .success: return
            case let .failure(error): throw mapped(error)
            }
        } catch let error as RoomCloudBackupTransportError {
            throw error
        } catch { throw mapped(error) }
    }

    func save(snapshot: RoomBackupSnapshot, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord {
        try RoomProjectBackupArchive.validate(descriptor: snapshot.descriptor)
        let database = database(named: containerIdentifier)
        let recordID = CKRecord.ID(recordName: snapshot.descriptor.recordName, zoneID: backupZoneID)
        if let existing = try await fetchRecord(id: recordID, database: database) {
            let decoded = try decode(record: existing)
            guard decoded.descriptor.archiveSHA256 == snapshot.descriptor.archiveSHA256,
                  decoded.descriptor.manifestSHA256 == snapshot.descriptor.manifestSHA256,
                  decoded.descriptor.archiveByteCount == snapshot.descriptor.archiveByteCount
            else { throw RoomCloudBackupTransportError.recordConflict }
            return decoded
        }

        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        write(snapshot.descriptor, to: record)
        record["packageArchive"] = CKAsset(fileURL: snapshot.archiveURL)
        do {
            let result = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let outcome = result.saveResults[recordID] else {
                throw RoomCloudBackupTransportError.transportFailure("CloudKit did not return a record save result.")
            }
            switch outcome {
            case let .success(saved): return try decode(record: saved)
            case let .failure(error):
                if let existing = try await fetchRecord(id: recordID, database: database) {
                    let decoded = try decode(record: existing)
                    if decoded.descriptor.archiveSHA256 == snapshot.descriptor.archiveSHA256,
                       decoded.descriptor.manifestSHA256 == snapshot.descriptor.manifestSHA256 {
                        return decoded
                    }
                    throw RoomCloudBackupTransportError.recordConflict
                }
                throw mapped(error)
            }
        } catch let error as RoomCloudBackupTransportError {
            throw error
        } catch { throw mapped(error) }
    }

    func lookup(snapshotID: String, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord? {
        guard snapshotID.count == 64 else { throw RoomCloudBackupTransportError.malformedRemoteRecord }
        let recordID = CKRecord.ID(recordName: "rssb1-\(snapshotID)", zoneID: backupZoneID)
        if let record = try await fetchRecord(id: recordID, database: database(named: containerIdentifier)) {
            return try decode(record: record)
        }
        return nil
    }

    func fetchArchive(record: RoomCloudBackupRemoteRecord, containerIdentifier: String, into destinationURL: URL) async throws {
        let recordID = CKRecord.ID(recordName: record.descriptor.recordName, zoneID: backupZoneID)
        guard let cloudRecord = try await fetchRecord(
            id: recordID,
            database: database(named: containerIdentifier),
            desiredKeys: Self.descriptorDesiredKeys + ["packageArchive"]
        ) else {
            throw RoomCloudBackupTransportError.malformedRemoteRecord
        }
        let decoded = try decode(record: cloudRecord)
        guard decoded.descriptor == record.descriptor,
              let asset = cloudRecord["packageArchive"] as? CKAsset,
              let sourceURL = asset.fileURL
        else { throw RoomCloudBackupTransportError.malformedRemoteRecord }
        let manager = FileManager.default
        let sourceAttributes: [FileAttributeKey: Any]
        do {
            sourceAttributes = try manager.attributesOfItem(atPath: sourceURL.path)
        } catch {
            throw RoomCloudBackupTransportError.transportFailure("CloudKit supplied an unreadable archive asset.")
        }
        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular,
              (try? manager.destinationOfSymbolicLink(atPath: sourceURL.path)) == nil,
              let sourceSize = sourceAttributes[.size] as? NSNumber,
              sourceSize.int64Value >= 0,
              UInt64(sourceSize.int64Value) == record.descriptor.archiveByteCount,
              UInt64(sourceSize.int64Value) <= RoomBackupLimits.maximumArchiveBytes
        else {
            throw RoomCloudBackupTransportError.malformedRemoteRecord
        }
        guard !manager.fileExists(atPath: destinationURL.path),
              (try? manager.destinationOfSymbolicLink(atPath: destinationURL.path)) == nil
        else {
            throw RoomCloudBackupTransportError.transportFailure("The owned backup download destination is not empty.")
        }
        do {
            try streamOwnedAsset(
                from: sourceURL,
                to: destinationURL,
                expectedByteCount: record.descriptor.archiveByteCount
            )
        } catch let error as RoomCloudBackupTransportError {
            throw error
        } catch {
            throw RoomCloudBackupTransportError.transportFailure("CloudKit supplied an unreadable archive asset.")
        }
    }

    private var backupZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }
    private func container(named identifier: String) -> CKContainer { CKContainer(identifier: identifier) }
    private func database(named identifier: String) -> CKDatabase { container(named: identifier).privateCloudDatabase }

    private func fetchRecord(
        id: CKRecord.ID,
        database: CKDatabase
    ) async throws -> CKRecord? {
        try await fetchRecord(
            id: id,
            database: database,
            desiredKeys: Self.descriptorDesiredKeys
        )
    }

    private func fetchRecord(
        id: CKRecord.ID,
        database: CKDatabase,
        desiredKeys: [CKRecord.FieldKey]?
    ) async throws -> CKRecord? {
        do {
            let results = try await database.records(for: [id], desiredKeys: desiredKeys)
            guard let outcome = results[id] else { return nil }
            switch outcome {
            case let .success(record): return record
            case let .failure(error):
                if isRecordMissing(error) { return nil }
                throw mapped(error)
            }
        } catch let error as RoomCloudBackupTransportError { throw error }
        catch {
            if isRecordMissing(error) { return nil }
            throw mapped(error)
        }
    }

    private struct DecodedListingPage {
        let records: [RoomCloudBackupRemoteRecord]
        let skippedMalformedRecordCount: Int
    }

    private func decodedListingPage(
        from results: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) throws -> DecodedListingPage {
        var records: [RoomCloudBackupRemoteRecord] = []
        var skippedMalformedRecordCount = 0
        for (_, result) in results {
            switch result {
            case let .success(record):
                do {
                    records.append(try decode(record: record))
                } catch RoomCloudBackupTransportError.malformedRemoteRecord {
                    // A successful CloudKit fetch can still carry an invalid
                    // descriptor. It is not displayed or recoverable, but it
                    // must not hide unrelated valid immutable backups.
                    skippedMalformedRecordCount += 1
                }
            case let .failure(error): throw mapped(error)
            }
        }
        return DecodedListingPage(
            records: records,
            skippedMalformedRecordCount: skippedMalformedRecordCount
        )
    }

    private func write(_ descriptor: RoomCloudBackupDescriptor, to record: CKRecord) {
        record["schemaVersion"] = descriptor.schemaVersion as NSString
        record["snapshotID"] = descriptor.snapshotID as NSString
        record["projectID"] = descriptor.projectID as NSString
        record["headRevisionID"] = descriptor.headRevisionID as NSString
        record["projectSchemaVersion"] = descriptor.projectSchemaVersion as NSString
        record["displayName"] = descriptor.displayName as NSString
        record["sourceUpdatedAt"] = descriptor.sourceUpdatedAt as NSDate
        record["revisionCount"] = descriptor.revisionCount as NSNumber
        record["fileCount"] = descriptor.fileCount as NSNumber
        record["uncompressedByteCount"] = NSNumber(value: descriptor.uncompressedByteCount)
        record["manifestSHA256"] = descriptor.manifestSHA256 as NSString
        record["archiveSHA256"] = descriptor.archiveSHA256 as NSString
        record["archiveByteCount"] = NSNumber(value: descriptor.archiveByteCount)
        record["archiveFormat"] = descriptor.archiveFormat as NSString
        record["complete"] = NSNumber(value: descriptor.complete)
    }

    private func decode(record: CKRecord) throws -> RoomCloudBackupRemoteRecord {
        guard let schemaVersion = record["schemaVersion"] as? String,
              let snapshotID = record["snapshotID"] as? String,
              let projectID = record["projectID"] as? String,
              let headRevisionID = record["headRevisionID"] as? String,
              let projectSchemaVersion = record["projectSchemaVersion"] as? String,
              let displayName = record["displayName"] as? String,
              let sourceUpdatedAt = record["sourceUpdatedAt"] as? Date,
              let revisionCount = (record["revisionCount"] as? NSNumber)?.intValue,
              let fileCount = (record["fileCount"] as? NSNumber)?.intValue,
              let uncompressedByteCount = (record["uncompressedByteCount"] as? NSNumber)?.uint64Value,
              let manifestSHA256 = record["manifestSHA256"] as? String,
              let archiveSHA256 = record["archiveSHA256"] as? String,
              let archiveByteCount = (record["archiveByteCount"] as? NSNumber)?.uint64Value,
              let archiveFormat = record["archiveFormat"] as? String,
              let complete = (record["complete"] as? NSNumber)?.boolValue
        else { throw RoomCloudBackupTransportError.malformedRemoteRecord }
        let descriptor = RoomCloudBackupDescriptor(
            schemaVersion: schemaVersion, snapshotID: snapshotID, projectID: projectID,
            headRevisionID: headRevisionID, projectSchemaVersion: projectSchemaVersion,
            displayName: displayName, sourceUpdatedAt: sourceUpdatedAt,
            revisionCount: revisionCount, fileCount: fileCount,
            uncompressedByteCount: uncompressedByteCount, manifestSHA256: manifestSHA256,
            archiveSHA256: archiveSHA256, archiveByteCount: archiveByteCount,
            archiveFormat: archiveFormat, complete: complete
        )
        do { try RoomProjectBackupArchive.validate(descriptor: descriptor) }
        catch { throw RoomCloudBackupTransportError.malformedRemoteRecord }
        return RoomCloudBackupRemoteRecord(descriptor: descriptor)
    }

    /// CKAsset URLs are external temporary files. Stream a bounded deep copy
    /// into the already-owned nonexisting lease destination before Core opens
    /// it, rather than allowing an oversized asset to consume scratch space.
    private func streamOwnedAsset(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedByteCount: UInt64
    ) throws {
        guard expectedByteCount <= RoomBackupLimits.maximumArchiveBytes else {
            throw RoomCloudBackupTransportError.malformedRemoteRecord
        }
        try Data().write(to: destinationURL, options: [.withoutOverwriting])
        var removeDestination = true
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination: FileHandle
        do {
            destination = try FileHandle(forWritingTo: destinationURL)
        } catch {
            try? source.close()
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        defer {
            try? source.close()
            try? destination.close()
            if removeDestination {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
        var copied: UInt64 = 0
        while copied < expectedByteCount {
            let requested = min(UInt64(64 * 1_024), expectedByteCount - copied)
            guard let chunk = try source.read(upToCount: Int(requested)),
                  !chunk.isEmpty,
                  UInt64(chunk.count) <= expectedByteCount - copied
            else {
                throw RoomCloudBackupTransportError.malformedRemoteRecord
            }
            try destination.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
        }
        // Probe only one byte after the declared bound. A swapped or growing
        // CKAsset must fail closed without allocating an unbounded tail.
        let trailing = try source.read(upToCount: 1) ?? Data()
        guard trailing.isEmpty else {
            throw RoomCloudBackupTransportError.malformedRemoteRecord
        }
        try destination.synchronize()
        removeDestination = false
    }

    private func isZoneMissing(_ error: Error) -> Bool { (error as? CKError)?.code == .zoneNotFound }
    private func isRecordMissing(_ error: Error) -> Bool {
        let code = (error as? CKError)?.code
        return code == .unknownItem || code == .zoneNotFound
    }
    private func mapped(_ error: Error) -> RoomCloudBackupTransportError {
        guard let cloudError = error as? CKError else {
            return .transportFailure("CloudKit returned an unclassified error.")
        }
        let retryAfter = min(60, max(0, Int((cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue ?? 0)))
        switch cloudError.code {
        case .serviceUnavailable: return .serviceUnavailable(retryAfterSeconds: retryAfter)
        case .networkUnavailable, .networkFailure: return .networkUnavailable(retryAfterSeconds: retryAfter)
        case .requestRateLimited: return .rateLimited(retryAfterSeconds: retryAfter)
        case .limitExceeded: return .limitExceeded
        case .notAuthenticated, .permissionFailure: return .accountUnavailable
        case .serverRecordChanged: return .recordConflict
        default: return .transportFailure("CloudKit \(cloudError.code.rawValue) blocked the explicit operation.")
        }
    }
}
