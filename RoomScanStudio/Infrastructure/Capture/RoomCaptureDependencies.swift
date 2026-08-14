import Foundation
import ImageIO
import RoomScanCore
import UIKit

/// A scratch directory owned by one app capture attempt. It is deliberately a
/// sibling of, never a child of, the authoritative project-package root.
struct RoomCaptureScratchWorkspace: Sendable, Equatable {
    let attempt: RoomCaptureAttemptToken
    let directoryURL: URL
}

/// Small, pure ownership gate for the asynchronous RoomPlan final-stop
/// callback. A driver must retain its AR/RoomPlan ownership until the matching
/// `didEndWith` callback has arrived; this type deliberately has no waiting or
/// continuation so a timeout path cannot leak a suspended continuation.
struct RoomCaptureSessionEndObservationGate: Sendable, Equatable {
    private(set) var endedAttempt: RoomCaptureAttemptToken?

    init(endedAttempt: RoomCaptureAttemptToken? = nil) {
        self.endedAttempt = endedAttempt
    }

    mutating func reset() {
        endedAttempt = nil
    }

    mutating func recordDidEnd(for attempt: RoomCaptureAttemptToken) {
        endedAttempt = attempt
    }

    func allowsOwnershipRelease(for attempt: RoomCaptureAttemptToken) -> Bool {
        endedAttempt == attempt
    }
}

/// Creates and removes only attempt-owned scratch directories. The persistent
/// package store receives these files only after the user explicitly saves a
/// prepared review. Existing parent aliases are canonicalized, while the
/// configured scratch leaf and every owned attempt leaf must never be links.
final class RoomCaptureScratchWorkspaceFactory {
    private let configuredRootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        configuredRootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func makeWorkspace(
        for attempt: RoomCaptureAttemptToken
    ) throws -> RoomCaptureScratchWorkspace {
        guard isSafeAttemptComponent(attempt.value) else {
            throw RoomCaptureDriverError.invalidAttempt
        }
        let rootURL = try ensureOwnedRootExists()
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let directoryURL = rootURL.appendingPathComponent(
            "attempt-\(attempt.value)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        try validateOwnedWorkspace(
            directoryURL,
            for: attempt,
            rootURL: rootURL
        )
        return RoomCaptureScratchWorkspace(
            attempt: attempt,
            directoryURL: directoryURL
        )
    }

    /// Removes only an existing, direct, owned attempt child. Failure is
    /// surfaced to the coordinator so it can retain the workspace and offer a
    /// retry; it is never silently converted into a terminal capture state.
    func cleanup(_ workspace: RoomCaptureScratchWorkspace) throws {
        let rootURL = try existingOwnedRoot()
        let candidate = try validateOwnedWorkspace(
            workspace.directoryURL,
            for: workspace.attempt,
            rootURL: rootURL
        )
        do {
            try fileManager.removeItem(at: candidate)
        } catch {
            throw RoomCaptureScratchError.cleanupFailed(candidate.path)
        }
    }

