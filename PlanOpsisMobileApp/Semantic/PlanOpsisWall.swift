import Foundation

public struct PlanOpsisWall: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceRoomPlanID: UUID?

    /// PlanOpsis plan-space origin in millimetres.
    public var start: Point2D
    /// Canonical wall length in millimetres.
    public var length: Double
    /// Canonical plan angle in radians.
    public var angleRadians: Double
    /// Wall height in millimetres.
    public var height: Double
    /// Wall thickness in millimetres.
    public var thickness: Double
    public var confidence: CaptureConfidence
    /// v12.2 which side of the wall (+1/-1 along `normal`) faces its room, when the capture observed it.
    /// Survives move, rotate and mirror (mirroring also reverses the axis); nil for drawn walls.
    public var roomSide: Int?

    public init(
        id: UUID = UUID(),
        sourceRoomPlanID: UUID? = nil,
        start: Point2D,
        length: Double,
        angleRadians: Double,
        height: Double,
        thickness: Double,
        confidence: CaptureConfidence = .unknown,
        roomSide: Int? = nil
    ) {
        self.id = id
        self.sourceRoomPlanID = sourceRoomPlanID
        self.start = start
        self.length = max(0, length)
        self.angleRadians = angleRadians
        self.height = max(0, height)
        self.thickness = max(0, thickness)
        self.confidence = confidence
        self.roomSide = roomSide
    }

    public var direction: Point2D {
        Point2D(x: cos(angleRadians), y: sin(angleRadians))
    }

    public var normal: Point2D {
        Point2D(x: -sin(angleRadians), y: cos(angleRadians))
    }

    public var end: Point2D {
        start + direction * length
    }

    public var center: Point2D {
        start + direction * (length * 0.5)
    }

    public var footprint: [Point2D] {
        let half = thickness * 0.5
        let n = normal * half
        return [start + n, end + n, end - n, start - n]
    }

    public mutating func editStart(_ point: Point2D) {
        start = point
    }

    /// Moves the start endpoint while preserving the current derived end point.
    /// This is used by direct-manipulation grips so the wall visibly behaves as a
    /// two-endpoint parametric segment rather than translating as a rigid object.
    public mutating func editStartKeepingEnd(_ newStart: Point2D) {
        let fixedEnd = end
        start = newStart
        let vector = fixedEnd - newStart
        length = vector.length
        if length > 1e-9 {
            angleRadians = atan2(vector.y, vector.x)
        }
    }

    public mutating func editLength(_ newLength: Double) {
        length = max(0, newLength)
    }

    public mutating func editAngleRadians(_ newAngle: Double) {
        angleRadians = newAngle
    }

    public mutating func editEnd(_ newEnd: Point2D) {
        let vector = newEnd - start
        let newLength = vector.length
        length = newLength
        if newLength > 1e-9 {
            angleRadians = atan2(vector.y, vector.x)
        }
    }

    public mutating func editHeight(_ newHeight: Double) {
        height = max(0, newHeight)
    }

    public mutating func editThickness(_ newThickness: Double) {
        thickness = max(0, newThickness)
    }
}
