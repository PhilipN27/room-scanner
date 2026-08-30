import Foundation
import RoomScanCore

/// The sole professional path allowed to inspect a local capture bundle.
/// Default working-set migration never references this type and therefore
/// cannot accidentally enumerate RGB, depth, confidence, mesh, or diagnostic
/// capture evidence. The bound manifest is a closed ledger: no directory
/// enumeration is used to discover optional files.
@MainActor
final class ProfessionalRawArchiveMaterializer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Produces an exact, source-bound disclosure ledger. It does not retain
    /// files or bytes; callers must explicitly accept this immutable selection
    /// before `build` can create the separate raw archive.
    func review(
        sourceRevision: RoomRedesignSourceRevision
    ) async throws -> ProfessionalProjectRawReview {
        try sourceRevision.validate()
        guard let evidence = RoomCaptureBundleLibrary.boundEvidence(
            forProject: sourceRevision.projectID,
            expectedSourceRevision: sourceRevision
        ), evidence.sourceBinding.sourceRevision == sourceRevision else {
            throw ProfessionalProjectSyncError.sourceUnavailable
        }

        var inputs: [RoomProfessionalRawArchiveInput] = []
        var ordinal = 0
        func append(
            assetClass: RoomProfessionalRawAssetClass,
            sourceURL: URL,
            archiveName: String,
            mediaType: String
        ) throws {
            ordinal += 1
            let prefix = assetClass.rawValue
            let assetID = String(format: "%@-%05d", prefix, ordinal)
            let path = "raw/\(assetClass.rawValue)-\(archiveName)"
            try requireRegularSourceFile(sourceURL)
            inputs.append(try RoomProfessionalRawArchiveInput(
                assetID: assetID,
                assetClass: assetClass,
                sourceURL: sourceURL,
                archivePath: path,
                mediaType: mediaType
            ))
        }

        // Bound sidecars are diagnostics, not working-set companions. Their
        // fixed filenames come from the capture contract, not a directory walk.
        try append(
            assetClass: .diagnostics,
            sourceURL: evidence.directoryURL.appendingPathComponent(
                RoomCaptureBundleLibrary.manifestFileName
            ),
            archiveName: "bundle-manifest.json",
            mediaType: "application/json"
        )
        try append(
            assetClass: .diagnostics,
            sourceURL: evidence.directoryURL.appendingPathComponent(
                RoomCaptureBundleLibrary.sourceBindingFileName
            ),
            archiveName: "source-revision-binding.json",
            mediaType: "application/json"
        )

        let meshURL = evidence.directoryURL.appendingPathComponent(
            RoomCaptureBundleLibrary.sceneMeshFileName
        )
        if try isRegularSourceFile(meshURL) {
            try append(
                assetClass: .diagnostics,
                sourceURL: meshURL,
                archiveName: "scene-mesh.ply",
                mediaType: "application/octet-stream"
            )
        }

        let framesURL = evidence.directoryURL.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        for (index, frame) in evidence.manifest.frames.enumerated() {
            guard RoomCaptureBundleLibrary.isSafeCaptureFileLeaf(frame.fileName) else {
                throw ProfessionalProjectSyncError.invalidRawReview
            }
            let label = String(format: "%05d", index + 1)
            try append(
                assetClass: .rgb,
                sourceURL: framesURL.appendingPathComponent(frame.fileName),
                archiveName: "\(label).jpg",
                mediaType: "image/jpeg"
            )
            guard let depth = frame.depth else { continue }
            guard RoomCaptureBundleLibrary.isSafeCaptureFileLeaf(depth.fileName) else {
                throw ProfessionalProjectSyncError.invalidRawReview
            }
            try append(
                assetClass: .depth,
                sourceURL: framesURL.appendingPathComponent(depth.fileName),
                archiveName: "\(label).bin",
                mediaType: "application/octet-stream"
            )
            if let confidenceName = depth.confidenceFileName {
                guard RoomCaptureBundleLibrary.isSafeCaptureFileLeaf(confidenceName) else {
                    throw ProfessionalProjectSyncError.invalidRawReview
                }
                try append(
                    assetClass: .confidence,
                    sourceURL: framesURL.appendingPathComponent(confidenceName),
                    archiveName: "\(label).bin",
                    mediaType: "application/octet-stream"
                )
            }
        }

        let selectionSHA256 = try await RoomProfessionalRawArchive.selectionSHA256(
            sourceRevision: sourceRevision,
            inputs: inputs
        )
        let entries = try await ledgerEntries(
            sourceRevision: sourceRevision,
            inputs: inputs,
            expectedSelectionSHA256: selectionSHA256
        )
        return .init(
            sourceRevision: sourceRevision,
            entries: entries,
            byteCountByClass: totals(entries, initial: UInt64.zero, value: \.byteCount),
            countByClass: totals(entries, initial: 0, value: { _ in 1 }),
            selectionSHA256: selectionSHA256,
            inputs: inputs
        )
    }

    /// Acceptance is explicit and produces the Core contract that binds the
    /// exact source revision and selection. Precise GPS is never a selectable
    /// raw class and remains explicitly excluded in the signed review.
    func accept(
        _ review: ProfessionalProjectRawReview,
        reviewID: String,
        reviewedAt: Date = Date()
    ) throws -> RoomRawDisclosureReview {
        guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(reviewID),
              ProfessionalProjectSyncJournalRecord.isSHA256(review.selectionSHA256),
              !review.entries.isEmpty
        else { throw ProfessionalProjectSyncError.invalidRawReview }
        return try RoomRawDisclosureReview(
            reviewID: reviewID,
            sourceRevision: review.sourceRevision,
            reviewedSelectionSHA256: review.selectionSHA256,
            reviewedAt: reviewedAt,
            decision: .accepted,
            preciseGPSExcluded: true
        )
    }

    /// Recomputes the closed ledger before creating an archive. This catches
    /// changed/deleted raw files and refuses to reuse an accepted review for a
    /// different revision or selection; it never truncates a raw source.
    func build(
        review: ProfessionalProjectRawReview,
        acceptedDisclosure: RoomRawDisclosureReview,
        archiveURL: URL
    ) async throws -> RoomProfessionalRawArchiveSnapshot {
        guard acceptedDisclosure.sourceRevision == review.sourceRevision,
              acceptedDisclosure.reviewedSelectionSHA256 == review.selectionSHA256,
              acceptedDisclosure.decision == .accepted
        else { throw ProfessionalProjectSyncError.invalidRawReview }
        let recalculated = try await RoomProfessionalRawArchive.selectionSHA256(
            sourceRevision: review.sourceRevision,
            inputs: review.inputs
        )
        guard recalculated == review.selectionSHA256 else {
            throw ProfessionalProjectSyncError.invalidRawReview
        }
        do {
            return try await RoomProfessionalRawArchive.build(
                sourceRevision: review.sourceRevision,
                review: acceptedDisclosure,
                inputs: review.inputs,
                archiveURL: archiveURL
            )
        } catch {
            throw ProfessionalProjectSyncError.invalidRawReview
        }
    }

    private func ledgerEntries(
        sourceRevision: RoomRedesignSourceRevision,
        inputs: [RoomProfessionalRawArchiveInput],
        expectedSelectionSHA256: String
    ) async throws -> [RoomProfessionalRawArchiveEntry] {
        // Core owns archive-entry preflight and exact SHA/byte binding. Build a
        // temporary, isolated archive to obtain its public ledger, then remove
        // it before returning the review. This avoids app-side duplicate ZIP
        // behavior while preserving a real Core source oracle.
        let directory = try temporaryReviewDirectory()
        defer { try? fileManager.removeItem(at: directory) }
        let provisionalReview = try RoomRawDisclosureReview(
            reviewID: "raw-review-preview",
            sourceRevision: sourceRevision,
            reviewedSelectionSHA256: expectedSelectionSHA256,
            reviewedAt: Date(timeIntervalSince1970: 0),
            decision: .accepted,
            preciseGPSExcluded: true
        )
        let snapshot = try await RoomProfessionalRawArchive.build(
            sourceRevision: sourceRevision,
            review: provisionalReview,
            inputs: inputs,
            archiveURL: directory.appendingPathComponent("review.zip")
        )
        return snapshot.manifest.entries
    }

    private func temporaryReviewDirectory() throws -> URL {
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "roomscan-professional-raw-review",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func isRegularSourceFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func requireRegularSourceFile(_ url: URL) throws {
        guard try isRegularSourceFile(url) else {
            throw ProfessionalProjectSyncError.invalidRawReview
        }
    }

    private func totals<T>(
        _ entries: [RoomProfessionalRawArchiveEntry],
        initial: T,
        value: (RoomProfessionalRawArchiveEntry) -> T
    ) -> [RoomProfessionalRawAssetClass: T] where T: AdditiveArithmetic {
        var result = Dictionary(uniqueKeysWithValues: RoomProfessionalRawAssetClass.allCases.map { ($0, initial) })
        for entry in entries {
            result[entry.assetClass, default: initial] += value(entry)
        }
        return result
    }
}
