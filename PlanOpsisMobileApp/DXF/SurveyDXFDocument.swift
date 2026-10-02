import Foundation

struct SurveyDXFTag: Codable, Hashable, Sendable { var code:Int; var value:String }
struct SurveyDXFRecord: Codable, Hashable, Sendable {
    var tags:[SurveyDXFTag]
    var type:String { string(0) ?? "" }
    func string(_ code:Int)->String? { tags.first{$0.code==code}?.value }
    func number(_ code:Int,_ fallback:Double=0)->Double { string(code).flatMap(Double.init) ?? fallback }
    mutating func set(_ code:Int,_ value:String) {
        if let i=tags.firstIndex(where:{$0.code==code}) { tags[i].value=value } else { tags.append(.init(code:code,value:value)) }
    }
    static func make(_ values:[(Int,String)])->Self { .init(tags:values.map{.init(code:$0.0,value:$0.1)}) }
    var text:String { tags.flatMap{[String($0.code),$0.value]}.joined(separator:"\r\n")+"\r\n" }
}
struct SurveyDXFDocument {
    var records:[SurveyDXFRecord]
    init(_ text:String) throws {
        var lines=text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").components(separatedBy:"\n")
        while lines.last=="" { lines.removeLast() }
        guard lines.count%2==0 else { throw SurveyError.invalid("Incomplete DXF group pair.") }
        var tags:[SurveyDXFTag]=[];records=[]
        for i in stride(from:0,to:lines.count,by:2) {
            guard let code=Int(lines[i].trimmingCharacters(in:.whitespaces)) else { throw SurveyError.invalid("Invalid DXF group code.") }
            if code==0 && !tags.isEmpty { records.append(.init(tags:tags));tags=[] }
            tags.append(.init(code:code,value:lines[i+1].trimmingCharacters(in:.whitespaces)))
        }
        if !tags.isEmpty { records.append(.init(tags:tags)) }
        guard records.last?.type=="EOF" else { throw SurveyError.invalid("DXF EOF is missing.") }
    }
    var text:String { records.map(\.text).joined() }
    func indices(in section:String)->[Int] {
        var active=false,result:[Int]=[]
        for (i,r) in records.enumerated() {
            if r.type=="SECTION" { active=r.string(2)==section;continue }
            if r.type=="ENDSEC" { active=false }
            else if active { result.append(i) }
        }
        return result
    }
    mutating func append(_ values:[SurveyDXFRecord],toSection section:String) throws {
        guard let start=records.firstIndex(where:{$0.type=="SECTION" && $0.string(2)==section}),let end=records[start...].firstIndex(where:{$0.type=="ENDSEC"}) else { throw SurveyError.invalid("Missing \(section) section.") }
        records.insert(contentsOf:values,at:end)
    }
    mutating func append(_ values:[SurveyDXFRecord],toTable table:String) throws {
        guard let start=records.firstIndex(where:{$0.type=="TABLE" && $0.string(2)==table}),let end=records[start...].firstIndex(where:{$0.type=="ENDTAB"}) else { throw SurveyError.invalid("Missing \(table) table.") }
        records[start].set(70,String(Int(records[start].number(70))+values.count))
        records.insert(contentsOf:values,at:end)
    }
}
func surveyDXFNumber(_ n:Double)->String { String(format:"%.6f",locale:Locale(identifier:"en_US_POSIX"),n) }
