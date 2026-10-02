import Foundation

/// Removes wall-face portions buried inside another wall at supported L/T junctions.
/// This affects derived drawing lines only; semantic axes, hosting and IFC solids are untouched.
public enum ArchitecturalWallDrawing {
    public static func resolve(_ primitives: [DXFPrimitive], segments: [DisplayWallPlanSegment], project: PlanOpsisProject) -> [DXFPrimitive] {
        var input = primitives
        let primitiveIDs = Set(primitives.map(\.id))
        for segment in segments where segment.footprint.count == 4 {
            // Ordered closed-room miters already include their terminal boundary.
            // Fallback faces need terminal edges from their SAME resolved footprint.
            guard primitiveIDs.contains("wall-face-a:\(segment.id)") else { continue }
            for (index, pair) in [(3,0),(1,2)].enumerated() {
                let a=segment.footprint[pair.0], b=segment.footprint[pair.1]
                let hasJamb = primitives.contains { p in
                    guard p.id.hasPrefix("jamb-"), p.points.count == 2 else { return false }
                    return ((p.points[0]-a).length < 1e-6 && (p.points[1]-b).length < 1e-6) ||
                        ((p.points[1]-a).length < 1e-6 && (p.points[0]-b).length < 1e-6)
                }
                if !hasJamb {
                    input.append(DXFPrimitive(id:"wall-cap:\(segment.id):\(index)",kind:.line,layer:"A-WALL",points:[a,b],lineWeightMM:ArchitecturalDraftingConvention.lineWeightMM(for:.wall),ifcClass:.wall,objectIDs:segment.sourceWallIDs,roomIDs:segment.sourceRoomIDs))
                }
            }
        }
        func cross(_ a: Point2D,_ b: Point2D) -> Double { a.x*b.y-a.y*b.x }
        func strictlyInside(_ point: Point2D,_ polygon: [Point2D]) -> Bool {
            let crosses=polygon.indices.map { cross(polygon[($0+1)%polygon.count]-polygon[$0],point-polygon[$0]) }
            return crosses.allSatisfy { $0 > 1e-6 } || crosses.allSatisfy { $0 < -1e-6 }
        }
        return input.flatMap { line -> [DXFPrimitive] in
            guard line.ifcClass == .wall, line.kind == .line, line.points.count == 2 else { return [line] }
            let a=line.points[0], delta=line.points[1]-a
            var intervals=[(0.0,1.0)]
            for other in segments where Set(other.sourceWallIDs).isDisjoint(with:line.objectIDs) && other.footprint.count >= 3 {
                let polygon=other.footprint
                var breaks=[0.0,1.0]
                for i in polygon.indices {
                    let p=polygon[i], edge=polygon[(i+1)%polygon.count]-p
                    let determinant=cross(delta,edge)
                    if abs(determinant) <= 1e-9 {
                        if abs(cross(p-a,delta)) <= 1e-6 && delta.dot(delta) > 1e-12 {
                            for endpoint in [p,p+edge] {
                                let t=(endpoint-a).dot(delta)/delta.dot(delta)
                                if t > 0 && t < 1 { breaks.append(t) }
                            }
                        }
                        continue
                    }
                    let t=cross(p-a,edge)/determinant, u=cross(p-a,delta)/determinant
                    if t > 0 && t < 1 && u >= -1e-9 && u <= 1+1e-9 { breaks.append(t) }
                }
                breaks.sort()
                for i in 0..<(breaks.count-1) {
                    let lo=breaks[i], hi=breaks[i+1]
                    let midpoint=a+delta*((lo+hi)/2)
                    // At capped physical junctions a terminal edge can coincide with an
                    // existing longitudinal face. Keep that face, not a doubled cap.
                    let coveredCap = line.id.hasPrefix("wall-cap:") && primitiveIDs.contains("wall-face-a:\(other.id)") && [0,2].contains { edgeIndex in
                        let p=polygon[edgeIndex], edge=polygon[(edgeIndex+1)%polygon.count]-p
                        let station=(midpoint-p).dot(edge)/max(edge.dot(edge),1e-12)
                        return abs(cross(midpoint-p,edge)) < 1e-6 && station >= -1e-9 && station <= 1+1e-9
                    }
                    guard hi-lo > 1e-10, strictlyInside(midpoint,polygon) || coveredCap else { continue }
                    intervals=intervals.flatMap { span -> [(Double,Double)] in
                        if span.1 <= lo || span.0 >= hi { return [span] }
                        var kept:[(Double,Double)]=[]
                        if span.0 < lo { kept.append((span.0,lo)) }
                        if span.1 > hi { kept.append((hi,span.1)) }
                        return kept
                    }
                }
            }
            return intervals.enumerated().compactMap { index, span in
                guard (span.1-span.0)*delta.length > 1e-6 else { return nil }
                var result=line
                if span.0 != 0 || span.1 != 1 { result.id += ":junction:\(index)" }
                result.points=[a+delta*span.0,a+delta*span.1]
                return result
            }
        }
    }
}