    /// Dedicated scratch roots may retain attempts only after an interrupted
    /// process. This never follows a link or removes a non-owned sibling.
    func recoverOwnedOrphans() throws {
        guard fileManager.fileExists(atPath: configuredRootURL.path) else {
            return
        }
        let rootURL = try existingOwnedRoot()
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix("attempt-"), isSafeAttemptDirectoryName(name) else {
                continue
            }
            guard child.deletingLastPathComponent().standardizedFileURL == rootURL else {
                throw RoomCaptureScratchError.unsafeWorkspace(child.path)
            }
            if try isSymbolicLink(at: child) {
                throw RoomCaptureScratchError.symbolicLink(child.path)
            }
            let attributes = try fileManager.attributesOfItem(atPath: child.path)
            guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
                throw RoomCaptureScratchError.unsafeWorkspace(child.path)
            }
            try fileManager.removeItem(at: child)
        }
    }

    private func isSafeAttemptComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func isSafeAttemptDirectoryName(_ value: String) -> Bool {
        guard value.hasPrefix("attempt-"), value.count <= 256 else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func ensureOwnedRootExists() throws -> URL {
        let rootURL = try canonicalRootURL()
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        if try isSymbolicLink(at: rootURL) {
            throw RoomCaptureScratchError.symbolicLink(rootURL.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: rootURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw RoomCaptureScratchError.unsafeRoot(rootURL.path)
        }
        return rootURL
    }

    private func existingOwnedRoot() throws -> URL {
        let rootURL = try canonicalRootURL()
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw RoomCaptureDriverError.noScratchWorkspace
        }
        if try isSymbolicLink(at: rootURL) {
            throw RoomCaptureScratchError.symbolicLink(rootURL.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: rootURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw RoomCaptureScratchError.unsafeRoot(rootURL.path)
        }
        return rootURL
    }

    private func canonicalRootURL() throws -> URL {
        let requested = configuredRootURL.standardizedFileURL
        if fileManager.fileExists(atPath: requested.path) {
            if try isSymbolicLink(at: requested) {
                throw RoomCaptureScratchError.symbolicLink(requested.path)
            }
            return requested.resolvingSymlinksInPath().standardizedFileURL
        }

        var missingComponents: [String] = []
        var ancestor = requested
        while !fileManager.fileExists(atPath: ancestor.path) {
            let component = ancestor.lastPathComponent
            guard !component.isEmpty, component != "/" else {
                throw RoomCaptureScratchError.unsafeRoot(requested.path)
            }
            missingComponents.append(component)
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                throw RoomCaptureScratchError.unsafeRoot(requested.path)
            }
            ancestor = parent
        }
        let canonicalAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
        return missingComponents.reversed().reduce(canonicalAncestor) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    private func validateOwnedWorkspace(
        _ workspaceURL: URL,
        for attempt: RoomCaptureAttemptToken,
        rootURL: URL
    ) throws -> URL {
        let candidate = workspaceURL.standardizedFileURL
        guard candidate.deletingLastPathComponent().standardizedFileURL == rootURL,
              candidate.lastPathComponent.hasPrefix("attempt-\(attempt.value)-"),
              isSafeAttemptDirectoryName(candidate.lastPathComponent),
              fileManager.fileExists(atPath: candidate.path)
        else {
            throw RoomCaptureScratchError.unsafeWorkspace(workspaceURL.path)
        }
        if try isSymbolicLink(at: candidate) {
            throw RoomCaptureScratchError.symbolicLink(candidate.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw RoomCaptureScratchError.unsafeWorkspace(candidate.path)
        }
        return candidate
    }

    private func isSymbolicLink(at url: URL) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

enum RoomCaptureScratchError: LocalizedError, Sendable, Equatable {
    case unsafeRoot(String)
    case unsafeWorkspace(String)
    case symbolicLink(String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsafeRoot(path):
            return "The capture scratch root is unsafe: \(path)."
        case let .unsafeWorkspace(path):
            return "The capture scratch workspace is unsafe: \(path)."
        case let .symbolicLink(path):
            return "Capture scratch paths cannot be symbolic links: \(path)."
        case let .cleanupFailed(path):
            return "Attempt scratch cleanup failed: \(path)."
        }
    }
}

enum RoomCaptureDriverError: LocalizedError, Sendable {
    case invalidAttempt
    case noScratchWorkspace
    case noCapturedResult
    case simulatedFailure(String)
    case liveAdapterUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAttempt:
            return "The capture attempt identifier is invalid."
        case .noScratchWorkspace:
            return "Capture scratch storage is unavailable."
        case .noCapturedResult:
            return "No completed capture result is available to review."
        case let .simulatedFailure(message):
            return message
        case .liveAdapterUnavailable:
            return "The inert capture-driver test seam cannot start a live RoomPlan attempt."
        }
    }
}

