import Foundation
import CoreGraphics
import CoreText

public struct SurveySheetRenderer {
    public init() {}
    public func render(project:PlanOpsisProject,dimensions:SurveyDimensionSnapshot,revisionID:UUID?=nil) throws -> Data {
        try SurveyValidation.validate(project)
        guard dimensions.issues.isEmpty else { throw SurveyError.invalid(dimensions.issues.joined(separator:"\n")) }
        let revision=try revisionID?.uuidString.prefix(8).description ?? String(SurveyHash.value(project).prefix(8))
        let builder=SurveyDimensionBuilder()
        var primitives=DXFExchangeEngine(surveyDrawing:true).preview(for:project,representation:.semanticObservations).primitives.filter{$0.layer != "A-DIMS"}
        primitives += builder.planPrimitives(snapshot:dimensions,settings:project.survey.settings)
        var points=primitives.flatMap(\.points)
        for p in primitives { if let c=p.center,let r=p.radius { points += [c-Point2D(x:r,y:r),c+Point2D(x:r,y:r)] } }
        guard !points.isEmpty,points.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { throw SurveyError.invalid("No finite geometry for the survey sheet.") }
        let margin=Double(project.survey.settings.scale)*8
        let minX=points.map(\.x).min()!-margin,minY=points.map(\.y).min()!-margin
        let maxX=points.map(\.x).max()!+margin,maxY=points.map(\.y).max()!+margin
        let paper=72.0/25.4,scale=paper/Double(project.survey.settings.scale)
        let page=CGRect(x:0,y:0,width:420*paper,height:297*paper)
        let drawing=CGRect(x:15*paper,y:25*paper,width:390*paper,height:247*paper)
        let tileW=drawing.width/scale,tileH=drawing.height/scale
        let columns=max(1,Int(ceil((maxX-minX)/tileW))),rows=max(1,Int(ceil((maxY-minY)/tileH)))
        guard columns*rows<=100 else { throw SurveyError.invalid("Drawing needs more than 100 sheets at this scale. Choose a smaller drawing scale.") }
        let data=NSMutableData()
        guard let consumer=CGDataConsumer(data:data),let context=CGContext(consumer:consumer,mediaBox:nil,nil) else { throw SurveyError.invalid("Unable to create PDF drawing.") }
        func text(_ value:String,_ position:CGPoint,_ size:Double,_ rotation:Double=0) {
            context.saveGState();context.translateBy(x:position.x,y:position.y);context.rotate(by:rotation)
            let attrs:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,size,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:value,attributes:attrs))
            context.textMatrix = .identity;context.textPosition = .zero;CTLineDraw(line,context);context.restoreGState()
        }
        for row in 0..<rows { for column in 0..<columns {
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes:[page],length:MemoryLayout<CGRect>.size)] as CFDictionary)
            text("PlanOpsis | Measured survey",CGPoint(x:drawing.minX,y:page.height-14*paper),14)
            text("1:\(project.survey.settings.scale) at 100% print | mm | Project \(project.id.uuidString.prefix(8)) | Rev \(revision)",CGPoint(x:drawing.minX,y:page.height-21*paper),9)
            text("Sheet \(row*columns+column+1)/\(rows*columns) | Tile \(column+1),\(row+1) | \(SurveyQAReport(project:project).fieldStatus)",CGPoint(x:drawing.minX,y:15*paper),9)
            text("Model dimensions do not certify capture or field accuracy.",CGPoint(x:drawing.minX,y:9*paper),8)
            // A 100 mm paper reference lets a recipient detect fit-to-page scaling.
            context.setStrokeColor(CGColor(gray:0,alpha:1));context.setLineWidth(0.5)
            context.move(to:CGPoint(x:page.width-115*paper,y:12*paper));context.addLine(to:CGPoint(x:page.width-15*paper,y:12*paper));context.strokePath()
            text("100 mm on paper",CGPoint(x:page.width-100*paper,y:7*paper),7)
            let origin=Point2D(x:columns==1 ? minX-(tileW-(maxX-minX))/2 : minX+Double(column)*tileW,y:rows==1 ? minY-(tileH-(maxY-minY))/2 : maxY-Double(row+1)*tileH)
            func point(_ p:Point2D)->CGPoint { CGPoint(x:drawing.minX+(p.x-origin.x)*scale,y:drawing.minY+(p.y-origin.y)*scale) }
            context.saveGState();context.clip(to:drawing)
            for p in primitives where p.layer != "A-SPACE" {
                context.setLineWidth(max(0.1,p.lineWeightMM)*paper)
                if p.kind == .text,let at=p.points.first,let value=p.text {
                    let size=(p.textHeight ?? project.survey.settings.modelTextHeightMM)*scale
                    let angle=(p.rotationDegrees ?? 0)*Double.pi/180
                    let attrs=[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,size,nil)]
                    let width=CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string:value,attributes:attrs)),nil,nil,nil)
                    var anchor=point(at);anchor.x -= cos(angle)*width/2;anchor.y -= sin(angle)*width/2
                    // An opaque text background keeps the measured label clear of dimension strokes.
                    context.saveGState();context.translateBy(x:anchor.x,y:anchor.y);context.rotate(by:angle)
                    context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:-2,y:-2,width:width+4,height:size+4));context.restoreGState()
                    text(value,anchor,size,angle)
                } else if p.kind == .arc,let c=p.center,let r=p.radius {
                    context.beginPath();context.addArc(center:point(c),radius:r*scale,startAngle:(p.startAngleDegrees ?? 0)*Double.pi/180,endAngle:(p.endAngleDegrees ?? 360)*Double.pi/180,clockwise:false);context.strokePath()
                } else if let first=p.points.first {
                    context.beginPath();context.move(to:point(first));for vertex in p.points.dropFirst() { context.addLine(to:point(vertex)) };if p.closed { context.closePath() };context.strokePath()
                }
            }
            context.restoreGState();context.endPDFPage()
        } }
        context.closePDF();return data as Data
    }
}
