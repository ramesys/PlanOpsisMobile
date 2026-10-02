import Foundation

public struct SurveyResolvedDimension: Codable, Hashable, Sendable, Identifiable {
    public var id:UUID
    public var entityID:UUID?
    public var kind:String
    public var start:Point2D
    public var end:Point2D
    public var dimensionStart:Point2D
    public var dimensionEnd:Point2D
    public var textPosition:Point2D
    public var valueMM:Double { (end-start).length }
}
public struct SurveyDimensionSnapshot: Sendable {
    public var dimensions:[SurveyResolvedDimension]
    public var issues:[String]
}
public struct SurveyDimensionBuilder {
    public init() {}
    public func definitions(project:PlanOpsisProject)->[SurveyDimensionDefinition] {
        var definitions:[SurveyDimensionDefinition]=[],generatedIDs=Set<UUID>()
        var seenBoundaries=Set<String>()
        func pointKey(_ p:Point2D)->String { String(format:"%.3f,%.3f",locale:Locale(identifier:"en_US_POSIX"),p.x,p.y) }
        func add(_ target:SurveyMeasurementTarget,_ id:UUID,_ offset:Double,_ visible:Bool=true) {
            generatedIDs.insert(id)
            guard visible else { return }
            let override=project.survey.dimensions.first{$0.id==id || $0.target==target}
            definitions.append(override ?? .init(id:id,target:target,offsetMM:offset))
        }
        for room in project.rooms {
            for wall in room.walls {
                let key=[pointKey(wall.start),pointKey(wall.end)].sorted().joined(separator:";")
                guard seenBoundaries.insert(key).inserted else { continue }
                let target=SurveyMeasurementTarget.wallLength(roomID:room.id,wallID:wall.id)
                add(target,PlanOpsisExchangeIdentity.derivedUUID(namespace:wall.id,role:"survey.dimension"),350+wall.thickness/2)
                let openings=room.openings.filter{$0.parameters.hostWallID==wall.id}.sorted{$0.parameters.offsetAlongWall<$1.parameters.offsetAlongWall}
                if !openings.isEmpty {
                    var refs:[(String,SurveyPoint)]=[("start",.init(roomID:room.id,wallID:wall.id,location:.start))]
                    for o in openings {
                        for side in [-1,1] { refs.append(("\(o.id):\(side)",.init(roomID:room.id,wallID:wall.id,location:.openingEdge(openingID:o.id,side:side)))) }
                    }
                    refs.append(("end",.init(roomID:room.id,wallID:wall.id,location:.end)))
                    for i in 1..<refs.count {
                        let id=PlanOpsisExchangeIdentity.derivedUUID(namespace:wall.id,role:"survey.chain:\(refs[i-1].0):\(refs[i].0)")
                        add(.distance(from:refs[i-1].1,to:refs[i].1),id,700+wall.thickness/2,project.survey.settings.showChains)
                    }
                }
            }
            do {
                for opening in room.openings {
                    add(.openingWidth(roomID:room.id,openingID:opening.id),PlanOpsisExchangeIdentity.derivedUUID(namespace:opening.id,role:"survey.dimension"),800,project.survey.settings.showOpeningWidths && !project.survey.settings.showChains)
                }
            }
            if !room.walls.isEmpty {
                let points=room.walls.flatMap { w in [(w.start,SurveyPoint(roomID:room.id,wallID:w.id,location:.start)),(w.end,SurveyPoint(roomID:room.id,wallID:w.id,location:.end))] }
                for axis in [SurveyProjectionAxis.horizontal,.vertical] {
                    let sorted=points.sorted { a,b in
                        let av=axis == .horizontal ? a.0.x:a.0.y,bv=axis == .horizontal ? b.0.x:b.0.y
                        return av==bv ? a.1.wallID.uuidString<b.1.wallID.uuidString : av<bv
                    }
                    if let a=sorted.first,let b=sorted.last {
                        add(.projectedDistance(from:a.1,to:b.1,axis:axis),PlanOpsisExchangeIdentity.derivedUUID(namespace:room.id,role:"survey.overall."+axis.rawValue),1200,project.survey.settings.showOverall)
                    }
                }
            }
        }
        // Retain hidden overrides in the project so re-enabling a category restores placement.
        definitions += project.survey.dimensions.filter { d in
            !generatedIDs.contains(d.id) && !definitions.contains(where:{$0.id==d.id})
        }
        return definitions
    }
    public func build(project:PlanOpsisProject) -> SurveyDimensionSnapshot {
        let definitions=definitions(project:project),engine=SurveyMeasurementEngine()
        var result:[SurveyResolvedDimension]=[],issues:[String]=[]
        for d in definitions {
            do {
                let (a,b)=try engine.endpoints(for:d.target,in:project), delta=b-a
                guard delta.length>1e-9,d.offsetMM.isFinite else { throw SurveyError.invalid("Invalid dimension geometry.") }
                let normal=Point2D(x:delta.normalized.y,y:-delta.normalized.x)
                let x=a+normal*d.offsetMM,y=b+normal*d.offsetMM
                let kind:String
                switch d.target { case .wallLength:kind="wall";case .openingWidth:kind="opening";case .wallThickness:kind="thickness";case .distance(let a,let b):
                    let hasOpening:Bool
                    if case .openingEdge=a.location { hasOpening=true } else if case .openingEdge=b.location { hasOpening=true } else { hasOpening=false }
                    kind=hasOpening ? "chain":"check"
                case .projectedDistance:kind="overall" }
                result.append(.init(id:d.id,entityID:d.target.entityIDs.first,kind:kind,start:a,end:b,dimensionStart:x,dimensionEnd:y,textPosition:d.textPosition ?? ((x+y)*0.5)))
            } catch { issues.append("\(d.id): \(error.localizedDescription)") }
        }
        return .init(dimensions:result,issues:issues)
    }
    public func planPrimitives(snapshot:SurveyDimensionSnapshot,settings:SurveyDrawingSettings) -> [DXFPrimitive] {
        guard settings.showDimensions else { return [] }
        return snapshot.dimensions.flatMap { d -> [DXFPrimitive] in
            let id=d.id.uuidString, layer=ArchitecturalDraftingConvention.Layer.dimensions.rawValue
            let angle=atan2(d.end.y-d.start.y,d.end.x-d.start.x)*180/Double.pi
            let rotation=angle>90 ? angle-180 : (angle < -90 ? angle+180 : angle)
            let direction=(d.dimensionEnd-d.dimensionStart).normalized
            let tick=(direction+Point2D(x:-direction.y,y:direction.x))*settings.modelTextHeightMM*0.18
            return [
                DXFPrimitive(id:"survey-dim:\(id):tick-a",kind:.line,layer:layer,points:[d.dimensionStart-tick,d.dimensionStart+tick],lineWeightMM:0.18),
                DXFPrimitive(id:"survey-dim:\(id):tick-b",kind:.line,layer:layer,points:[d.dimensionEnd-tick,d.dimensionEnd+tick],lineWeightMM:0.18),
                DXFPrimitive(id:"survey-dim:\(id):line",kind:.line,layer:layer,points:[d.dimensionStart,d.dimensionEnd],lineWeightMM:0.13),
                DXFPrimitive(id:"survey-dim:\(id):a",kind:.line,layer:layer,points:[d.start,d.dimensionStart],lineWeightMM:0.13),
                DXFPrimitive(id:"survey-dim:\(id):b",kind:.line,layer:layer,points:[d.end,d.dimensionEnd],lineWeightMM:0.13),
                DXFPrimitive(id:"survey-dim:\(id):text",kind:.text,layer:layer,points:[d.textPosition],text:String(format:"%.*f",locale:Locale(identifier:"en_US_POSIX"),settings.precision,d.valueMM),textHeight:settings.modelTextHeightMM,rotationDegrees:rotation,lineWeightMM:0.13)
            ]
        }
    }
}
