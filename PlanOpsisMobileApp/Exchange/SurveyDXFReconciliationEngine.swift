import Foundation

public struct SurveyDXFChangeProposal:Sendable {
    public var sourceFingerprint:String
    public var proposedProject:PlanOpsisProject?
    public var changes:[String]
    public var issues:[String]
    public var canApply:Bool { proposedProject != nil && issues.isEmpty }
}
public struct SurveyDXFReconciliationEngine {
    public init() {}
    public func preview(drawing:EditableDXFDrawing,baseline:SurveyExchangeManifest,current:PlanOpsisProject)->SurveyDXFChangeProposal {
        do {
            guard baseline.profileVersion==1,baseline.units=="mm",baseline.projectID==current.id,baseline.baseline.id==current.id else { throw SurveyError.invalid("Exchange manifest does not belong to this project/profile.") }
            try SurveyValidation.validate(current)
            let before=EditableDXFReader().read(baseline.originalDXF)
            guard drawing.issues.isEmpty,before.issues.isEmpty else { throw SurveyError.invalid((drawing.issues+before.issues).joined(separator:"\n")) }
            guard drawing.outlineSignature==before.outlineSignature else { throw SurveyError.invalid("Wall-face geometry changed independently of its architectural controls. Review the CAD drawing.") }
            let controls=drawing.controls+drawing.dimensions, original=before.controls+before.dimensions
            guard Set(controls.map(\.id))==Set(original.map(\.id)),controls.count==original.count,Set(controls.map(\.id)).count==controls.count else { throw SurveyError.invalid("Controls were deleted, duplicated, or lost identity metadata.") }
            var next=current,changes:[String]=[]
            func close(_ a:Double,_ b:Double)->Bool { abs(a-b)<=0.001 }
            func same(_ a:Point2D,_ b:Point2D)->Bool { close(a.x,b.x) && close(a.y,b.y) }
            // A connected junction has one destination. Validate all explicit requests
            // against baseline coordinates before endpoint propagation changes the model.
            var endpointRequests:[(origin:Point2D,destination:Point2D)]=[]
            for control in controls where control.kind=="wall" {
                guard let old=original.first(where:{$0.id==control.id}),let end=control.end,let oldEnd=old.end else { continue }
                for (origin,destination) in [(old.position,control.position),(oldEnd,end)] where !same(origin,destination) {
                    if endpointRequests.contains(where:{ ($0.origin-origin).length<=0.001 && !same($0.destination,destination) }) {
                        throw SurveyError.invalid("Connected wall endpoints request conflicting destinations. Resolve the junction in CAD before importing.")
                    }
                    endpointRequests.append((origin,destination))
                }
            }
            for control in controls.sorted(by:{ ($0.kind == "wall" ? 0:1,$0.id.uuidString) < ($1.kind == "wall" ? 0:1,$1.id.uuidString) }) {
                guard control.revisionID==baseline.revisionID,let old=original.first(where:{$0.id==control.id}),control.kind==old.kind else { throw SurveyError.invalid("Control revision or type changed.") }
                guard control.measurementSignature==old.measurementSignature else { throw SurveyError.invalid("Dimension measurement references changed; edit architectural controls instead.") }
                guard control.scale.allSatisfy({abs($0-1)<1e-9}),control.blockSignature==old.blockSignature else { throw SurveyError.invalid("Scaled/mirrored instances and edited block definitions require manual resolution.") }
                let endpointSame:Bool
                if let a=control.end,let b=old.end { endpointSame=same(a,b) } else { endpointSame=control.end==nil && old.end==nil }
                let rotated=abs(atan2(sin(control.rotation-old.rotation),cos(control.rotation-old.rotation)))>1e-7
                guard !same(control.position,old.position) || !endpointSame || rotated else { continue }
                if control.kind=="component" {
                    guard let r=next.rooms.firstIndex(where:{$0.components.contains(where:{$0.id==control.id})}),let i=next.rooms[r].components.firstIndex(where:{$0.id==control.id}),let base=baseline.baseline.rooms.first(where:{$0.id==next.rooms[r].id})?.components.first(where:{$0.id==control.id}),current.rooms[r].components[i]==base else { throw SurveyError.invalid("Component also changed in PlanOpsis.") }
                    next.rooms[r].components[i].position=control.position
                    next.rooms[r].components[i].rotationRadians=control.rotation
                } else if control.kind=="wall" {
                    guard let end=control.end,let r=next.rooms.firstIndex(where:{$0.walls.contains(where:{$0.id==control.id})}),let index=next.rooms[r].walls.firstIndex(where:{$0.id==control.id}),let baseRoom=baseline.baseline.rooms.first(where:{$0.id==next.rooms[r].id}),let base=baseRoom.walls.first(where:{$0.id==control.id}),current.rooms[r].walls[index]==base else { throw SurveyError.invalid("Wall also changed in PlanOpsis or lost its endpoint.") }
                    for (endpoint,point,oldPoint) in [(WallEndpointKind.start,control.position,old.position),(.end,end,old.end ?? old.position)] where !same(point,oldPoint) {
                        let moved=try SurveyCorrectionEngine().movingEndpoint(wallID:control.id,endpoint:endpoint,to:point,in:next)
                        for w in moved.rooms.flatMap(\.walls) {
                            if let previous=next.rooms.flatMap(\.walls).first(where:{$0.id==w.id}),previous != w,
                               let actual=current.rooms.flatMap(\.walls).first(where:{$0.id==w.id}),
                               let baselineWall=baseline.baseline.rooms.flatMap(\.walls).first(where:{$0.id==w.id}),actual != baselineWall {
                                throw SurveyError.invalid("A connected wall also changed in PlanOpsis.")
                            }
                        }
                        next=moved
                    }
                } else if control.kind=="opening" {
                    guard let r=next.rooms.firstIndex(where:{$0.openings.contains(where:{$0.id==control.id})}),let i=next.rooms[r].openings.firstIndex(where:{$0.id==control.id}),let baseRoom=baseline.baseline.rooms.first(where:{$0.id==next.rooms[r].id}),let base=baseRoom.openings.first(where:{$0.id==control.id}),current.rooms[r].openings[i]==base,let wall=next.rooms[r].walls.first(where:{$0.id==base.parameters.hostWallID}),let baseWall=baseRoom.walls.first(where:{$0.id==wall.id}),wall==baseWall,!rotated else { throw SurveyError.invalid("Opening or host changed; only movement along an unchanged host is supported.") }
                    let delta=control.position-wall.start
                    guard abs(delta.dot(wall.normal))<=0.001 else { throw SurveyError.invalid("Opening moved away from its host wall.") }
                    var opening=next.rooms[r].openings[i];let offset=delta.dot(wall.direction)
                    switch opening {
                    case .door(var d):d.parameters.offsetAlongWall=offset;opening = .door(d)
                    case .window(var w):w.parameters.offsetAlongWall=offset;opening = .window(w)
                    case .opening(var p):p.offsetAlongWall=offset;opening = .opening(p)
                    }
                    next.rooms[r].openings[i]=opening
                } else if control.kind=="dimension" {
                    guard current.survey.dimensions==baseline.baseline.survey.dimensions else { throw SurveyError.invalid("Annotations also changed in PlanOpsis.") }
                    let definition=SurveyDimensionBuilder().definitions(project:baseline.baseline).first{$0.id==control.id}
                    guard var d=definition else { throw SurveyError.invalid("Dimension reference missing.") }
                    d.textPosition=control.position
                    if let line=control.end,let resolved=SurveyDimensionBuilder().build(project:baseline.baseline).dimensions.first(where:{$0.id==control.id}) {
                        let direction=(resolved.end-resolved.start).normalized,normal=Point2D(x:direction.y,y:-direction.x)
                        d.offsetMM=(line-resolved.end).dot(normal)
                    }
                    next.survey.dimensions.removeAll{$0.id==d.id};next.survey.dimensions.append(d)
                }
                changes.append("\(control.kind) \(control.id.uuidString.prefix(8))")
            }
            try SurveyCorrectionEngine().validateChange(from:current,to:next)
            return .init(sourceFingerprint:try SurveyHash.value(current),proposedProject:next,changes:changes,issues:[])
        } catch { return .init(sourceFingerprint:(try? SurveyHash.value(current)) ?? "",proposedProject:nil,changes:[],issues:[error.localizedDescription]) }
    }
    public func apply(_ proposal:SurveyDXFChangeProposal,to current:PlanOpsisProject) throws -> PlanOpsisProject {
        guard proposal.canApply,try proposal.sourceFingerprint==SurveyHash.value(current),let next=proposal.proposedProject else { throw SurveyError.invalid("Project changed since review, or exchange has unresolved issues.") }
        try SurveyCorrectionEngine().validateChange(from:current,to:next)
        return next
    }
}
