import Foundation
import UIKit
import RoomScanCore

/// A bounded UIKit-only renderer for derived, clearly non-survey outputs. Core
/// supplies pure projection math; this adapter owns PNG/PDF framework calls.
@MainActor
struct UIKitRoomExportDerivedProvider: RoomHeadExportDeriving {
    private static let imageSize = CGSize(width: 1_600, height: 1_200)
    private static let pageSize = CGSize(width: 612, height: 792)

    func makeDerivedArtifacts(
        from materialization: RoomHeadExportMaterialization
    ) throws -> [RoomDerivedExportArtifact] {
        let semanticURL = materialization.workspaceURL.appendingPathComponent(
            "revision/semantic-model.json"
        )
        let semanticData = try Data(contentsOf: semanticURL)
        let snapshot = try RoomJSONCoding.makeDecoder().decode(
            RoomSemanticSnapshot.self,
            from: semanticData
        )
        let projection = try RoomFloorPlanProjection.make(from: snapshot)
        let derivedDirectory = materialization.workspaceURL.appendingPathComponent(
            "derived",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: derivedDirectory,
            withIntermediateDirectories: true
        )
        let pngURL = derivedDirectory.appendingPathComponent("floor-plan.png")
        let pdfURL = derivedDirectory.appendingPathComponent("summary.pdf")
        let pngData = makePNG(projection: projection)
        guard pngData.count <= Int(RoomExportLimits.maximumPNGBytes) else {
            throw RoomExportError.sizeLimitExceeded("derived/floor-plan.png")
        }
        try pngData.write(to: pngURL, options: .atomic)

        let pdfData = makePDF(
            projection: projection,
            projectID: materialization.descriptor.projectID,
            revisionID: materialization.descriptor.headRevisionID
        )
        guard pdfData.count <= Int(RoomExportLimits.maximumPDFBytes) else {
            throw RoomExportError.sizeLimitExceeded("derived/summary.pdf")
        }
        try pdfData.write(to: pdfURL, options: .atomic)
        return [
            RoomDerivedExportArtifact(
                sourceURL: pngURL,
                entryPath: try RoomExportEntryPath("derived/floor-plan.png"),
                mediaType: "image/png",
                output: .floorPlanPNG
            ),
            RoomDerivedExportArtifact(
                sourceURL: pdfURL,
                entryPath: try RoomExportEntryPath("derived/summary.pdf"),
                mediaType: "application/pdf",
                output: .pdfSummary,
                pageCount: 1
            ),
        ]
    }

    private func makePNG(projection: RoomFloorPlanProjection) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: Self.imageSize, format: format).pngData { context in
            UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: Self.imageSize))
            draw(projection: projection, in: context.cgContext, rect: CGRect(origin: .zero, size: Self.imageSize))
        }
    }

    private func makePDF(
        projection: RoomFloorPlanProjection,
        projectID: String,
        revisionID: String
    ) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: Self.pageSize),
            format: format
        )
        return renderer.pdfData { context in
            context.beginPage()
            let graphics = context.cgContext
            UIColor.white.setFill()
            graphics.fill(CGRect(origin: .zero, size: Self.pageSize))
            let title = "ROOMSCANSTUDIO - HEAD REVISION EXPORT"
            title.draw(
                in: CGRect(x: 36, y: 36, width: 540, height: 26),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: UIColor.black,
                ]
            )
            "Project \(projectID) | Head \(revisionID)".draw(
                in: CGRect(x: 36, y: 62, width: 540, height: 20),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: UIColor.darkGray,
                ]
            )
            draw(
                projection: projection,
                in: graphics,
                rect: CGRect(x: 36, y: 104, width: 540, height: 540)
            )
            "Derived from normalized semantic boxes. Measurements are estimates, not survey-grade evidence."
                .draw(
                    in: CGRect(x: 36, y: 668, width: 540, height: 48),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 9),
                        .foregroundColor: UIColor.darkGray,
                    ]
                )
        }
    }

    private func draw(
        projection: RoomFloorPlanProjection,
        in context: CGContext,
        rect: CGRect
    ) {
        let inset = rect.insetBy(dx: 24, dy: 24)
        let width = max(projection.bounds.width, 0.01)
        let height = max(projection.bounds.height, 0.01)
        let scale = min(inset.width / width, inset.height / height)
        context.setLineWidth(1.5)
        for item in projection.items {
            let points = item.corners.map {
                CGPoint(
                    x: inset.minX + CGFloat($0.x - projection.bounds.minimum.x) * scale,
                    y: inset.maxY - CGFloat($0.y - projection.bounds.minimum.y) * scale
                )
            }
            guard let first = points.first else { continue }
            let path = CGMutablePath()
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
            if item.isStructural {
                UIColor.black.withAlphaComponent(0.16).setFill()
                UIColor.black.setStroke()
            } else {
                UIColor(red: 0.04, green: 0.52, blue: 0.65, alpha: 0.2).setFill()
                UIColor(red: 0.04, green: 0.45, blue: 0.58, alpha: 1).setStroke()
            }
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }
    }
}
