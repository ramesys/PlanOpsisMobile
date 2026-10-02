import Foundation

/// Conservative cleanup: never merge lines belonging to different semantic objects.
public enum DXFDrawingValidator {
    public struct Result {
        public var primitives: [DXFPrimitive]
        public var issues: [DXFExportIssue]
    }
    private struct LineKey: Hashable {
        var a: Point2D; var b: Point2D; var layer: String; var weight: Double
        var objectIDs: [UUID]; var roomIDs: [UUID]; var hostIDs: [UUID]
        var ifc: ArchitecturalDraftingConvention.IFCClass?; var type: String?
    }
    public static func clean(_ input: [DXFPrimitive], tolerance: Double = 1e-6) -> Result {
        let layers = Set(ArchitecturalDraftingConvention.Layer.allCases.map(\.rawValue))
        var output: [DXFPrimitive] = [], issues: [DXFExportIssue] = []
        var lines = Set<LineKey>()
        func issue(_ severity: DXFExportIssue.Severity, _ message: String, _ id: String) { issues.append(.init(severity,"\(id): \(message)")) }
        func sorted(_ ids: [UUID]) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
        for var item in input {
            guard layers.contains(item.layer) else { issue(.error,"unregistered layer \(item.layer)",item.id); continue }
            let points = item.points + (item.center.map { [$0] } ?? [])
            let values = [item.radius,item.startAngleDegrees,item.endAngleDegrees,item.textHeight,item.rotationDegrees,item.lineWeightMM].compactMap { $0 }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), values.allSatisfy(\.isFinite) else {
                issue(.error,"non-finite geometry",item.id); continue
            }
            guard item.lineWeightMM >= 0 else { issue(.error,"negative lineweight",item.id); continue }
            switch item.kind {
            case .line:
                guard item.points.count == 2 else { issue(.error,"LINE requires two vertices",item.id); continue }
                var a = item.points[0], b = item.points[1]
                guard (b-a).length > tolerance else { issue(.warning,"removed zero/near-zero LINE",item.id); continue }
                if a.x > b.x || (a.x == b.x && a.y > b.y) { swap(&a,&b) }
                let key = LineKey(a:a,b:b,layer:item.layer,weight:item.lineWeightMM,objectIDs:sorted(item.objectIDs),roomIDs:sorted(item.roomIDs),hostIDs:sorted(item.hostIDs),ifc:item.ifcClass,type:item.semanticType)
                if !item.objectIDs.isEmpty && !lines.insert(key).inserted { issue(.warning,"removed duplicate segment with identical semantic ownership",item.id); continue }
            case .polyline:
                var cleaned: [Point2D] = []
                for p in item.points where cleaned.last.map({ (p-$0).length > tolerance }) ?? true { cleaned.append(p) }
                if item.closed, let first = cleaned.first, let last = cleaned.last, (last-first).length <= tolerance { cleaned.removeLast() }
                guard cleaned.count >= (item.closed ? 3 : 2) else { issue(.error,"malformed polyline",item.id); continue }
                if item.ifcClass == .space || item.ifcClass == .column || item.ifcClass == .beam {
                    guard item.closed else { issue(.error,"profile must be closed",item.id); continue }
                }
                if item.closed {
                    let area = cleaned.indices.reduce(0.0) { sum, i in
                        let a=cleaned[i], b=cleaned[(i+1)%cleaned.count]; return sum+a.x*b.y-b.x*a.y
                    }
                    guard abs(area) > tolerance*tolerance else { issue(.error,"degenerate closed profile",item.id); continue }
                }
                if cleaned != item.points { issue(.warning,"removed repeated polyline vertices",item.id) }
                item.points = cleaned
            case .arc:
                guard item.center != nil, let radius=item.radius, radius > tolerance, let a=item.startAngleDegrees, let b=item.endAngleDegrees,
                      abs((b-a).truncatingRemainder(dividingBy:360)) > 1e-9 else { issue(.error,"invalid ARC radius or sweep",item.id); continue }
            case .text:
                guard item.points.count == 1, item.text != nil, let h=item.textHeight, h > 0 else { issue(.error,"invalid TEXT",item.id); continue }
            }
            output.append(item)
        }
        return Result(primitives:output,issues:issues)
    }
}

public extension DXFPrimitive {
    /// Tight geometric bounds for lines/arcs/polylines; conservative nominal text metrics.
    var boundsPoints: [Point2D] {
        switch kind {
        case .line,.polyline: return points
        case .arc:
            guard let c=center,let r=radius,let a=startAngleDegrees,let b=endAngleDegrees else { return [] }
            return ArchitecturalSymbol.Geometry.arc(center:c,radius:r,start:a * .pi/180,end:b * .pi/180).boundsPoints
        case .text:
            guard let center=points.first else { return [] }
            let h=textHeight ?? ArchitecturalDraftingConvention.TextStyle.dimensionHeightMM
            let w=Double(text?.count ?? 0)*h*0.65, a=(rotationDegrees ?? 0) * .pi/180
            let d=Point2D(x:cos(a),y:sin(a))*(w/2),n=Point2D(x:-sin(a),y:cos(a))*(h/2)
            return [center-d-n,center+d-n,center+d+n,center-d+n]
        }
    }
}
