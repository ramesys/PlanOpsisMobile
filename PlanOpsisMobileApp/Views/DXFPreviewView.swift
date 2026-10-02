#if os(iOS)
import SwiftUI

struct DXFPreviewView: View {
    let snapshot: DXFPreviewSnapshot

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = CGSize(width: max(1, proxy.size.width - 20), height: max(1, proxy.size.height - 20))
            let viewport = DXFViewport(snapshot: snapshot, size: canvasSize)
            ZStack(alignment: .topLeading) {
                PlanOpsisPalette.workspace

                Canvas { context, _ in
                    for primitive in snapshot.primitives {
                        if let layer = ArchitecturalDraftingConvention.Layer(rawValue: primitive.layer),
                           !ArchitecturalDraftingConvention.isInitiallyVisible(layer) { continue }
                        draw(primitive, viewport: viewport, context: &context)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
                .padding(10)

                Text("DXF · mm")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .planOpsisLiquidSurface(cornerRadius: 14)
                    .padding(18)
            }
        }
    }

    private func draw(_ primitive: DXFPrimitive, viewport: DXFViewport, context: inout GraphicsContext) {
        let lineWidth = screenLineWidth(primitive.lineWeightMM)
        switch primitive.kind {
        case .line:
            guard primitive.points.count >= 2 else { return }
            var path = Path()
            path.move(to: viewport.screen(primitive.points[0]))
            path.addLine(to: viewport.screen(primitive.points[1]))
            context.stroke(path, with: .color(.primary), lineWidth: lineWidth)
        case .polyline:
            guard let first = primitive.points.first else { return }
            var path = Path()
            path.move(to: viewport.screen(first))
            for p in primitive.points.dropFirst() { path.addLine(to: viewport.screen(p)) }
            if primitive.closed { path.closeSubpath() }
            context.stroke(path, with: .color(.primary), lineWidth: lineWidth)
        case .arc:
            guard let center = primitive.center,
                  let radius = primitive.radius,
                  let start = primitive.startAngleDegrees,
                  let end = primitive.endAngleDegrees else { return }
            var span = end - start
            if span <= 0 { span += 360 }
            let steps = max(8, Int(span / 5))
            var path = Path()
            for i in 0...steps {
                let a = (start + span * Double(i) / Double(steps)) * .pi / 180
                let p = center + Point2D(x: cos(a), y: sin(a)) * radius
                if i == 0 { path.move(to: viewport.screen(p)) }
                else { path.addLine(to: viewport.screen(p)) }
            }
            context.stroke(path, with: .color(.primary), lineWidth: lineWidth)
        case .text:
            guard let p = primitive.points.first, let value = primitive.text else { return }
            let screenPoint = viewport.screen(p)
            let label = Text(value).font(.system(size: max(8, min(13, CGFloat((primitive.textHeight ?? 180) * viewport.scale * 0.8))), design: .monospaced))
            let rotation = primitive.rotationDegrees ?? 0
            context.drawLayer { layer in
                layer.translateBy(x: screenPoint.x, y: screenPoint.y)
                // DXF angles are counter-clockwise in Y-up model space; Canvas screen Y points down.
                layer.rotate(by: .degrees(-rotation))
                layer.draw(label, at: .zero, anchor: .center)
            }
        }
    }

    private func screenLineWidth(_ millimetres: Double) -> CGFloat {
        switch millimetres {
        case 0.40...: return 3.0
        case 0.20...: return 2.0
        default: return 1.0
        }
    }
}

private struct DXFViewport {
    let minX: Double
    let minY: Double
    let scale: Double
    let size: CGSize
    let padding: Double = 28

    init(snapshot: DXFPreviewSnapshot, size: CGSize) {
        let visiblePrimitives = snapshot.primitives.filter { primitive in
            guard let layer = ArchitecturalDraftingConvention.Layer(rawValue: primitive.layer) else { return true }
            return ArchitecturalDraftingConvention.isInitiallyVisible(layer)
        }
        let points = visiblePrimitives.flatMap(\.boundsPoints)
        if let first = points.first {
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points.dropFirst() {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            let w = max(1, maxX - minX), h = max(1, maxY - minY)
            self.minX = minX; self.minY = minY
            self.scale = min(max(1, Double(size.width) - 2 * padding) / w, max(1, Double(size.height) - 2 * padding) / h)
        } else {
            self.minX = 0; self.minY = 0; self.scale = 1
        }
        self.size = size
    }

    func screen(_ p: Point2D) -> CGPoint {
        CGPoint(
            x: CGFloat(padding + (p.x - minX) * scale),
            y: CGFloat(Double(size.height) - padding - (p.y - minY) * scale)
        )
    }
}
#endif
