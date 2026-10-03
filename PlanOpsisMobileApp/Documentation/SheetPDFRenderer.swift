import Foundation
#if canImport(CoreText)
import CoreGraphics
import CoreText

/// v12.4 writes a drawing set as a vector PDF, one page per sheet at true paper size.
public struct SheetPDFRenderer: Sendable {
    public init() {}

    public func render(_ set: DrawingSet, title: String = "PlanOpsis drawings") throws -> Data {
        let data = NSMutableData()
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "PlanOpsis"]
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary) else {
            throw SurveyError.invalid("Unable to create the PDF drawing set.")
        }
        for sheet in set.sheets {
            let points = 72.0 / 25.4
            var box = CGRect(x: 0, y: 0, width: sheet.width * points, height: sheet.height * points)
            context.beginPage(mediaBox: &box)
            context.saveGState()
            context.scaleBy(x: points, y: points)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for primitive in sheet.primitives { draw(primitive, in: context) }
            context.restoreGState()
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    func draw(_ primitive: SheetPrimitive, in context: CGContext) {
        let ink = CGColor(gray: CGFloat(primitive.gray), alpha: 1)
        context.setStrokeColor(ink)
        context.setLineWidth(CGFloat(max(0.05, primitive.weight)))
        context.setLineDash(phase: 0, lengths: primitive.dash.map { CGFloat($0) })
        func cg(_ p: Point2D) -> CGPoint { CGPoint(x: p.x, y: p.y) }
        func finish(closed: Bool) {
            if let fill = primitive.fill, closed {
                context.setFillColor(CGColor(gray: CGFloat(fill), alpha: 1))
                context.drawPath(using: primitive.weight > 0 ? .fillStroke : .fill)
            } else if primitive.weight > 0 {
                context.strokePath()
            } else {
                context.beginPath()
            }
        }
        switch primitive.shape {
        case let .line(a, b):
            context.beginPath(); context.move(to: cg(a)); context.addLine(to: cg(b)); finish(closed: false)
        case let .polyline(points, closed):
            guard let first = points.first else { return }
            context.beginPath(); context.move(to: cg(first))
            for p in points.dropFirst() { context.addLine(to: cg(p)) }
            if closed { context.closePath() }
            finish(closed: closed)
        case let .polygon(points):
            guard let first = points.first else { return }
            context.beginPath(); context.move(to: cg(first))
            for p in points.dropFirst() { context.addLine(to: cg(p)) }
            context.closePath()
            finish(closed: true)
        case let .circle(center, radius):
            context.beginPath(); context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            finish(closed: true)
        case let .arc(center, radius, start, end):
            context.beginPath(); context.addArc(center: cg(center), radius: CGFloat(radius), startAngle: CGFloat(start), endAngle: CGFloat(end), clockwise: false)
            finish(closed: false)
        case let .text(string, at, height, rotation, anchor, bold):
            drawText(string, at: at, height: height, rotation: rotation, anchor: anchor, bold: bold, color: ink, in: context)
        }
    }

    /// `height` is the cap height in millimetres; Helvetica's cap height is about 0.72 of its size.
    func drawText(_ string: String, at: Point2D, height: Double, rotation: Double, anchor: SheetTextAnchor, bold: Bool, color: CGColor, in context: CGContext) {
        guard !string.isEmpty else { return }
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, CGFloat(height / 0.72), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let shift: Double
        switch anchor {
        case .left: shift = 0
        case .center: shift = width / 2
        case .right: shift = width
        }
        context.saveGState()
        context.translateBy(x: at.x, y: at.y)
        context.rotate(by: CGFloat(rotation))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -shift, y: 0)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
#endif
