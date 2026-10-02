#if os(iOS)
import SwiftUI

struct PLYPlanPreview: View {
    let result: PLYReconstructionResult
    var showWallLabels: Bool = false

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                guard let bounds = previewBounds else { return }
                let pad = 18.0
                let sx = max(1e-9, (size.width - pad * 2) / max(1, bounds.maxX - bounds.minX))
                let sy = max(1e-9, (size.height - pad * 2) / max(1, bounds.maxY - bounds.minY))
                let scale = min(sx, sy)

                func map(_ p: PLYPoint2D) -> CGPoint {
                    CGPoint(
                        x: pad + (p.x - bounds.minX) * scale,
                        y: size.height - pad - (p.y - bounds.minY) * scale
                    )
                }

                // Cap display-only evidence. Reconstruction uses the complete downsampled section,
                // while the preview intentionally avoids submitting an unbounded path to Canvas.
                var pointsPath = Path()
                for p in result.sectionPointsMM.prefix(12_000) {
                    let q = map(p)
                    pointsPath.addEllipse(in: CGRect(x: q.x - 0.9, y: q.y - 0.9, width: 1.8, height: 1.8))
                }
                context.fill(pointsPath, with: .color(Color.primary.opacity(0.34)))

                for segment in result.segments {
                    var path = Path()
                    path.move(to: map(segment.start))
                    path.addLine(to: map(segment.end))
                    context.stroke(path, with: .color(Color.primary.opacity(0.9)), lineWidth: 1.4)
                }

                for (index, wall) in result.wallSeeds.enumerated() {
                    var path = Path()
                    path.move(to: map(wall.startMM))
                    path.addLine(to: map(wall.endMM))
                    context.stroke(
                        path,
                        with: .color(Color.accentColor),
                        lineWidth: max(2.2, min(24, wall.thicknessMM * scale))
                    )
                    if showWallLabels {
                        let d = PLYPoint2D(x: cos(wall.angleRadians), y: sin(wall.angleRadians))
                        let midpoint = wall.startMM + d * (wall.lengthMM * 0.5)
                        context.draw(
                            Text("W\(index + 1)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.accentColor),
                            at: map(midpoint),
                            anchor: .center
                        )
                    }
                }

                for wall in result.reviewWallSeeds {
                    var path = Path()
                    path.move(to: map(wall.startMM))
                    path.addLine(to: map(wall.endMM))
                    context.stroke(
                        path,
                        with: .color(Color.orange.opacity(0.95)),
                        style: StrokeStyle(lineWidth: max(1.8, min(18, wall.thicknessMM * scale * 0.55)), dash: [7, 5])
                    )
                }

                for wall in result.suppressedWallSeeds {
                    var path = Path()
                    path.move(to: map(wall.startMM))
                    path.addLine(to: map(wall.endMM))
                    context.stroke(
                        path,
                        with: .color(Color.red.opacity(0.28)),
                        style: StrokeStyle(lineWidth: 1.2, dash: [3, 5])
                    )
                }

                for structural in result.structuralSeeds {
                    let corners = footprint(of: structural)
                    guard let first = corners.first else { continue }
                    var path = Path()
                    path.move(to: map(first))
                    for corner in corners.dropFirst() { path.addLine(to: map(corner)) }
                    path.closeSubpath()
                    let color: Color = structural.kind == .column ? .purple : .cyan
                    context.fill(path, with: .color(color.opacity(0.16)))
                    context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: structural.kind == .column ? 1.8 : 1.4)
                }

                for structural in result.reviewStructuralSeeds {
                    let corners = footprint(of: structural)
                    guard let first = corners.first else { continue }
                    var path = Path()
                    path.move(to: map(first))
                    for corner in corners.dropFirst() { path.addLine(to: map(corner)) }
                    path.closeSubpath()
                    context.fill(path, with: .color(Color.orange.opacity(0.10)))
                    context.stroke(path, with: .color(Color.orange.opacity(0.9)), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                }

                for structural in result.suppressedStructuralSeeds {
                    let corners = footprint(of: structural)
                    guard let first = corners.first else { continue }
                    var path = Path()
                    path.move(to: map(first))
                    for corner in corners.dropFirst() { path.addLine(to: map(corner)) }
                    path.closeSubpath()
                    context.stroke(path, with: .color(Color.red.opacity(0.25)), style: StrokeStyle(lineWidth: 1.0, dash: [2, 5]))
                }
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Computes bounds without concatenating/copying the potentially large point array.
    private var previewBounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)?

        func include(_ p: PLYPoint2D) {
            if var current = bounds {
                current.minX = min(current.minX, p.x)
                current.minY = min(current.minY, p.y)
                current.maxX = max(current.maxX, p.x)
                current.maxY = max(current.maxY, p.y)
                bounds = current
            } else {
                bounds = (p.x, p.y, p.x, p.y)
            }
        }

        for p in result.sectionPointsMM { include(p) }
        for segment in result.segments {
            include(segment.start)
            include(segment.end)
        }
        for wall in result.wallSeeds + result.reviewWallSeeds + result.suppressedWallSeeds {
            include(wall.startMM)
            include(wall.endMM)
        }
        // Structural candidates do not control preview framing. The comparison should remain
        // centred on the measured PLY footprint and reconstructed wall boundary; an outlier
        // candidate must not zoom the room down to a thumbnail.
        return bounds
    }

    private func footprint(of seed: PLYStructuralSeed) -> [PLYPoint2D] {
        let d = PLYPoint2D(x: cos(seed.rotationRadians), y: sin(seed.rotationRadians))
        let n = PLYPoint2D(x: -sin(seed.rotationRadians), y: cos(seed.rotationRadians))
        let x = d * (seed.widthMM * 0.5)
        let y = n * (seed.depthMM * 0.5)
        return [seed.centerMM - x - y, seed.centerMM + x - y, seed.centerMM + x + y, seed.centerMM - x + y]
    }
}
#endif