enum RoomCaptureGPSResult: Sendable, Equatable {
    case authorized(RoomGPSLocation?)
    case denied
}

@MainActor
protocol RoomCameraPermissionProviding: AnyObject {
    func requestCameraPermission(
        for attempt: RoomCaptureAttemptToken
    ) async -> RoomCapturePermission
}

@MainActor
protocol RoomLocationProviding: AnyObject {
    func requestCurrentLocation(
        for attempt: RoomCaptureAttemptToken
    ) async -> RoomCaptureGPSResult
    /// Cancels only the matching attempt's in-flight request and resumes its
    /// waiter before the capture coordinator can route to a terminal phase.
    func cancelCurrentLocation(for attempt: RoomCaptureAttemptToken) async
}

/// Main-actor observations are separated from the pure Core reducer. The
/// real RoomPlan adapter will translate delegate callbacks into these values;
/// the deterministic driver uses the same contract without Apple APIs.
enum RoomCaptureDriverObservation: Sendable, Equatable {
    case didStart(attempt: RoomCaptureAttemptToken)
    case didStop(attempt: RoomCaptureAttemptToken)
    case coaching(
        attempt: RoomCaptureAttemptToken,
        instruction: RoomCaptureCoachingInstruction
    )
    case tracking(
        attempt: RoomCaptureAttemptToken,
        quality: RoomTrackingQuality,
        limitedReason: RoomTrackingLimitedReason?
    )
    /// Snapshot-derived semantic guidance. It is maintained separately from
    /// transient operational guidance so normal/bright recovery can clear the
    /// latter without discarding a real semantic review warning.
    case semanticGuidance(
        attempt: RoomCaptureAttemptToken,
        values: [RoomCaptureGuidance]
    )
    /// Transient coaching, tracking, and lighting guidance. Drivers publish
    /// an empty array when a previously observed condition recovers.
    case operationalGuidance(
        attempt: RoomCaptureAttemptToken,
        values: [RoomCaptureGuidance]
    )
    /// Bounded, qualitative quality cues. Adapters may localize only when
    /// their current pose and semantic region evidence supports it.
    case qualityCoaching(
        attempt: RoomCaptureAttemptToken,
        values: [RoomQualityCoachingCue]
    )
    case liveSnapshot(
        attempt: RoomCaptureAttemptToken,
        snapshot: RoomSemanticSnapshot
    )
    case terminated(
        attempt: RoomCaptureAttemptToken,
        reason: RoomCaptureTerminationReason
    )
}

/// Review-ready input remains outside the durable store until the coordinator
/// dispatches the Core reducer's explicit save effect.
struct RoomCapturePreparedReview: Sendable, Equatable {
    var commit: RoomInitialCaptureCommit
    var guidance: [RoomCaptureGuidance]
    var orientationSuggestion: RoomOrientationSuggestion?

    init(
        commit: RoomInitialCaptureCommit,
        guidance: [RoomCaptureGuidance] = [],
        orientationSuggestion: RoomOrientationSuggestion? = nil
    ) {
        self.commit = commit
        self.guidance = guidance
        self.orientationSuggestion = orientationSuggestion
    }
}

/// Scalar/pose-only tracking sample collected during capture. It deliberately
/// carries no image buffer and is bounded by the Apple adapter before use.
struct RoomCaptureQualityTrackingSample: Sendable, Equatable {
    var sequence: Int
    var timestamp: Double
    var quality: RoomTrackingQuality
    var limitedReason: RoomTrackingLimitedReason?
    var cameraTransform: [Double]
    var intrinsics: [Double]
    var imageWidth: Int
    var imageHeight: Int
}

/// Post-stop quality analysis. JPEG downsampling and luminance scoring happen
/// only from the driver's processing task, never from ARSession polling or the
/// live capture callback path.
enum RoomCaptureQualityAnalyzer {
    static let maximumAnalysisPixelSize = 320

