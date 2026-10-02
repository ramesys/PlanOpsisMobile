import Foundation

/// v12.1 pure 2D plan camera: maps model millimetres (Y up) to view points (Y down).
///
/// The plan view used to recompute its fit from the current geometry on every render, so an edit that
/// changed the drawing's extent rescaled the view under the user's finger. The view now keeps one
/// transform and refits only on explicit events (Fit, project/room change, first layout).
/// Screen points are expressed as `Point2D` in view coordinates so this stays platform-neutral.
public struct PlanViewTransform: Hashable, Sendable {
    /// View points per model millimetre.
    public var scale: Double
    /// Model point displayed at the centre of the view.
    public var modelCenter: Point2D

    public init(scale: Double, modelCenter: Point2D) {
        self.scale = max(1e-9, scale)
        self.modelCenter = modelCenter
    }

    /// Drafting margin used by `fitted`: proportional to the view, between 44 and 88 points.
    public static func contentInset(viewWidth: Double, viewHeight: Double) -> Double {
        min(88, max(44, max(1, min(viewWidth, viewHeight)) * 0.12))
    }

    /// The transform that centres `bounds` in the view with the drafting margin.
    public static func fitted(to bounds: FloorGeometry?, viewWidth: Double, viewHeight: Double) -> PlanViewTransform {
        guard let bounds else { return PlanViewTransform(scale: 1, modelCenter: .zero) }
        let inset = contentInset(viewWidth: viewWidth, viewHeight: viewHeight)
        let availableWidth = max(1, viewWidth - inset * 2)
        let availableHeight = max(1, viewHeight - inset * 2)
        let scale = min(availableWidth / max(1, bounds.width), availableHeight / max(1, bounds.depth))
        return PlanViewTransform(scale: scale, modelCenter: bounds.center)
    }

    public func screen(_ model: Point2D, viewWidth: Double, viewHeight: Double) -> Point2D {
        Point2D(
            x: viewWidth * 0.5 + (model.x - modelCenter.x) * scale,
            y: viewHeight * 0.5 - (model.y - modelCenter.y) * scale
        )
    }

    public func model(_ screen: Point2D, viewWidth: Double, viewHeight: Double) -> Point2D {
        Point2D(
            x: modelCenter.x + (screen.x - viewWidth * 0.5) / scale,
            y: modelCenter.y + (viewHeight * 0.5 - screen.y) / scale
        )
    }

    /// Moves the drawing by a screen-space translation.
    public func panned(byScreenDX dx: Double, dy: Double) -> PlanViewTransform {
        PlanViewTransform(scale: scale, modelCenter: Point2D(x: modelCenter.x - dx / scale, y: modelCenter.y + dy / scale))
    }

    /// Scales by `factor` keeping the model point under `focus` (view coordinates) fixed on screen.
    public func zoomed(by factor: Double, about focus: Point2D, viewWidth: Double, viewHeight: Double) -> PlanViewTransform {
        guard factor.isFinite, factor > 0 else { return self }
        let anchor = model(focus, viewWidth: viewWidth, viewHeight: viewHeight)
        let newScale = scale * factor
        return PlanViewTransform(
            scale: newScale,
            modelCenter: Point2D(
                x: anchor.x - (focus.x - viewWidth * 0.5) / newScale,
                y: anchor.y - (viewHeight * 0.5 - focus.y) / newScale
            )
        )
    }
}
