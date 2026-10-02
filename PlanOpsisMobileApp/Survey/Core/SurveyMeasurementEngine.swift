import Foundation

public struct SurveyMeasurementEvaluation: Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case unchecked, withinTolerance, outsideTolerance, needsRecheck, invalidReference }
    public var currentMM:Double?
    public var residualMM:Double?
    public var status:Status
    public var diagnostic:String?
}
public struct SurveyMeasurementEngine {
    public init() {}
    public func endpoints(for target:SurveyMeasurementTarget,in project:PlanOpsisProject) throws -> (Point2D,Point2D) {
        try SurveyValidation.validate(target,in:project)
        func wall(_ r:UUID,_ id:UUID) throws -> PlanOpsisWall {
            guard let w=project.rooms.first(where:{$0.id==r})?.walls.first(where:{$0.id==id}) else { throw SurveyError.invalid("Wall missing.") }; return w
        }
        func point(_ p:SurveyPoint) throws -> Point2D {
            let w=try wall(p.roomID,p.wallID)
            switch p.location {
            case .start:return w.start
            case .end:return w.end
            case .openingEdge(let id,let side):
                guard let o=project.rooms.first(where:{$0.id==p.roomID})?.openings.first(where:{$0.id==id}) else { throw SurveyError.invalid("Opening reference missing.") }
                return w.start+w.direction*(o.parameters.offsetAlongWall+Double(side)*o.parameters.width/2)
            case .face(let station,let side):return w.start+w.direction*station+w.normal*(Double(side)*w.thickness/2)
            }
        }
        switch target {
        case .wallLength(let r,let id):let w=try wall(r,id);return (w.start,w.end)
        case .wallThickness(let r,let id):let w=try wall(r,id);let mid=w.start+w.direction*(w.length/2);return (mid-w.normal*(w.thickness/2),mid+w.normal*(w.thickness/2))
        case .openingWidth(let r,let id):
            guard let o=project.rooms.first(where:{$0.id==r})?.openings.first(where:{$0.id==id}) else { throw SurveyError.invalid("Opening missing.") }
            let w=try wall(r,o.parameters.hostWallID),p=o.parameters
            return (w.start+w.direction*(p.offsetAlongWall-p.width/2),w.start+w.direction*(p.offsetAlongWall+p.width/2))
        case .distance(let a,let b):return (try point(a),try point(b))
        case .projectedDistance(let a,let b,let axis):
            let x=try point(a),y=try point(b)
            return (x,axis == .horizontal ? Point2D(x:y.x,y:x.y):Point2D(x:x.x,y:y.y))
        }
    }
    public func fingerprint(for target:SurveyMeasurementTarget,in project:PlanOpsisProject) throws -> String {
        let (a,b)=try endpoints(for:target,in:project)
        return try SurveyHash.value([a,b])
    }
    public func evaluate(_ observation:SurveyObservation,in project:PlanOpsisProject) -> SurveyMeasurementEvaluation {
        do {
            guard observation.observedMM.isFinite,observation.observedMM>0,observation.toleranceMM.map({$0.isFinite && $0>=0}) ?? true else { throw SurveyError.invalid("Invalid measurement or tolerance.") }
            let (a,b)=try endpoints(for:observation.target,in:project), length=(b-a).length
            guard length.isFinite,length>0 else { throw SurveyError.invalid("Measurement has no finite positive length.") }
            let residual=length-observation.observedMM
            let fingerprint=try self.fingerprint(for:observation.target,in:project)
            let status:SurveyMeasurementEvaluation.Status
            if let verified=observation.verificationFingerprint {
                if verified != fingerprint { status = .needsRecheck }
                else if let tolerance=observation.toleranceMM { status=abs(residual)<=tolerance+1e-9 ? .withinTolerance : .outsideTolerance }
                else { status = .unchecked }
            } else { status = .unchecked }
            return .init(currentMM:length,residualMM:residual,status:status,diagnostic:nil)
        } catch { return .init(currentMM:nil,residualMM:nil,status:.invalidReference,diagnostic:error.localizedDescription) }
    }
}