    static func analyze(
        snapshot: RoomSemanticSnapshot,
        coordinateSpaceEpochID: String,
        bundleDirectoryURL: URL,
        trackingSamples: [RoomCaptureQualityTrackingSample]
    ) throws -> RoomQualityAssessment {
        let regions = makeRegions(snapshot: snapshot)
        let manifestURL = bundleDirectoryURL.appendingPathComponent(
            RoomCaptureBundleLibrary.manifestFileName
        )
        let manifest = try? RoomJSONCoding.makeDecoder().decode(
            RoomCaptureBundleManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let framesDirectory = bundleDirectoryURL.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )

        var visualFrames: [RoomQualityFrameEvidence] = []
        var coverageFrames: [RoomQualityCoverageEvidence] = []
        for (index, frame) in (manifest?.frames ?? []).prefix(2_000).enumerated() {
            guard let camera = RoomMeshProjection.Camera(
                cameraToWorldColumnMajor: frame.cameraTransform,
                intrinsicsColumnMajor: frame.intrinsics,
                sensorWidth: frame.imageWidth,
                sensorHeight: frame.imageHeight
            ) else { continue }
            let visible = visibleRegionIDs(regions: regions, camera: camera)
            let evidence = RoomQualityEvidenceReference(
                evidenceID: String(format: "keyframe-%05d", index + 1),
                kind: .posedKeyframe,
                sourceReference: "capture-bundle/frames/\(frame.fileName)"
            )
            coverageFrames.append(.init(evidence: evidence, visibleRegionIDs: visible))
            let imageURL = framesDirectory.appendingPathComponent(frame.fileName)
            guard let image = downsampledRGBA(at: imageURL) else { continue }
            visualFrames.append(.init(
                evidence: evidence,
                rawSharpness: RoomMeshFrameAnalysis.luminanceSharpness(
                    rgba: image.rgba,
                    width: image.width,
                    height: image.height
                ),
                visibleRegionIDs: visible
            ))
        }

        let tracking = trackingSamples.prefix(2_000).map { sample in
            let camera = RoomMeshProjection.Camera(
                cameraToWorldColumnMajor: sample.cameraTransform,
                intrinsicsColumnMajor: sample.intrinsics,
                sensorWidth: sample.imageWidth,
                sensorHeight: sample.imageHeight
            )
            return RoomQualityTrackingEvidence(
                evidence: .init(
                    evidenceID: String(format: "tracking-%05d", sample.sequence),
                    kind: .trackingObservation,
                    sourceReference: String(format: "arkit-tracking-observation-%05d", sample.sequence)
                ),
                quality: sample.quality,
                limitedReason: sample.limitedReason,
                affectedRegionID: camera.flatMap {
                    visibleRegionIDs(regions: regions, camera: $0).first
                }
            )
        }
        let elementsByID = Dictionary(uniqueKeysWithValues: (
            snapshot.structuralElements + snapshot.objectElements
        ).map { ($0.id, $0) })
        let semantics = regions.compactMap { region -> RoomQualitySemanticEvidence? in
            guard let element = elementsByID[region.semanticElementID ?? ""] else { return nil }
            return .init(
                evidence: .init(
                    evidenceID: "semantic-\(region.regionID)",
                    kind: .semanticElement,
                    sourceReference: "semantic-model/\(element.id)"
                ),
                classificationConfidence: element.provenance?.classificationConfidence ?? .unknown,
                affectedRegionID: region.regionID
            )
        }
        return try RoomQualityAggregator.aggregate(.init(
            coordinateSpaceEpochID: coordinateSpaceEpochID,
            regions: regions,
            frames: visualFrames,
            tracking: tracking,
            semantics: semantics,
            coverageFrames: coverageFrames,
            visualSourceAvailable: manifest != nil && !visualFrames.isEmpty,
            coverageSourceAvailable: manifest != nil && !coverageFrames.isEmpty
        ))
    }

