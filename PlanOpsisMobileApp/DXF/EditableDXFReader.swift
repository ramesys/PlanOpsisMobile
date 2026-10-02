import Foundation

public struct SurveyDXFControl:Codable,Hashable,Sendable,Identifiable {
    public var id:UUID
    public var kind:String
    public var revisionID:UUID
    public var position:Point2D
    public var end:Point2D?
    public var rotation:Double
    public var scale:[Double]
    public var blockSignature:String?
    public var measurementSignature:String? = nil
}
public struct EditableDXFDrawing:Sendable {
    public var controls:[SurveyDXFControl]=[]
    public var dimensions:[SurveyDXFControl]=[]
    public var units:Int=0
    public var outlineSignature=""
    public var issues:[String]=[]
}
public struct EditableDXFReader {
    public init() {}
    public func read(_ text:String)->EditableDXFDrawing {
        var result=EditableDXFDrawing()
        do {
            let doc=try SurveyDXFDocument(text)
            let header=doc.records.first{$0.type=="SECTION" && $0.string(2)=="HEADER"}
            if let tags=header?.tags,let i=tags.firstIndex(where:{$0.code==9 && $0.value=="$INSUNITS"}),i+1<tags.count { result.units=Int(tags[i+1].value) ?? 0 }
            var blockName:String?,blocks:[String:[SurveyDXFRecord]]=[:],blockHeaders:[String:SurveyDXFRecord]=[:]
            for i in doc.indices(in:"BLOCKS") {
                let r=doc.records[i]
                if r.type=="BLOCK" {
                    blockName=r.string(2)
                    if let n=blockName {
                        guard blocks[n]==nil else { throw SurveyError.invalid("Duplicate block definition.") }
                        blocks[n]=[];blockHeaders[n]=r
                    }
                }
                else if r.type=="ENDBLK" { blockName=nil }
                else if let n=blockName { blocks[n,default:[]].append(r) }
            }
            var outlines:[String]=[],seen=Set<UUID>()
            let regex=try NSRegularExpression(pattern:"PO12:([a-z]+):([0-9A-Fa-f-]{36}):([0-9A-Fa-f-]{36})")
            for i in doc.indices(in:"ENTITIES") {
                let r=doc.records[i]
                for t in r.tags where (10...59).contains(t.code) {
                    guard let n=Double(t.value),n.isFinite else { throw SurveyError.invalid("Nonfinite DXF geometry.") }
                }
                if r.string(8)=="A-WALL" { outlines.append(signature(r)) }
                let metadata=r.tags.filter{$0.code>=1000}.map(\.value).joined(separator:" ")
                let matches=regex.matches(in:metadata,range:NSRange(metadata.startIndex...,in:metadata))
                guard let match=matches.first else { continue }
                guard matches.count==1 else { throw SurveyError.invalid("Ambiguous control identity.") }
                func part(_ i:Int)->String { String(metadata[Range(match.range(at:i),in:metadata)!]) }
                guard let id=UUID(uuidString:part(2)),let revision=UUID(uuidString:part(3)),seen.insert(id).inserted else { throw SurveyError.invalid("Duplicate or invalid control ID.") }
                let kind=part(1),p=Point2D(x:r.number(10),y:r.number(20))
                var control=SurveyDXFControl(id:id,kind:kind,revisionID:revision,position:p,end:nil,rotation:r.number(50)*Double.pi/180,scale:[r.number(41,1),r.number(42,1),r.number(43,1)],blockSignature:nil)
                if kind=="wall" {
                    if r.type=="LINE" { control.end=Point2D(x:r.number(11),y:r.number(21)) }
                    else if r.type=="LWPOLYLINE" {
                        let xs=r.tags.filter{$0.code==10}.compactMap{Double($0.value)},ys=r.tags.filter{$0.code==20}.compactMap{Double($0.value)}
                        guard xs.count==2,ys.count==2,r.number(70)==0,r.tags.filter({$0.code==42}).allSatisfy({Double($0.value)==0}) else { throw SurveyError.invalid("Wall control must be one open straight segment.") }
                        control.end=Point2D(x:xs[1],y:ys[1])
                    } else { throw SurveyError.invalid("Unsupported wall control entity.") }
                    guard r.number(30)==0,r.number(31)==0,r.number(38)==0,r.number(39)==0,r.number(210)==0,r.number(220)==0,r.number(230,1)==1 else { throw SurveyError.invalid("Wall controls must remain in the plan plane.") }
                    control.scale=[1,1,1];control.rotation=0
                } else if kind=="component" || kind=="opening" {
                    guard r.type=="INSERT",let name=r.string(2),let content=blocks[name],!content.isEmpty else { throw SurveyError.invalid("Missing symbol block definition.") }
                    guard r.number(30)==0,r.number(210)==0,r.number(220)==0,r.number(230,1)==1 else { throw SurveyError.invalid("Symbol transform left the plan plane.") }
                    guard let header=blockHeaders[name],[10,20,30].allSatisfy({header.number($0)==0}) else { throw SurveyError.invalid("Symbol block base point changed.") }
                    control.blockSignature=SurveyHash.data(Data(try normalized(content).map(signature).sorted().joined(separator:"\n").utf8))
                } else if kind=="dimension" {
                    guard r.type=="DIMENSION" else { throw SurveyError.invalid("Dimension was exploded or changed to unsupported geometry.") }
                    if let label=r.string(1),!label.isEmpty,label != "<>" {
                        let delta=Point2D(x:r.number(14)-r.number(13),y:r.number(24)-r.number(23))
                        let angle=r.number(50)*Double.pi/180
                        let measured=Int(r.number(70)) & 7 == 1 ? delta.length : abs(delta.dot(Point2D(x:cos(angle),y:sin(angle))))
                        let style=doc.records.first{$0.type=="DIMSTYLE" && $0.string(2)==r.string(3)}
                        let precision=Int(r.number(271,style?.number(271,0) ?? 0))
                        guard (0...6).contains(precision),let numeric=Double(label),abs(numeric-measured)<=0.5*pow(10,-Double(precision))+0.000001 else { throw SurveyError.invalid("Dimension label does not match measured geometry.") }
                    }
                    control.measurementSignature=[13,23,33,14,24,34,50].map{String(format:"%.3f",locale:Locale(identifier:"en_US_POSIX"),abs(r.number($0))<0.0005 ? 0:r.number($0))}.joined(separator:":")
                    control.position=Point2D(x:r.number(11),y:r.number(21))
                    control.end=Point2D(x:r.number(10),y:r.number(20));control.scale=[1,1,1]
                } else { throw SurveyError.invalid("Unknown survey control kind.") }
                if kind=="dimension" { result.dimensions.append(control) } else { result.controls.append(control) }
            }
            result.outlineSignature=SurveyHash.data(Data(outlines.sorted().joined(separator:"\n").utf8))
            if result.units != 4 { result.issues.append("Drawing units must be explicitly millimetres.") }
            if result.controls.isEmpty { result.issues.append("No preserved PlanOpsis survey controls were found.") }
        } catch { result.issues.append(error.localizedDescription) }
        return result
    }
    // Rhino's default scheme writes legacy POLYLINE/VERTEX sequences for planar outlines.
    // Normalize their representation, while retaining bulges and elevation in the signature.
    private func normalized(_ records:[SurveyDXFRecord]) throws -> [SurveyDXFRecord] {
        var result:[SurveyDXFRecord]=[],pending:SurveyDXFRecord?
        for r in records {
            if r.type=="POLYLINE" {
                guard pending==nil,Int(r.number(70)) & ~1 == 0 else { throw SurveyError.invalid("Unsupported block polyline.") }
                pending = .make([(0,"LWPOLYLINE"),(70,String(Int(r.number(70)))),(38,surveyDXFNumber(r.number(30)))])
            } else if r.type=="VERTEX" {
                guard pending != nil,r.number(30)==0 else { throw SurveyError.invalid("Invalid block polyline vertex.") }
                pending!.tags += [.init(code:10,value:surveyDXFNumber(r.number(10))),.init(code:20,value:surveyDXFNumber(r.number(20))),.init(code:42,value:surveyDXFNumber(r.number(42)))]
            } else if r.type=="SEQEND" {
                guard let poly=pending else { throw SurveyError.invalid("Invalid block sequence.") }
                result.append(poly);pending=nil
            } else {
                guard pending==nil else { throw SurveyError.invalid("Unterminated block polyline.") }
                result.append(r)
            }
        }
        guard pending==nil else { throw SurveyError.invalid("Unterminated block polyline.") }
        return result
    }
    private func signature(_ r:SurveyDXFRecord)->String {
        let xs=r.tags.filter{$0.code==10}.compactMap{Double($0.value)},ys=r.tags.filter{$0.code==20}.compactMap{Double($0.value)}
        func p(_ x:Double,_ y:Double)->String { String(format:"%.3f,%.3f",locale:Locale(identifier:"en_US_POSIX"),abs(x)<0.0005 ? 0:x,abs(y)<0.0005 ? 0:y) }
        if r.type=="LINE" { return "segment:"+[p(r.number(10),r.number(20)),p(r.number(11),r.number(21))].sorted().joined(separator:";") }
        if r.type=="LWPOLYLINE",xs.count==2,ys.count==2,r.number(70)==0 { return "segment:"+[p(xs[0],ys[0]),p(xs[1],ys[1])].sorted().joined(separator:";") }
        if r.type=="LWPOLYLINE",xs.count==ys.count {
            let bulges=r.tags.filter{$0.code==42}.compactMap{Double($0.value)}
            let vertices=zip(xs,ys).enumerated().map { i,xy in p(xy.0,xy.1)+":"+surveyDXFNumber(i<bulges.count ? bulges[i]:0) }
            return "poly:\(Int(r.number(70))):\(surveyDXFNumber(r.number(38))):"+vertices.joined(separator:";")
        }
        if r.type=="ARC" {
            func angle(_ code:Int)->String { let v=r.number(code).truncatingRemainder(dividingBy:360);return surveyDXFNumber(v<0 ? v+360:v) }
            return "arc:"+p(r.number(10),r.number(20))+":"+surveyDXFNumber(r.number(40))+":"+angle(50)+":"+angle(51)+":"+surveyDXFNumber(r.number(30))
        }
        let geometry=r.tags.filter{(10...59).contains($0.code) || $0.code==70 || $0.code==1}.map { t in
            "\(t.code):"+(Double(t.value).map{surveyDXFNumber($0)} ?? t.value)
        }
        return r.type+":"+geometry.joined(separator:";")
    }
}
