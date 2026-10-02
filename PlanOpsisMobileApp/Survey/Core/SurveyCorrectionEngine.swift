import Foundation

public struct SurveyCorrectionProposal: Sendable {
    public var sourceFingerprint:String
    public var proposedProject:PlanOpsisProject?
    public var issues:[String]
    public var canApply:Bool { proposedProject != nil && issues.isEmpty }
}
public struct SurveyCorrectionEngine {
    public init() {}
    public func preview(observationID:UUID,anchor:WallEndpointKind?,project:PlanOpsisProject) -> SurveyCorrectionProposal {
        do {
            try SurveyValidation.validate(project)
            guard let o=project.survey.observations.first(where:{$0.id==observationID}) else { throw SurveyError.invalid("Measurement missing.") }
            var next=project
            switch o.target {
            case .wallLength(let rid,let wid):
                guard let r=next.rooms.firstIndex(where:{$0.id==rid}),let w=next.rooms[r].walls.first(where:{$0.id==wid}),let anchor else { throw SurveyError.invalid("Choose the fixed wall endpoint.") }
                let moving:WallEndpointKind=anchor == .start ? .end : .start
                let point=anchor == .start ? w.start+w.direction*o.observedMM : w.end-w.direction*o.observedMM
                next=try movingEndpoint(wallID:wid,endpoint:moving,to:point,in:next)
            case .wallThickness(let rid,let wid):
                guard let r=next.rooms.firstIndex(where:{$0.id==rid}),let w=next.rooms[r].walls.firstIndex(where:{$0.id==wid}) else { throw SurveyError.invalid("Wall missing.") }
                next.rooms[r].walls[w].thickness=o.observedMM
            case .openingWidth(let rid,let oid):
                guard let r=next.rooms.firstIndex(where:{$0.id==rid}),let i=next.rooms[r].openings.firstIndex(where:{$0.id==oid}) else { throw SurveyError.invalid("Opening missing.") }
                var opening=next.rooms[r].openings[i]
                switch opening {
                case .door(var d):d.parameters.width=o.observedMM;opening = .door(d)
                case .window(var w):w.parameters.width=o.observedMM;opening = .window(w)
                case .opening(var p):p.width=o.observedMM;opening = .opening(p)
                }
                next.rooms[r].openings[i]=opening
            case .distance,.projectedDistance:throw SurveyError.invalid("Face distances and diagonals are check measurements; correct their defining walls explicitly.")
            }
            try validateChange(from:project,to:next)
            return .init(sourceFingerprint:try SurveyHash.value(project),proposedProject:next,issues:[])
        } catch { return .init(sourceFingerprint:(try? SurveyHash.value(project)) ?? "",proposedProject:nil,issues:[error.localizedDescription]) }
    }
    public func movingEndpoint(wallID:UUID,endpoint:WallEndpointKind,to point:Point2D,in project:PlanOpsisProject) throws -> PlanOpsisProject {
        var settings=PlanEditingSettings();settings.connectedEndpointTolerance=0.001
        guard let result=PlanEditingConstraintEngine().moveEndpoint(wallID:wallID,endpoint:endpoint,proposed:point,in:project.rooms.flatMap(\.walls),settings:settings,applyConstraints:false) else { throw SurveyError.invalid("Wall endpoint could not be moved.") }
        let walls=Dictionary(uniqueKeysWithValues:result.walls.map{($0.id,$0)})
        var next=project
        for r in next.rooms.indices { next.rooms[r].walls=next.rooms[r].walls.map{walls[$0.id] ?? $0} }
        return next
    }
    public func validateChange(from original:PlanOpsisProject,to next:PlanOpsisProject) throws {
        try SurveyValidation.validate(next)
        let errors=ExchangeGeometryValidation.errors(in:next)
        guard errors.isEmpty else { throw SurveyError.invalid(errors.joined(separator:"\n")) }
        let oldTopology=ParametricGeometryEngine().generate(from:original).topology
        let newTopology=ParametricGeometryEngine().generate(from:next).topology
        for boundary in oldTopology.sharedBoundaries where boundary.strength == .strong {
            guard newTopology.sharedBoundaries.contains(where:{$0.id==boundary.id && $0.strength == .strong}) else { throw SurveyError.invalid("Correction would separate an established shared boundary. Review both room observations.") }
        }
        let old=oldTopology.roomBoundaries,new=newTopology.roomBoundaries
        for boundary in old where boundary.isClosed {
            guard new.contains(where:{$0.roomID==boundary.roomID && $0.isClosed}) else { throw SurveyError.invalid("Correction would open a closed room boundary.") }
        }
        for check in original.survey.observations where check.locked {
            let evaluated=SurveyMeasurementEngine().evaluate(check,in:next)
            guard let residual=evaluated.residualMM,let tolerance=check.toleranceMM,abs(residual)<=tolerance+1e-9 else { throw SurveyError.invalid("Correction conflicts with a locked measured check.") }
        }
    }
    public func apply(_ proposal:SurveyCorrectionProposal,to project:PlanOpsisProject) throws -> PlanOpsisProject {
        guard proposal.canApply,try proposal.sourceFingerprint==SurveyHash.value(project),let next=proposal.proposedProject else { throw SurveyError.invalid("Correction is invalid or the project changed. Preview it again.") }
        try validateChange(from:project,to:next)
        return next
    }
}
