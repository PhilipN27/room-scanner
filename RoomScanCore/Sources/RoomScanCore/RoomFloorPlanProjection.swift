import Foundation

/// Pure top-down projection inputs for the UIKit-only PNG/PDF providers. It
/// deliberately describes semantic boxes, not RoomPlan mesh or survey truth.
public struct RoomFloorPlanPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct RoomFloorPlanItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var label: String
    public var center: RoomFloorPlanPoint
    public var widthMeters: Double
    public var depthMeters: Double
    public var isStructural: Bool
    /// Top-down corners after applying the stored column-major transform's
    /// local X/Z basis. The UIKit renderer draws this polygon rather than an
    /// axis-aligned extent, preserving captured yaw for semantic boxes.
    public var corners: [RoomFloorPlanPoint]

    public init(
        id: String,
        kind: String,
        label: String,
        center: RoomFloorPlanPoint,
        widthMeters: Double,
        depthMeters: Double,
        isStructural: Bool,
        corners: [RoomFloorPlanPoint]
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.center = center
        self.widthMeters = widthMeters
        self.depthMeters = depthMeters
        self.isStructural = isStructural
        self.corners = corners
    }
}

public struct RoomFloorPlanBounds: Codable, Sendable, Equatable {
    public var minimum: RoomFloorPlanPoint
    public var maximum: RoomFloorPlanPoint

    public init(minimum: RoomFloorPlanPoint, maximum: RoomFloorPlanPoint) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var width: Double { maximum.x - minimum.x }
    public var height: Double { maximum.y - minimum.y }
}

public struct RoomFloorPlanProjection: Codable, Sendable, Equatable {
    /// Derived renderers intentionally cap semantic coordinates. Store-valid
    /// values can be finite yet far too large for CoreGraphics multiplication.
    public static let maximumRenderableMeters = 100_000.0
    public var items: [RoomFloorPlanItem]
    public var bounds: RoomFloorPlanBounds

    public init(items: [RoomFloorPlanItem], bounds: RoomFloorPlanBounds) {
        self.items = items
        self.bounds = bounds
    }

    public static func make(from snapshot: RoomSemanticSnapshot) throws -> RoomFloorPlanProjection {
        let structural = try snapshot.structuralElements.map { try item($0, structural: true) }
        let objects = try snapshot.objectElements.map { try item($0, structural: false) }
        let items = (structural + objects).sorted { $0.id < $1.id }
        guard let first = items.first else {
            return RoomFloorPlanProjection(
                items: [],
                bounds: RoomFloorPlanBounds(
                    minimum: RoomFloorPlanPoint(x: -1, y: -1),
                    maximum: RoomFloorPlanPoint(x: 1, y: 1)
                )
            )
        }
        var minimumX = try bounded(first.corners.map(\.x).min() ?? first.center.x)
        var maximumX = try bounded(first.corners.map(\.x).max() ?? first.center.x)
        var minimumY = try bounded(first.corners.map(\.y).min() ?? first.center.y)
        var maximumY = try bounded(first.corners.map(\.y).max() ?? first.center.y)
        for item in items.dropFirst() {
            minimumX = min(minimumX, try bounded(item.corners.map(\.x).min() ?? item.center.x))
            maximumX = max(maximumX, try bounded(item.corners.map(\.x).max() ?? item.center.x))
            minimumY = min(minimumY, try bounded(item.corners.map(\.y).min() ?? item.center.y))
            maximumY = max(maximumY, try bounded(item.corners.map(\.y).max() ?? item.center.y))
        }
        // A stable one-metre margin keeps zero-thickness/one-dimensional
        // surfaces visible in the derived semantic drawing.
        return RoomFloorPlanProjection(
            items: items,
            bounds: RoomFloorPlanBounds(
                minimum: RoomFloorPlanPoint(x: try bounded(minimumX - 1), y: try bounded(minimumY - 1)),
                maximum: RoomFloorPlanPoint(x: try bounded(maximumX + 1), y: try bounded(maximumY + 1))
            )
        )
    }

    private static func item(
        _ element: RoomSemanticElement,
        structural: Bool
    ) throws -> RoomFloorPlanItem {
        guard
            element.dimensionsMeters.width.isFinite,
            element.dimensionsMeters.depth.isFinite,
            element.dimensionsMeters.width >= 0,
            element.dimensionsMeters.depth >= 0
        else {
            throw RoomFloorPlanProjectionError.invalidSemanticBounds(element.id)
        }
        let transform = element.transform?.columnMajorValues ?? [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        guard transform.count == 16 else {
            throw RoomFloorPlanProjectionError.invalidSemanticBounds(element.id)
        }
        let x = transform[12]
        let z = transform[14]
        guard x.isFinite, z.isFinite else {
            throw RoomFloorPlanProjectionError.invalidSemanticBounds(element.id)
        }
        _ = try bounded(x)
        _ = try bounded(z)
        let width = max(element.dimensionsMeters.width, 0.01)
        let depth = max(element.dimensionsMeters.depth, 0.01)
        _ = try bounded(width)
        _ = try bounded(depth)
        let xAxis = RoomFloorPlanPoint(x: transform[0], y: transform[2])
        let zAxis = RoomFloorPlanPoint(x: transform[8], y: transform[10])
        guard xAxis.x.isFinite, xAxis.y.isFinite, zAxis.x.isFinite, zAxis.y.isFinite else {
            throw RoomFloorPlanProjectionError.invalidSemanticBounds(element.id)
        }
        let halfWidth = width / 2
        let halfDepth = depth / 2
        let corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { signs in
            RoomFloorPlanPoint(
                x: x + signs.0 * halfWidth * xAxis.x + signs.1 * halfDepth * zAxis.x,
                y: z + signs.0 * halfWidth * xAxis.y + signs.1 * halfDepth * zAxis.y
            )
        }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw RoomFloorPlanProjectionError.invalidSemanticBounds(element.id)
        }
        _ = try corners.map { try bounded($0.x) }
        _ = try corners.map { try bounded($0.y) }
        return RoomFloorPlanItem(
            id: element.id,
            kind: element.kind,
            label: element.label,
            center: RoomFloorPlanPoint(x: x, y: z),
            widthMeters: width,
            depthMeters: depth,
            isStructural: structural,
            corners: corners
        )
    }

    private static func bounded(_ value: Double) throws -> Double {
        guard value.isFinite, abs(value) <= maximumRenderableMeters else {
            throw RoomFloorPlanProjectionError.invalidSemanticBounds("renderable bounds")
        }
        return value
    }
}

public enum RoomFloorPlanProjectionError: Error, Sendable, Equatable {
    case invalidSemanticBounds(String)
}
