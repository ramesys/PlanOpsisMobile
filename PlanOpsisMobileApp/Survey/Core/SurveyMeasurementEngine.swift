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
        case .wallFaceLength(let r,let id,let side):
            guard let room=project.rooms.first(where:{$0.id==r}) else { throw SurveyError.invalid("Room missing.") }
            return try faceSegment(wallID:id,side:side,in:room)
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
    /// v12.2: the end points of one wall face as a surveyor would tape it. At an L-corner the face meets the
    /// matching face of the connected wall (inside with inside, outside with outside); at a T-junction both
    /// faces stop at the through wall's face; free ends and straight continuations are not trimmed.
    public func faceSegment(wallID:UUID,side:Int,in room:PlanOpsisRoom) throws -> (Point2D,Point2D) {
        guard let w=room.walls.first(where:{$0.id==wallID}),side == -1 || side == 1 else { throw SurveyError.invalid("Wall face missing.") }
        let offset=w.normal*(Double(side)*w.thickness/2)
        var ends=[w.start+offset,w.end+offset]
        let tolerance=GeometryTolerances.coincidenceMM
        let minimumSine=sin(5*Double.pi/180)
        func cross(_ a:Point2D,_ b:Point2D)->Double { a.x*b.y-a.y*b.x }
        func intersect(_ p:Point2D,_ d:Point2D,_ q:Point2D,_ e:Point2D)->Point2D? {
            let den=cross(d,e)
            guard abs(den)>1e-9 else { return nil }
            let t=cross(q-p,e)/den
            return p+d*t
        }
        for (index,endpoint) in [w.start,w.end].enumerated() {
            let intoBody=index == 0 ? w.direction : w.direction * -1
            let others=room.walls.filter { $0.id != w.id }
            let atEnd=others.filter { min(($0.start-endpoint).length,($0.end-endpoint).length) <= tolerance }
            var neighbour:PlanOpsisWall?
            var neighbourSide:Double?
            if atEnd.count == 1, let n=atEnd.first, abs(cross(w.direction,n.direction)) > minimumSine {
                // L-corner: match faces whose offsets point to the same side of the corner.
                let nIntoBody=(n.start-endpoint).length <= (n.end-endpoint).length ? n.direction : n.direction * -1
                let ours=offset.dot(nIntoBody)
                let theirs=n.normal.dot(intoBody)
                if abs(ours) > 1e-9, abs(theirs) > 1e-9 { neighbour=n; neighbourSide=(ours*theirs) > 0 ? 1 : -1 }
            } else if atEnd.isEmpty {
                // T-junction: this end touches the interior of a through wall; stop at its near face.
                if let n=others.first(where:{ n in
                    let t=(endpoint-n.start).dot(n.direction)
                    return t > tolerance && t < n.length-tolerance && abs((endpoint-n.start).dot(n.normal)) <= tolerance && abs(cross(w.direction,n.direction)) > minimumSine
                }) {
                    neighbour=n; neighbourSide=n.normal.dot(intoBody) >= 0 ? 1 : -1
                }
            }
            if let n=neighbour,let s=neighbourSide,
               let point=intersect(ends[index],w.direction,n.start+n.normal*(s*n.thickness/2),n.direction) {
                ends[index]=point
            }
        }
        return (ends[0],ends[1])
    }

    /// v12.2: the side (+1/-1 along the wall normal) facing into the room, from the room outline when it is
    /// closed, otherwise from the centre of the room's walls. Nil when it cannot be decided.
    public func roomSide(ofWall wallID:UUID,in room:PlanOpsisRoom) -> Int? {
        guard let w=room.walls.first(where:{$0.id==wallID}) else { return nil }
        let mid=w.center,probe=w.thickness/2+50
        let topology=StructureTopologyEngine().generate(from:PlanOpsisProject(rooms:[room]))
        let outline=ArchitecturalRoomEnvelope.polygon(for:room,topology:topology)
        if outline.count >= 3 {
            let plus=PlanPolygon.contains(mid+w.normal*probe,in:outline),minus=PlanPolygon.contains(mid-w.normal*probe,in:outline)
            if plus != minus { return plus ? 1 : -1 }
        }
        let others=room.walls.filter{$0.id != w.id}
        guard !others.isEmpty else { return nil }
        let centre=others.map(\.center).reduce(.zero,+)*(1/Double(others.count))
        let side=(centre-mid).dot(w.normal)
        return abs(side) > 1e-6 ? (side > 0 ? 1 : -1) : nil
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
