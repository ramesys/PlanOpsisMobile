import Foundation

public struct EditableDXFWriter {
    public init() {}
    /// - Parameter layerNaming: v12.3 DXF layer names; symbol geometry inside blocks keeps its own layer
    ///   (e.g. IfcDoor) instead of layer 0, so exploding a block in Rhino keeps it classified.
    public func export(project:PlanOpsisProject,dimensions:SurveyDimensionSnapshot,revisionID:UUID,layerNaming:DXFLayerNaming = .ifcClass)->SurveyDXFExport {
        typealias Layer=ArchitecturalDraftingConvention.Layer
        let dimensionLayer=Layer.dimensions.dxfName(layerNaming),wallAxisLayer=Layer.wallCenter.dxfName(layerNaming)
        var manifest=SurveyExchangeManifest(projectID:project.id,revisionID:revisionID,baseline:project,originalDXF:"")
        do {
            try SurveyValidation.validate(project)
            guard dimensions.issues.isEmpty else { throw SurveyError.invalid(dimensions.issues.joined(separator:"\n")) }
            let base=DXFExchangeEngine(surveyDrawing:true,layerNaming:layerNaming).exportValidated(project:project,representation:.semanticObservations)
            guard base.canWrite else { throw SurveyError.invalid(base.issues.map(\.message).joined(separator:"\n")) }
            var doc=try SurveyDXFDocument(base.text)
            var counter=0x1000000
            func handle()->String { defer{counter += 1};return String(counter,radix:16).uppercased() }
            let model=doc.records.first{$0.type=="BLOCK_RECORD" && $0.string(2)=="*Model_Space"}?.string(5) ?? "0"
            let blockTable=doc.records.first{$0.type=="TABLE" && $0.string(2)=="BLOCK_RECORD"}?.string(5) ?? "0"
            let style=doc.records.first{$0.type=="STYLE"}?.string(5) ?? "0"
            func entity(_ type:String,_ layer:String,_ owner:String)->[(Int,String)] {
                [(0,type),(5,handle()),(330,owner),(100,"AcDbEntity"),(8,layer)]
            }
            func mark(_ kind:String,_ id:UUID)->[SurveyDXFTag] {
                [.init(code:1001,value:"Rhino"),.init(code:1002,value:"{"),.init(code:1000,value:"PlanOpsisControl"),.init(code:1000,value:"PO12:\(kind):\(id.uuidString):\(revisionID.uuidString)"),.init(code:1002,value:"}")]
            }
            try doc.append([.make([(0,"APPID"),(5,handle()),(100,"AcDbSymbolTableRecord"),(100,"AcDbRegAppTableRecord"),(2,"Rhino"),(70,"0")])],toTable:"APPID")
            var entities:[SurveyDXFRecord]=[],blocks:[SurveyDXFRecord]=[],blockRecords:[SurveyDXFRecord]=[]
            func beginBlock(_ name:String)->String {
                let owner=handle()
                blockRecords.append(.make([(0,"BLOCK_RECORD"),(5,owner),(330,blockTable),(100,"AcDbSymbolTableRecord"),(100,"AcDbBlockTableRecord"),(2,name),(70,"0")]))
                blocks.append(.make(entity("BLOCK","0",owner)+[(100,"AcDbBlockBegin"),(2,name),(70,name.hasPrefix("*D") ? "1":"0"),(10,"0"),(20,"0"),(30,"0"),(3,name),(1,"")]))
                return owner
            }
            func endBlock(_ owner:String) { blocks.append(.make(entity("ENDBLK","0",owner)+[(100,"AcDbBlockEnd")])) }
            let blockIDs=Set(project.rooms.flatMap{$0.components.map(\.id)+$0.openings.map(\.id)})
            let originalEntities=doc.indices(in:"ENTITIES").map{doc.records[$0]}
            func owns(_ r:SurveyDXFRecord,_ id:UUID)->Bool { r.tags.contains{$0.code==1000 && $0.value=="OBJECT:\(id.uuidString)"} }
            // Keep architectural outlines and metadata; editable symbols are emitted as INSERTs below.
            let oldIndices=Set(doc.indices(in:"ENTITIES"))
            doc.records=doc.records.enumerated().compactMap { index,record in
                guard oldIndices.contains(index) else { return record }
                if record.string(8)==dimensionLayer { return nil }
                if blockIDs.contains(where:{owns(record,$0)}) { return nil }
                var r=record
                if record.string(8)==wallAxisLayer,let k=record.tags.firstIndex(where:{$0.code==1000 && $0.value=="WALL"}),record.tags.count>k+2,let id=UUID(uuidString:record.tags[k+2].value) {
                    r.tags.append(contentsOf:mark("wall",id))
                }
                return r
            }
            func symbol(_ id:UUID,_ kind:String,_ center:Point2D,_ angle:Double,_ layer:String) {
                let name="PO12_"+id.uuidString.replacingOccurrences(of:"-",with:""), owner=beginBlock(name)
                for source in originalEntities where owns(source,id) {
                    var r=source
                    if let index=r.tags.firstIndex(where:{$0.code>=1000}) { r.tags=Array(r.tags[..<index]) }
                    r.set(5,handle());r.set(330,owner)
                    // Move geometry into a local block frame; dimensions stay in model space.
                    for xcode in [10,11] {
                        let xi=r.tags.indices.filter{r.tags[$0].code==xcode},yi=r.tags.indices.filter{r.tags[$0].code==xcode+10}
                        for (x,y) in zip(xi,yi) {
                            let px=(Double(r.tags[x].value) ?? 0)-center.x,py=(Double(r.tags[y].value) ?? 0)-center.y
                            r.tags[x].value=surveyDXFNumber(px*cos(angle)+py*sin(angle))
                            r.tags[y].value=surveyDXFNumber(-px*sin(angle)+py*cos(angle))
                        }
                    }
                    if r.type=="ARC" { r.set(50,surveyDXFNumber(r.number(50)-angle*180/Double.pi));r.set(51,surveyDXFNumber(r.number(51)-angle*180/Double.pi)) }
                    blocks.append(r)
                }
                endBlock(owner)
                var insert=SurveyDXFRecord.make(entity("INSERT",layer,model)+[(100,"AcDbBlockReference"),(2,name),(10,surveyDXFNumber(center.x)),(20,surveyDXFNumber(center.y)),(30,"0"),(41,"1"),(42,"1"),(43,"1"),(50,surveyDXFNumber(angle*180/Double.pi))])
                insert.tags += mark(kind,id);entities.append(insert)
            }
            for room in project.rooms {
                for c in room.components {
                    let layer=ArchitecturalDraftingConvention.layer(for:ArchitecturalDraftingConvention.ifcClass(for:c.kind)).dxfName(layerNaming)
                    symbol(c.id,"component",c.position,c.rotationRadians,layer)
                }
                for o in room.openings {
                    guard let w=room.walls.first(where:{$0.id==o.parameters.hostWallID}) else { continue }
                    let layer=ArchitecturalDraftingConvention.layer(for:ArchitecturalDraftingConvention.ifcClass(for:o.kind)).dxfName(layerNaming)
                    symbol(o.id,"opening",w.start+w.direction*o.parameters.offsetAlongWall,w.angleRadians,layer)
                }
            }
            let dimTable=handle(),dimStyle=handle(),settings=project.survey.settings
            let table:[SurveyDXFRecord]=[
                .make([(0,"TABLE"),(2,"DIMSTYLE"),(5,dimTable),(330,"0"),(100,"AcDbSymbolTable"),(70,"1")]),
                .make([(0,"DIMSTYLE"),(105,dimStyle),(330,dimTable),(100,"AcDbSymbolTableRecord"),(100,"AcDbDimStyleTableRecord"),(2,"PLANOPSIS_SURVEY"),(70,"0"),(40,"1"),(41,"100"),(42,"50"),(44,"50"),(140,surveyDXFNumber(settings.modelTextHeightMM)),(147,"50"),(271,String(settings.precision)),(277,"2"),(278,"46"),(340,style)]),
                .make([(0,"ENDTAB")])]
            try doc.append(table,toSection:"TABLES")
            if settings.showDimensions {
                for (index,d) in dimensions.dimensions.enumerated() {
                    let name="*D\(index+1)",owner=beginBlock(name)
                    let primitives=SurveyDimensionBuilder().planPrimitives(snapshot:.init(dimensions:[d],issues:[]),settings:settings)
                    for p in primitives {
                        if p.kind == .line,p.points.count==2 {
                            blocks.append(.make(entity("LINE",dimensionLayer,owner)+[(100,"AcDbLine"),(10,surveyDXFNumber(p.points[0].x)),(20,surveyDXFNumber(p.points[0].y)),(30,"0"),(11,surveyDXFNumber(p.points[1].x)),(21,surveyDXFNumber(p.points[1].y)),(31,"0")]))
                        } else if p.kind == .text,let at=p.points.first {
                            blocks.append(.make(entity("TEXT",dimensionLayer,owner)+[(100,"AcDbText"),(10,surveyDXFNumber(at.x)),(20,surveyDXFNumber(at.y)),(30,"0"),(40,surveyDXFNumber(settings.modelTextHeightMM)),(1,p.text ?? ""),(50,surveyDXFNumber(p.rotationDegrees ?? 0)),(7,"STANDARD"),(72,"1"),(11,surveyDXFNumber(at.x)),(21,surveyDXFNumber(at.y)),(31,"0"),(100,"AcDbText"),(73,"2")]))
                        }
                    }
                    endBlock(owner)
                    var r=SurveyDXFRecord.make(entity("DIMENSION",dimensionLayer,model)+[(100,"AcDbDimension"),(2,name),(10,surveyDXFNumber(d.dimensionEnd.x)),(20,surveyDXFNumber(d.dimensionEnd.y)),(30,"0"),(11,surveyDXFNumber(d.textPosition.x)),(21,surveyDXFNumber(d.textPosition.y)),(31,"0"),(70,project.survey.dimensions.first(where:{$0.id==d.id})?.textPosition == nil ? "32":"160"),(1,"<>"),(3,"PLANOPSIS_SURVEY"),(100,"AcDbAlignedDimension"),(13,surveyDXFNumber(d.start.x)),(23,surveyDXFNumber(d.start.y)),(33,"0"),(14,surveyDXFNumber(d.end.x)),(24,surveyDXFNumber(d.end.y)),(34,"0"),(50,surveyDXFNumber(atan2(d.end.y-d.start.y,d.end.x-d.start.x)*180/Double.pi)),(100,"AcDbRotatedDimension")])
                    r.tags += mark("dimension",d.id);entities.append(r)
                }
            }
            try doc.append(blockRecords,toTable:"BLOCK_RECORD")
            try doc.append(blocks,toSection:"BLOCKS")
            try doc.append(entities,toSection:"ENTITIES")
            if let header=doc.records.firstIndex(where:{$0.type=="SECTION" && $0.string(2)=="HEADER"}),let seed=doc.records[header].tags.firstIndex(where:{$0.code==9 && $0.value=="$HANDSEED"}),seed+1<doc.records[header].tags.count { doc.records[header].tags[seed+1].value=handle() }
            manifest.originalDXF=doc.text
            return .init(text:doc.text,manifest:manifest,issues:[])
        } catch { return .init(text:"",manifest:manifest,issues:[error.localizedDescription]) }
    }
}
