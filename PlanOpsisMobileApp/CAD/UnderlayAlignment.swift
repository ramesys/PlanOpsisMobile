import Foundation

/// v12.6 where an underlay (an architect's DXF or a PDF page) sits under the plan.
///
/// Drawing coordinates map to plan millimetres as translation(offset) · rotation · scale(unitScale ·
/// scale): `unitScale` comes from the source (the DXF's units, or the PDF's paper scale) and `scale` is
/// the calibration on top of it, 1 when the source units are right.
public struct UnderlayPlacement: Codable, Hashable, Sendable {
    public var offset: Point2D
    public var rotationDegrees: Double
    public var scale: Double

    public init(offset: Point2D = .zero, rotationDegrees: Double = 0, scale: Double = 1) {
        self.offset = offset
        self.rotationDegrees = rotationDegrees
        self.scale = scale
    }

    public static let identity = UnderlayPlacement()

    public func transform(unitScale: Double) -> CADAffine {
        let s = unitScale * scale
        return CADAffine.translation(offset)
            .concatenating(.rotation(rotationDegrees * .pi / 180))
            .concatenating(.scale(s, s))
    }

    /// The placement after moving the placed drawing by `correction` (applied in plan coordinates).
    public func applying(_ correction: PlanSimilarity) -> UnderlayPlacement {
        var degrees = (rotationDegrees + correction.rotation * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 } else if degrees <= -180 { degrees += 360 }
        return UnderlayPlacement(offset: correction.apply(offset), rotationDegrees: degrees, scale: scale * correction.scale)
    }

    public func moved(by delta: Point2D) -> UnderlayPlacement {
        applying(PlanSimilarity(translation: delta))
    }

    /// Rotated about a plan point.
    public func rotated(byDegrees degrees: Double, about center: Point2D) -> UnderlayPlacement {
        applying(.rotation(degrees * .pi / 180, about: center))
    }
}

/// A uniform scale and rotation about the origin followed by a translation: p ↦ s·R(θ)·p + t.
public struct PlanSimilarity: Hashable, Sendable {
    public var scale: Double
    /// Radians, counter-clockwise.
    public var rotation: Double
    public var translation: Point2D

    public init(scale: Double = 1, rotation: Double = 0, translation: Point2D = .zero) {
        self.scale = scale
        self.rotation = rotation
        self.translation = translation
    }

    public func apply(_ p: Point2D) -> Point2D {
        let c = cos(rotation), s = sin(rotation)
        return Point2D(x: scale * (c * p.x - s * p.y), y: scale * (s * p.x + c * p.y)) + translation
    }

    public static func rotation(_ angle: Double, about center: Point2D) -> PlanSimilarity {
        let turn = PlanSimilarity(rotation: angle)
        return PlanSimilarity(rotation: angle, translation: center - turn.apply(center))
    }

    public static func scaling(_ factor: Double, about center: Point2D) -> PlanSimilarity {
        PlanSimilarity(scale: factor, translation: center - center * factor)
    }

    /// The similarity taking `a` to `targetA` and `b` toward `targetB`: rotation and translation always,
    /// scale only when `matchScale` (otherwise the drawing keeps its size and `targetA` is exact).
    /// Nil when either pair of points coincides.
    public static func aligning(_ a: Point2D, _ b: Point2D, to targetA: Point2D, _ targetB: Point2D, matchScale: Bool) -> PlanSimilarity? {
        let from = b - a, to = targetB - targetA
        guard from.length > 1e-9, to.length > 1e-9 else { return nil }
        let rotation = atan2(to.y, to.x) - atan2(from.y, from.x)
        let scale = matchScale ? to.length / from.length : 1
        let turned = PlanSimilarity(scale: scale, rotation: rotation)
        return PlanSimilarity(scale: scale, rotation: rotation, translation: targetA - turned.apply(a))
    }
}

/// Picking state for two-point alignment and calibration, kept apart from the view so it can be tested.
public struct UnderlayAlignmentSession: Hashable, Sendable {
    public enum Mode: String, Hashable, Sendable {
        /// Two points on the underlay, then the same two points on the plan.
        case align
        /// Two points on the underlay a known distance apart.
        case calibrate
    }

    public var mode: Mode
    public private(set) var underlayPoints: [Point2D] = []
    public private(set) var planPoints: [Point2D] = []

    public init(mode: Mode) { self.mode = mode }

    public var needsUnderlayPoint: Bool { underlayPoints.count < 2 }
    public var isComplete: Bool {
        switch mode {
        case .align: return underlayPoints.count == 2 && planPoints.count == 2
        case .calibrate: return underlayPoints.count == 2
        }
    }

    public mutating func add(_ point: Point2D) {
        if underlayPoints.count < 2 { underlayPoints.append(point) }
        else if mode == .align, planPoints.count < 2 { planPoints.append(point) }
    }