    static func makeRegions(snapshot: RoomSemanticSnapshot) -> [RoomQualityRegion] {
        (snapshot.structuralElements + snapshot.objectElements)
            .compactMap { element in
                let transform: RoomTransform4x4
                if let existing = element.transform {
                    transform = existing
                } else if let position = try? RoomSpatialNormalization.position(of: element) {
                    transform = RoomTransform4x4(columnMajorValues: [
                        1, 0, 0, 0,
                        0, 1, 0, 0,
                        0, 0, 1, 0,
                        position.x, position.y, position.z, 1,
                    ])
                } else {
                    return nil
                }
                return try? RoomQualityRegion(
                    regionID: element.id,
                    label: element.label,
                    semanticElementID: element.id,
                    dimensionsMeters: .init(
                        width: max(0.02, element.dimensionsMeters.width),
                        height: max(0.02, element.dimensionsMeters.height),
                        depth: max(0.02, element.dimensionsMeters.depth)
                    ),
                    roomTransform: transform
                )
            }
            .sorted { $0.regionID < $1.regionID }
    }

    static func visibleRegionIDs(
        regions: [RoomQualityRegion],
        camera: RoomMeshProjection.Camera
    ) -> [String] {
        regions.filter { region in
            samplePoints(for: region).contains { point in
                guard let projected = camera.project(world: point) else { return false }
                return camera.containsSensorPixel(projected.pixel)
            }
        }.map(\.regionID).sorted()
    }

    private static func samplePoints(for region: RoomQualityRegion) -> [SIMD3<Double>] {
        let width = region.dimensionsMeters.width * 0.35
        let height = region.dimensionsMeters.height * 0.35
        let local = [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(width, 0, 0), SIMD3<Double>(-width, 0, 0),
            SIMD3<Double>(0, height, 0), SIMD3<Double>(0, -height, 0),
        ]
        let m = region.roomTransform.columnMajorValues
        guard m.count == 16 else { return [] }
        return local.map { point in
            SIMD3<Double>(
                m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
                m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
                m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14]
            )
        }
    }

    private static func downsampledRGBA(at url: URL) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: false,
                      kCGImageSourceThumbnailMaxPixelSize: maximumAnalysisPixelSize,
                  ] as CFDictionary
              )
        else { return nil }
        let width = image.width
        let height = image.height
        guard width >= 3, height >= 3 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? (rgba, width, height) : nil
    }
}

@MainActor
protocol RoomCaptureDriving: AnyObject {
    var observationHandler: ((RoomCaptureDriverObservation) -> Void)? { get set }

    /// The live camera/scan surface for full-screen presentation during a
    /// scan, when the driver has one. Deterministic and inert drivers return
    /// nil and the capture UI falls back to the semantic canvas.
    var liveCaptureView: UIView? { get }

