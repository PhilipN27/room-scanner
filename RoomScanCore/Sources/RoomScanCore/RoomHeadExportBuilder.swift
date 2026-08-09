import Foundation

/// Converts a previously materialized head-revision snapshot plus required
/// derived artifacts into the inspectable manifest and deterministic ZIP.
/// The store lock is intentionally not held here: `materialization` already
/// contains independent byte copies outside the authoritative package root.
public enum RoomHeadExportBuilder {
    public static func build(
        materialization: RoomHeadExportMaterialization,
        derivedArtifacts: [RoomDerivedExportArtifact],
        archiveURL: URL
    ) async throws -> RoomHeadExportResult {
        let workspace = materialization.workspaceURL.standardizedFileURL
        try validateWorkspace(workspace)
        var sourceEntries = try materializedInputs(materialization, workspace: workspace)
        let derivedInputs = try derivedInputs(derivedArtifacts, workspace: workspace)
        sourceEntries.append(contentsOf: derivedInputs.inputs)
        try RoomExportEntryPath.validateUnique(sourceEntries.map(\.entryPath))
        guard !sourceEntries.contains(where: { $0.entryPath.value == "manifest.json" }) else {
            throw RoomExportError.duplicateEntryPath("manifest.json")
        }
        _ = try RoomExportLimits.finalArchiveEntryCount(
            forMaterializedEntries: materialization.entries.count,
            derivedEntryCount: derivedInputs.inputs.count
        )

        guard derivedInputs.outputs.contains(.floorPlanPNG),
              derivedInputs.outputs.contains(.pdfSummary)
        else {
            throw RoomExportError.missingRequiredArtifact("floor-plan PNG and PDF summary")
        }

        let frozenDigests = try await RoomDeterministicZIP.preflight(inputs: sourceEntries)
        let manifestEntries = frozenDigests.map {
            RoomExportManifestEntry(
                path: $0.entryPath.value,
                mediaType: $0.mediaType,
                byteCount: $0.byteCount,
                sha256Hex: $0.sha256Hex,
                output: output(for: $0.entryPath, materialization: materialization, derivedArtifacts: derivedArtifacts)
            )
        }
        let outputs = try completedOutputRecords(
            materialization.requestedOutputs,
            derivedOutputs: derivedInputs.outputs
        )
        let manifest = RoomExportManifest(
            projectID: materialization.descriptor.projectID,
            headRevisionID: materialization.descriptor.headRevisionID,
            zipProfileVersion: RoomDeterministicZIP.profileVersion,
            entries: manifestEntries.sorted { $0.path < $1.path },
            requestedOutputs: outputs
        )
        let manifestURL = workspace.appendingPathComponent("manifest.json")
        try writeManifest(manifest, to: manifestURL, workspace: workspace)

        let manifestInput = RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath("manifest.json"),
            mediaType: "application/json"
        )
        var finalInputs = sourceEntries
        finalInputs.append(manifestInput)
        let manifestDigest = try await RoomDeterministicZIP.preflight(inputs: [manifestInput])
        let finalDigests = (frozenDigests + manifestDigest).sorted { $0.entryPath < $1.entryPath }
        let zipReceipt = try await RoomDeterministicZIP.write(
            inputs: finalInputs,
            to: archiveURL,
            expectedDigests: finalDigests
        )
        let receipt = RoomExportReceipt(
            projectID: materialization.descriptor.projectID,
            headRevisionID: materialization.descriptor.headRevisionID,
            archiveSHA256: zipReceipt.archiveSHA256,
            archiveByteCount: zipReceipt.archiveByteCount,
            manifestSHA256: manifestDigest[0].sha256Hex,
            profileVersion: zipReceipt.profileVersion
        )
        return RoomHeadExportResult(
            archiveURL: archiveURL,
            manifest: manifest,
            receipt: receipt
        )
    }

    private static func materializedInputs(
        _ materialization: RoomHeadExportMaterialization,
        workspace: URL
    ) throws -> [RoomZIPInput] {
        try materialization.entries.map { entry in
            let sourceURL = workspace.appendingPathComponent(entry.workspaceRelativePath.value)
            try validateContainedRegularFile(sourceURL, workspace: workspace)
            return RoomZIPInput(
                sourceURL: sourceURL,
                entryPath: entry.entryPath,
                mediaType: entry.mediaType
            )
        }
    }

    private static func derivedInputs(
        _ artifacts: [RoomDerivedExportArtifact],
        workspace: URL
    ) throws -> (inputs: [RoomZIPInput], outputs: Set<RoomExportOutput>) {
        var seenOutputs = Set<RoomExportOutput>()
        var inputs: [RoomZIPInput] = []
        var aggregateByteCount: UInt64 = 0
        for artifact in artifacts {
            guard seenOutputs.insert(artifact.output).inserted else {
                throw RoomExportError.duplicateEntryPath(artifact.entryPath.value)
            }
            try validateContainedRegularFile(artifact.sourceURL, workspace: workspace)
            let byteCount = try fileByteCount(of: artifact.sourceURL)
            guard byteCount <= RoomExportLimits.maximumDerivedBytes else {
                throw RoomExportError.sizeLimitExceeded(artifact.entryPath.value)
            }
            let (nextAggregate, overflow) = aggregateByteCount.addingReportingOverflow(byteCount)
            guard !overflow, nextAggregate <= RoomExportLimits.maximumDerivedBytes else {
                throw RoomExportError.archiveLimitExceeded
            }
            aggregateByteCount = nextAggregate
            switch artifact.output {
            case .floorPlanPNG:
                try validatePNG(artifact.sourceURL, byteCount: byteCount)
            case .pdfSummary:
                guard
                    byteCount <= RoomExportLimits.maximumPDFBytes,
                    let pageCount = artifact.pageCount,
                    pageCount > 0,
                    pageCount <= RoomExportLimits.maximumPDFPages,
                    try hasPDFHeader(artifact.sourceURL)
                else {
                    throw RoomExportError.sizeLimitExceeded(artifact.entryPath.value)
                }
            default:
                throw RoomExportError.missingRequiredArtifact("Unsupported derived output \(artifact.output.rawValue)")
            }
            inputs.append(RoomZIPInput(
                sourceURL: artifact.sourceURL,
                entryPath: artifact.entryPath,
                mediaType: artifact.mediaType
            ))
        }
        return (inputs, seenOutputs)
    }

    private static func output(
        for path: RoomExportEntryPath,
        materialization: RoomHeadExportMaterialization,
        derivedArtifacts: [RoomDerivedExportArtifact]
    ) -> RoomExportOutput {
        if let materialized = materialization.entries.first(where: { $0.entryPath == path }) {
            return materialized.output
        }
        if let derived = derivedArtifacts.first(where: { $0.entryPath == path }) {
            return derived.output
        }
        // `manifest.json` intentionally never appears in the manifest's own
        // entry closure, so this fallback should be unreachable for it.
        return .attachments
    }

    private static func completedOutputRecords(
        _ initial: [RoomExportOutputRecord],
        derivedOutputs: Set<RoomExportOutput>
    ) throws -> [RoomExportOutputRecord] {
        var records: [RoomExportOutput: RoomExportOutputRecord] = [:]
        for record in initial {
            guard records[record.output] == nil else {
                throw RoomExportError.duplicateEntryPath(record.output.rawValue)
            }
            records[record.output] = record
        }
        for output in derivedOutputs {
            records[output] = RoomExportOutputRecord(output: output, status: .generated)
        }
        guard Set(records.keys) == Set(RoomExportOutput.allCases) else {
            throw RoomExportError.missingRequiredArtifact("complete requested-output status closure")
        }
        return records.values.sorted { $0.output.rawValue < $1.output.rawValue }
    }

    private static func writeManifest(
        _ manifest: RoomExportManifest,
        to url: URL,
        workspace: URL
    ) throws {
        guard !FileManager.default.fileExists(atPath: url.path), !isSymbolicLink(url) else {
            throw RoomExportError.destinationAlreadyExists(url.path)
        }
        try validateContainedPath(url, workspace: workspace)
        do {
            let data = try RoomJSONCoding.makeEncoder().encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch let error as RoomExportError {
            throw error
        } catch {
            throw RoomExportError.zipStructureInvalid("Unable to write the export manifest.")
        }
    }

    private static func validateWorkspace(_ workspace: URL) throws {
        guard workspace.isFileURL,
              !isSymbolicLink(workspace),
              directoryExists(workspace)
        else {
            throw RoomExportError.unsafeDestination(workspace.path)
        }
    }

    private static func validateContainedRegularFile(_ url: URL, workspace: URL) throws {
        try validateContainedPath(url, workspace: workspace)
        guard !isSymbolicLink(url), try isRegularFile(url) else {
            throw RoomExportError.unsafeDestination(url.path)
        }
    }

    private static func validateContainedPath(_ url: URL, workspace: URL) throws {
        let root = workspace.standardizedFileURL.pathComponents
        let candidate = url.standardizedFileURL.pathComponents
        guard candidate.count >= root.count,
              zip(root, candidate).allSatisfy({ $0 == $1 })
        else {
            throw RoomExportError.unsafeDestination(url.path)
        }
        var current = workspace
        for component in candidate.dropFirst(root.count) {
            current.appendPathComponent(component)
            if isSymbolicLink(current) {
                throw RoomExportError.unsafeDestination(url.path)
            }
        }
    }

    private static func validatePNG(_ url: URL, byteCount: UInt64) throws {
        guard byteCount <= RoomExportLimits.maximumPNGBytes else {
            throw RoomExportError.sizeLimitExceeded(url.lastPathComponent)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 24), header.count == 24 else {
            throw RoomExportError.missingRequiredArtifact("floor-plan PNG header")
        }
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard Array(header.prefix(8)) == signature,
              String(decoding: header[12..<16], as: UTF8.self) == "IHDR"
        else {
            throw RoomExportError.missingRequiredArtifact("floor-plan PNG")
        }
        let width = UInt32(header[16]) << 24 | UInt32(header[17]) << 16 | UInt32(header[18]) << 8 | UInt32(header[19])
        let height = UInt32(header[20]) << 24 | UInt32(header[21]) << 16 | UInt32(header[22]) << 8 | UInt32(header[23])
        guard width > 0, height > 0,
              width <= UInt32(RoomExportLimits.maximumPNGPixelDimension),
              height <= UInt32(RoomExportLimits.maximumPNGPixelDimension)
        else {
            throw RoomExportError.sizeLimitExceeded("floor-plan PNG dimensions")
        }
    }

    private static func hasPDFHeader(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 5) else { return false }
        return prefix == Data("%PDF-".utf8)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isRegularFile(_ url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private static func fileByteCount(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
            throw RoomExportError.zipStructureInvalid("Derived file size is unavailable.")
        }
        return UInt64(size.int64Value)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