    public mutating func undo() {
        if !planPoints.isEmpty { planPoints.removeLast() } else if !underlayPoints.isEmpty { underlayPoints.removeLast() }
    }

    /// What to tap next.
    public var prompt: String {
        switch (mode, underlayPoints.count, planPoints.count) {
        case (_, 0, _): return "Tap the first point on the underlay."
        case (_, 1, _): return "Tap the second point on the underlay."
        case (.align, _, 0): return "Tap where the first point belongs on the plan."
        case (.align, _, 1): return "Tap where the second point belongs on the plan."
        case (.calibrate, _, _): return "Enter the real distance between the two points."
        default: return "Alignment ready."
        }
    }

    /// The correction for `.align`; nil until four points are picked.
    public func alignment(matchScale: Bool) -> PlanSimilarity? {
        guard mode == .align, isComplete else { return nil }
        return PlanSimilarity.aligning(underlayPoints[0], underlayPoints[1], to: planPoints[0], planPoints[1], matchScale: matchScale)
    }

    /// Scale factor the underlay would need for `.align` to fit both points exactly.
    public var alignmentScaleFactor: Double? {
        guard mode == .align, isComplete else { return nil }
        let from = (underlayPoints[1] - underlayPoints[0]).length, to = (planPoints[1] - planPoints[0]).length
        return from > 1e-9 ? to / from : nil
    }

    /// The correction for `.calibrate`: scales about the first point so the two points end up
    /// `knownLength` millimetres apart.
    public func calibration(knownLength: Double) -> PlanSimilarity? {
        guard mode == .calibrate, isComplete, knownLength > 0 else { return nil }
        let measured = (underlayPoints[1] - underlayPoints[0]).length
        guard measured > 1e-9 else { return nil }
        return .scaling(knownLength / measured, about: underlayPoints[0])
    }

    /// Distance between the two underlay points as currently placed, mm.
    public var measuredLength: Double? {
        underlayPoints.count == 2 ? (underlayPoints[1] - underlayPoints[0]).length : nil
    }
}

/// v12.6 a PDF page used as an underlay: a rendered image of the sheet, placed like a drawing whose
/// unit is one millimetre of paper, so the drawing scale (1:100 → 100) is the unit scale.
public struct RasterUnderlay: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Paper size of the page, mm.
    public var pageWidthMM: Double
    public var pageHeightMM: Double
    /// PNG of the page; the image's top-left corner is the page's top-left corner.
    public var imageData: Data
    /// Drawing scale denominator: 100 for 1:100.
    public var paperScale: Double

    public init(id: UUID = UUID(), name: String, pageWidthMM: Double, pageHeightMM: Double, imageData: Data, paperScale: Double = 100) {
        self.id = id
        self.name = name
        self.pageWidthMM = pageWidthMM
        self.pageHeightMM = pageHeightMM
        self.imageData = imageData
        self.paperScale = paperScale
    }

    /// Page corners in paper mm: top-left, top-right, bottom-left (y up).
    public var corners: (topLeft: Point2D, topRight: Point2D, bottomLeft: Point2D) {
        (Point2D(x: 0, y: pageHeightMM), Point2D(x: pageWidthMM, y: pageHeightMM), Point2D(x: 0, y: 0))
    }

    /// Bounds of the placed page in plan mm.
    public func bounds(placement: UnderlayPlacement) -> CADRect {
        let t = placement.transform(unitScale: paperScale)
        let c = corners
        return CADRect(points: [c.topLeft, c.topRight, c.bottomLeft, Point2D(x: pageWidthMM, y: 0)].map(t.apply)) ?? .empty
    }
}

/// v12.7 the underlay a project keeps: the source file (stored, hash-verified, with the project's
/// attachments) and how it sits under the plan.
public struct ProjectUnderlay: Codable, Hashable, Sendable {
    public enum Format: String, Codable, Hashable, Sendable { case dxf, pdf, ifc }

    public var format: Format
    public var asset: SurveyEvidenceReference
    public var fileName: String
    public var placement: UnderlayPlacement
    /// PDF only: the drawing scale denominator and the page shown (0-based).
    public var paperScale: Double?
    public var pageIndex: Int?
    public var hiddenLayers: [String]?
    public var isVisible: Bool

    public init(format: Format, asset: SurveyEvidenceReference, fileName: String, placement: UnderlayPlacement,
                paperScale: Double? = nil, pageIndex: Int? = nil, hiddenLayers: [String]? = nil, isVisible: Bool = true) {
        self.format = format
        self.asset = asset
        self.fileName = fileName
        self.placement = placement
        self.paperScale = paperScale
        self.pageIndex = pageIndex
        self.hiddenLayers = hiddenLayers
        self.isVisible = isVisible
    }

    public static func format(forFileName name: String) -> Format {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return .pdf
        case "ifc": return .ifc
        default: return .dxf
        }
    }
}