    func start(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws
    func stop(attempt: RoomCaptureAttemptToken) async throws
    func terminate(attempt: RoomCaptureAttemptToken) async
    func process(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws -> RoomCapturePreparedReview
    func requestReferencePhoto(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID,
        workspace: RoomCaptureScratchWorkspace
    ) async throws
    /// Cancel any driver-owned processor and wait until it cannot write into
    /// the attempt workspace again.
    func cancelProcessing(attempt: RoomCaptureAttemptToken) async
    /// Barrier for any start/photo/processing work that can write scratch
    /// files. The coordinator also awaits its own tracked tasks before removal.
    func awaitScratchWriteBarrier(for attempt: RoomCaptureAttemptToken) async
    func cleanup(workspace: RoomCaptureScratchWorkspace) async throws
}

extension RoomCaptureDriving {
    var liveCaptureView: UIView? { nil }
}

@MainActor
protocol RoomCaptureDriverFactory: AnyObject {
    func makeDriver() -> any RoomCaptureDriving
}

@MainActor
protocol RoomCaptureSavePolicy: AnyObject {
    func validateSave(for attempt: RoomCaptureAttemptToken) throws
}

@MainActor
protocol RoomCaptureAttemptIDGenerating: AnyObject {
    func nextAttemptToken() -> RoomCaptureAttemptToken
}

@MainActor
final class UUIDRoomCaptureAttemptIDGenerator: RoomCaptureAttemptIDGenerating {
    func nextAttemptToken() -> RoomCaptureAttemptToken {
        RoomCaptureAttemptToken("capture-\(UUID().uuidString.lowercased())")
    }
}

@MainActor
final class DeterministicRoomCaptureAttemptIDGenerator: RoomCaptureAttemptIDGenerating {
    private var values: [String]
    private var nextIndex = 0

    init(values: [String]) {
        self.values = values
    }

    func nextAttemptToken() -> RoomCaptureAttemptToken {
        let value: String
        if nextIndex < values.count {
            value = values[nextIndex]
        } else {
            value = "capture-deterministic-\(nextIndex + 1)"
        }
        nextIndex += 1
        return RoomCaptureAttemptToken(value)
    }
}

@MainActor
final class StaticCameraPermissionProvider: RoomCameraPermissionProviding {
    private let permission: RoomCapturePermission

    init(permission: RoomCapturePermission) {
        self.permission = permission
    }

    func requestCameraPermission(
        for attempt: RoomCaptureAttemptToken
    ) async -> RoomCapturePermission {
        permission
    }
}

@MainActor
final class StaticLocationProvider: RoomLocationProviding {
    private let result: RoomCaptureGPSResult

    init(result: RoomCaptureGPSResult) {
        self.result = result
    }

    func requestCurrentLocation(
        for attempt: RoomCaptureAttemptToken
    ) async -> RoomCaptureGPSResult {
        result
    }

    func cancelCurrentLocation(for attempt: RoomCaptureAttemptToken) async {}
}

@MainActor
final class AcceptingRoomCaptureSavePolicy: RoomCaptureSavePolicy {
    func validateSave(for attempt: RoomCaptureAttemptToken) throws {}
}

@MainActor
final class FailingRoomCaptureSavePolicy: RoomCaptureSavePolicy {
    func validateSave(for attempt: RoomCaptureAttemptToken) throws {
        throw RoomCaptureDriverError.simulatedFailure(
            "The deterministic capture save failure was requested. Scratch review data remains available."
        )
    }
}

/// Deliberate test seam for callers that need an inert driver. Production
/// `AppEnvironment` uses `AppleRoomCaptureDriverFactory`; this type never
/// opens a camera or constructs an AR session.
@MainActor
final class UnavailableLiveRoomCaptureDriver: RoomCaptureDriving {
    var observationHandler: ((RoomCaptureDriverObservation) -> Void)?

    func start(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        throw RoomCaptureDriverError.liveAdapterUnavailable
    }

    func stop(attempt: RoomCaptureAttemptToken) async throws {
        throw RoomCaptureDriverError.liveAdapterUnavailable
    }

    func terminate(attempt: RoomCaptureAttemptToken) async {}

    func process(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws -> RoomCapturePreparedReview {
        throw RoomCaptureDriverError.liveAdapterUnavailable
    }

    func requestReferencePhoto(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        throw RoomCaptureDriverError.liveAdapterUnavailable
    }

    func cancelProcessing(attempt: RoomCaptureAttemptToken) async {}

    func awaitScratchWriteBarrier(for attempt: RoomCaptureAttemptToken) async {}

    func cleanup(workspace: RoomCaptureScratchWorkspace) async throws {}
}

@MainActor
final class UnavailableLiveRoomCaptureDriverFactory: RoomCaptureDriverFactory {
    func makeDriver() -> any RoomCaptureDriving {
        UnavailableLiveRoomCaptureDriver()
    }
}
