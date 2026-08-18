import CoreGraphics
import Foundation
import ImageIO
import RoomScanCore
import UniformTypeIdentifiers

/// Adapter boundary for the RoomPlan/SceneKit renderer owned by the UI layer.
/// Rendering happens before `RoomAIRoomPackageAppService.prepare`, on a
/// detached task, and writes only to the supplied export lease.  The package
/// service consequently never asks a live capture session for pixels.
protocol RoomAIRoomPackageDerivativeRendering: Sendable {
    func renderFloorPlanPNG(
        sourceRevision: RoomRedesignSourceRevision,
        into leaseURL: URL
    ) async throws -> RoomAIRoomPackageAppArtifact

    func renderCanonicalViewPNGs(
        orientation: RoomOrientationContractV2,
        sourceRevision: RoomRedesignSourceRevision,
        into leaseURL: URL
    ) async throws -> [RoomAIRoomPackageAppArtifact]
}

enum RoomAIRoomPackageDerivativeRendererError: Error, Equatable {
    case wrongSourceRevision
    case missingCanonicalViewCount
    case unsafeOutput
}

enum RoomAIRoomPackageDerivativeRenderer {
    static func validate(
        floorPlan: RoomAIRoomPackageAppArtifact,
        canonicalViews: [RoomAIRoomPackageAppArtifact],
        orientation: RoomOrientationContractV2
    ) throws {
        guard floorPlan.relativePath == "derivatives/floor-plan.png",
              floorPlan.mediaType == "image/png" else {
            throw RoomAIRoomPackageDerivativeRendererError.unsafeOutput
        }
        guard canonicalViews.count == 6,
              Set(canonicalViews.map(\.artifactID)).count == 6,
              canonicalViews.allSatisfy({ $0.relativePath.hasPrefix("derivatives/canonical-views/") && $0.relativePath.hasSuffix(".png") && $0.mediaType == "image/png" }),
              Set(canonicalViews.map(\.artifactID)) == Set(orientation.canonicalCameras.map { "canonical-view-\($0.cameraID)" })
        else {
            throw RoomAIRoomPackageDerivativeRendererError.missingCanonicalViewCount
        }
    }
}

/// Production renderer for an immutable semantic snapshot and its exact
/// canonical cameras. When a source-bound raster exists for a camera it is
/// decoded and normalized; otherwise a clearly schematic semantic projection
/// is rendered for that camera. It never presents a schematic as a photograph.
struct UIKitRoomAIRoomPackageDerivativeRenderer: RoomAIRoomPackageDerivativeRendering {
    let snapshot: RoomSemanticSnapshot
    let expectedSourceRevision: RoomRedesignSourceRevision
    let canonicalViewSources: [String: URL]

    func renderFloorPlanPNG(sourceRevision: RoomRedesignSourceRevision, into leaseURL: URL) async throws -> RoomAIRoomPackageAppArtifact {
        guard sourceRevision == expectedSourceRevision else {
            throw RoomAIRoomPackageDerivativeRendererError.wrongSourceRevision
        }
        let projection = try RoomFloorPlanProjection.make(from: snapshot)
        let url = leaseURL.appendingPathComponent("derivatives/floor-plan.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try renderSemanticProjection(projection, camera: nil)
        try data.write(to: url, options: Data.WritingOptions.withoutOverwriting)
        return .init(artifactID: "floor-plan", sourceURL: url, relativePath: "derivatives/floor-plan.png", mediaType: "image/png")
    }

    func renderCanonicalViewPNGs(orientation: RoomOrientationContractV2, sourceRevision: RoomRedesignSourceRevision, into leaseURL: URL) async throws -> [RoomAIRoomPackageAppArtifact] {
        guard sourceRevision == expectedSourceRevision else {
            throw RoomAIRoomPackageDerivativeRendererError.wrongSourceRevision
        }
        try orientation.validate(boundTo: sourceRevision)
        let projection = try RoomFloorPlanProjection.make(from: snapshot)
        return try orientation.canonicalCameras.map { camera in
            let data: Data
            if let source = canonicalViewSources[camera.cameraID] {
                data = try normalizedPNG(from: source)
            } else {
                data = try renderSemanticProjection(projection, camera: camera)
            }
            let path = "derivatives/canonical-views/\(camera.cameraID).png"
            let destination = leaseURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: [.withoutOverwriting])
            return .init(artifactID: "canonical-view-\(camera.cameraID)", sourceURL: destination, relativePath: path, mediaType: "image/png")
        }
    }

    private func normalizedPNG(from sourceURL: URL) throws -> Data {
        let sourceBytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let sanitized = try RoomAIImageSanitizer.sanitize(
            sourceBytes,
            declaredFilename: sourceURL.lastPathComponent
        )
        guard let source = CGImageSourceCreateWithData(sanitized.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RoomAIRoomPackageDerivativeRendererError.unsafeOutput }
        return try pngData(from: image)
    }

    private func renderSemanticProjection(
        _ projection: RoomFloorPlanProjection,
        camera: RoomCanonicalCameraContract?
    ) throws -> Data {
        let width = 1_600
        let height = 1_200
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RoomAIRoomPackageDerivativeRendererError.unsafeOutput }

        context.setFillColor(CGColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bounds = projection.bounds
        let scale = min(
            1_500 / max(CGFloat(bounds.width), 0.01),
            1_100 / max(CGFloat(bounds.height), 0.01)
        )
        func point(x: Double, z: Double) -> CGPoint {
            CGPoint(
                x: 50 + CGFloat(x - bounds.minimum.x) * scale,
                y: 1_150 - CGFloat(z - bounds.minimum.y) * scale
            )
        }

        for item in projection.items {
            let points = item.corners.map { point(x: $0.x, z: $0.y) }
            guard let first = points.first else { continue }
            context.beginPath()
            context.move(to: first)
            for value in points.dropFirst() { context.addLine(to: value) }
            context.closePath()
            context.setFillColor(
                item.isStructural
                    ? CGColor(gray: 0.15, alpha: 0.12)
                    : CGColor(red: 0.04, green: 0.45, blue: 0.58, alpha: 0.18)
            )
            context.setStrokeColor(
                item.isStructural
                    ? CGColor(gray: 0.12, alpha: 1)
                    : CGColor(red: 0.04, green: 0.45, blue: 0.58, alpha: 1)
            )
            context.setLineWidth(item.isStructural ? 3 : 2)
            context.drawPath(using: .fillStroke)
        }

        if let camera {
            let start = point(x: camera.positionMeters.x, z: camera.positionMeters.z)
            let end = point(x: camera.targetMeters.x, z: camera.targetMeters.z)
            context.setStrokeColor(CGColor(red: 0.76, green: 0.36, blue: 0.04, alpha: 1))
            context.setFillColor(CGColor(red: 0.76, green: 0.36, blue: 0.04, alpha: 1))
            context.setLineWidth(6)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            context.fillEllipse(in: CGRect(x: start.x - 12, y: start.y - 12, width: 24, height: 24))
        }

        guard let image = context.makeImage() else {
            throw RoomAIRoomPackageDerivativeRendererError.unsafeOutput
        }
        return try pngData(from: image)
    }

    private func pngData(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw RoomAIRoomPackageDerivativeRendererError.unsafeOutput }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RoomAIRoomPackageDerivativeRendererError.unsafeOutput
        }
        let sanitized = try RoomAIImageSanitizer.sanitize(
            output as Data,
            declaredFilename: "derived.png"
        )
        guard sanitized.mediaType == "image/png" else {
            throw RoomAIRoomPackageDerivativeRendererError.unsafeOutput
        }
        return sanitized.data
    }
}
