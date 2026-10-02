import Foundation

public struct PLYDXFPreviewExporter: Sendable {
    public init() {}

    public func makeDXF(result: PLYReconstructionResult) -> String {
        var out: [String] = []
        func pair(_ code: Int, _ value: String) { out.append(String(code)); out.append(value) }
        func number(_ value: Double) -> String { String(format: "%.6f", value) }

        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$INSUNITS"); pair(70, "4") // millimetres
        pair(0, "ENDSEC")
        pair(0, "SECTION"); pair(2, "ENTITIES")

        for segment in result.segments {
            pair(0, "LINE"); pair(8, "PLY_SECTION_LINES")
            pair(10, number(segment.start.x)); pair(20, number(segment.start.y)); pair(30, "0")
            pair(11, number(segment.end.x)); pair(21, number(segment.end.y)); pair(31, "0")
        }

        for wall in result.wallSeeds {
            let e = wall.endMM
            pair(0, "LINE"); pair(8, "PLY_WALL_ACCEPTED")
            pair(10, number(wall.startMM.x)); pair(20, number(wall.startMM.y)); pair(30, "0")
            pair(11, number(e.x)); pair(21, number(e.y)); pair(31, "0")
        }
        for wall in result.reviewWallSeeds {
            let e = wall.endMM
            pair(0, "LINE"); pair(8, "PLY_WALL_REVIEW")
            pair(10, number(wall.startMM.x)); pair(20, number(wall.startMM.y)); pair(30, "0")
            pair(11, number(e.x)); pair(21, number(e.y)); pair(31, "0")
        }
        for wall in result.suppressedWallSeeds {
            let e = wall.endMM
            pair(0, "LINE"); pair(8, "PLY_WALL_SUPPRESSED")
            pair(10, number(wall.startMM.x)); pair(20, number(wall.startMM.y)); pair(30, "0")
            pair(11, number(e.x)); pair(21, number(e.y)); pair(31, "0")
        }

        for structural in result.structuralSeeds {
            let d = PLYPoint2D(x: cos(structural.rotationRadians), y: sin(structural.rotationRadians))
            let n = PLYPoint2D(x: -sin(structural.rotationRadians), y: cos(structural.rotationRadians))
            let x = d * (structural.widthMM * 0.5), y = n * (structural.depthMM * 0.5)
            let corners = [structural.centerMM - x - y, structural.centerMM + x - y, structural.centerMM + x + y, structural.centerMM - x + y]
            pair(0, "LWPOLYLINE"); pair(8, structural.kind == .column ? "PLY_COLUMNS" : "PLY_BEAMS")
            pair(90, "4"); pair(70, "1")
            for point in corners { pair(10, number(point.x)); pair(20, number(point.y)) }
        }

        for structural in result.reviewStructuralSeeds + result.suppressedStructuralSeeds {
            let d = PLYPoint2D(x: cos(structural.rotationRadians), y: sin(structural.rotationRadians))
            let n = PLYPoint2D(x: -sin(structural.rotationRadians), y: cos(structural.rotationRadians))
            let x = d * (structural.widthMM * 0.5), y = n * (structural.depthMM * 0.5)
            let corners = [structural.centerMM - x - y, structural.centerMM + x - y, structural.centerMM + x + y, structural.centerMM - x + y]
            let isReview = result.reviewStructuralSeeds.contains { $0.id == structural.id }
            pair(0, "LWPOLYLINE"); pair(8, isReview ? "PLY_STRUCTURE_REVIEW" : "PLY_STRUCTURE_SUPPRESSED")
            pair(90, "4"); pair(70, "1")
            for point in corners { pair(10, number(point.x)); pair(20, number(point.y)) }
        }

        pair(0, "ENDSEC"); pair(0, "EOF")
        return out.joined(separator: "\n") + "\n"
    }
}
