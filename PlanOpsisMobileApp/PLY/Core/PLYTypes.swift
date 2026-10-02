import Foundation

public enum PLYLengthUnit: String, CaseIterable, Codable, Sendable {
    case meters
    case centimeters
    case millimeters

    public var millimetersPerUnit: Double {
        switch self {
        case .meters: return 1000.0
        case .centimeters: return 10.0
        case .millimeters: return 1.0
        }
    }

    public var label: String {
        switch self {
        case .meters: return "m"
        case .centimeters: return "cm"
        case .millimeters: return "mm"
        }
    }
}

public enum PLYUpAxis: String, CaseIterable, Codable, Sendable {
    case auto
    case x
    case y
    case z

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        }
    }
}

public enum PLYWallInferenceKind: String, Codable, Hashable, Sendable {
    /// Two approximately parallel observed faces supplied a measured wall thickness.
    case pairedFaces
    /// Only one visible wall surface/line was present; PlanOpsis uses the configured default thickness.
    case singleSurface
}

public enum PLYStructuralKind: String, Codable, Hashable, Sendable {
    case column
    case beam

    public var label: String {
        switch self {
        case .column: return "Column"
        case .beam: return "Beam"
        }
    }
}

public enum PLYCandidateStatus: String, Codable, Hashable, Sendable {
    case accepted
    case review
    case suppressed

    public var label: String {
        switch self {
        case .accepted: return "Accepted"
        case .review: return "Review"
        case .suppressed: return "Suppressed"
        }
    }
}

public enum PLYQAStatus: String, Codable, Hashable, Sendable {
    case pass
    case review
    case fail

    public var label: String {
        switch self {
        case .pass: return "PASS"
        case .review: return "REVIEW"
        case .fail: return "FAIL"
        }
    }
}

public struct PLYPoint3D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public func scaled(by factor: Double) -> PLYPoint3D {
        .init(x: x * factor, y: y * factor, z: z * factor)
    }
}

public struct PLYPoint2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static func +(lhs: PLYPoint2D, rhs: PLYPoint2D) -> PLYPoint2D {
        .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    public static func -(lhs: PLYPoint2D, rhs: PLYPoint2D) -> PLYPoint2D {
        .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    public static func *(lhs: PLYPoint2D, rhs: Double) -> PLYPoint2D {
        .init(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    public var length: Double { hypot(x, y) }
}

public struct PLYBounds3D: Codable, Hashable, Sendable {
    public var min: PLYPoint3D
    public var max: PLYPoint3D

    public init(min: PLYPoint3D, max: PLYPoint3D) {
        self.min = min
        self.max = max
    }

    public var width: Double { max.x - min.x }
    public var depth: Double { max.y - min.y }
    public var height: Double { max.z - min.z }
}

public struct PLYPointCloud: Codable, Hashable, Sendable {
    public var sourceName: String
    public var sourceUnit: PLYLengthUnit
    public var points: [PLYPoint3D]

    public init(sourceName: String, sourceUnit: PLYLengthUnit, points: [PLYPoint3D]) {
        self.sourceName = sourceName
        self.sourceUnit = sourceUnit
        self.points = points
    }

    public var boundsInSourceUnits: PLYBounds3D? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, minZ = first.z
        var maxX = first.x, maxY = first.y, maxZ = first.z
        for p in points.dropFirst() {
            minX = Swift.min(minX, p.x); minY = Swift.min(minY, p.y); minZ = Swift.min(minZ, p.z)
            maxX = Swift.max(maxX, p.x); maxY = Swift.max(maxY, p.y); maxZ = Swift.max(maxZ, p.z)
        }
        return .init(min: .init(x: minX, y: minY, z: minZ), max: .init(x: maxX, y: maxY, z: maxZ))
    }

    public func pointsInMillimeters() -> [PLYPoint3D] {
        let s = sourceUnit.millimetersPerUnit
        return points.map { $0.scaled(by: s) }
    }
}

public struct PLYSectionSettings: Codable, Hashable, Sendable {
    public var upAxis: PLYUpAxis
    public var sectionHeightMM: Double
    public var sectionThicknessMM: Double
    public var voxelSizeMM: Double
    public var lineToleranceMM: Double
    public var minLineSupport: Int
    public var minSegmentLengthMM: Double
    public var maxGapMM: Double
    public var maxSegments: Int
    public var angleStepDegrees: Double
    public var endpointSnapMM: Double
    public var minWallThicknessMM: Double
    public var maxWallThicknessMM: Double
    public var defaultWallThicknessMM: Double
    public var defaultWallHeightMM: Double
    public var allowSingleSurfaceWalls: Bool
    /// Treats a single observed room-facing scan surface as the *interior wall face*, then offsets
    /// the semantic wall axis outward by half the assumed thickness. This keeps the measured PLY
    /// footprint registered to the inner architectural wall face instead of centering a wall on it.
    public var registerSingleSurfaceAsInteriorFace: Bool
    /// Runs a topology cleanup pass after geometric line extraction: collinear fragment consolidation,
    /// junction solving, T-junction attachment, and small disconnected-noise pruning.
    public var professionalCleanup: Bool
    /// Maximum scan/occlusion/opening gap that may be bridged between collinear wall fragments.
    /// This restores a continuous semantic host wall across doors/windows; openings can be inferred later.
    public var wallContinuityGapMM: Double
    /// Detect reviewable structural candidates from the same PLY evidence. These remain candidates
    /// until the user commits the reconstruction into the semantic project.
    public var detectStructuralElements: Bool
    public var structuralGridMM: Double
    public var defaultBeamWidthMM: Double
    public var defaultBeamDepthMM: Double
    /// v11.8: suppresses weak disconnected geometric candidates before they cross the semantic boundary.
    public var noiseSuppressionEnabled: Bool
    /// Minimum automatic wall quality score. Lower-quality walls are retained as review evidence.
    public var automaticWallAcceptanceScore: Double
    /// Below this score a wall is considered scan noise unless manually reviewed.
    public var wallSuppressionScore: Double
    /// Maximum residual used when measuring how much of the plan-section evidence supports semantic walls.
    public var qaWallSupportDistanceMM: Double

    public init(
        upAxis: PLYUpAxis = .auto,
        sectionHeightMM: Double = 1200,
        sectionThicknessMM: Double = 180,
        voxelSizeMM: Double = 35,
        lineToleranceMM: Double = 45,
        minLineSupport: Int = 10,
        minSegmentLengthMM: Double = 450,
        maxGapMM: Double = 220,
        maxSegments: Int = 40,
        angleStepDegrees: Double = 2,
        endpointSnapMM: Double = 80,
        minWallThicknessMM: Double = 70,
        maxWallThicknessMM: Double = 500,
        defaultWallThicknessMM: Double = 150,
        defaultWallHeightMM: Double = 2700,
        allowSingleSurfaceWalls: Bool = true,
        registerSingleSurfaceAsInteriorFace: Bool = true,
        professionalCleanup: Bool = true,
        wallContinuityGapMM: Double = 1600,
        detectStructuralElements: Bool = true,
        structuralGridMM: Double = 120,
        defaultBeamWidthMM: Double = 250,
        defaultBeamDepthMM: Double = 350,
        noiseSuppressionEnabled: Bool = true,
        automaticWallAcceptanceScore: Double = 0.54,
        wallSuppressionScore: Double = 0.32,
        qaWallSupportDistanceMM: Double = 140
    ) {
        self.upAxis = upAxis
        self.sectionHeightMM = sectionHeightMM
        self.sectionThicknessMM = sectionThicknessMM
        self.voxelSizeMM = voxelSizeMM
        self.lineToleranceMM = lineToleranceMM
        self.minLineSupport = minLineSupport
        self.minSegmentLengthMM = minSegmentLengthMM
        self.maxGapMM = maxGapMM
        self.maxSegments = maxSegments
        self.angleStepDegrees = angleStepDegrees
        self.endpointSnapMM = endpointSnapMM
        self.minWallThicknessMM = minWallThicknessMM
        self.maxWallThicknessMM = maxWallThicknessMM
        self.defaultWallThicknessMM = defaultWallThicknessMM
        self.defaultWallHeightMM = defaultWallHeightMM
        self.allowSingleSurfaceWalls = allowSingleSurfaceWalls
        self.registerSingleSurfaceAsInteriorFace = registerSingleSurfaceAsInteriorFace
        self.professionalCleanup = professionalCleanup
        self.wallContinuityGapMM = wallContinuityGapMM
        self.detectStructuralElements = detectStructuralElements
        self.structuralGridMM = structuralGridMM
        self.defaultBeamWidthMM = defaultBeamWidthMM
        self.defaultBeamDepthMM = defaultBeamDepthMM
        self.noiseSuppressionEnabled = noiseSuppressionEnabled
        self.automaticWallAcceptanceScore = automaticWallAcceptanceScore
        self.wallSuppressionScore = wallSuppressionScore
        self.qaWallSupportDistanceMM = qaWallSupportDistanceMM
    }
}

public struct PLYPlanSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var start: PLYPoint2D
    public var end: PLYPoint2D
    public var support: Int
    public var rmsErrorMM: Double

    public init(id: UUID = UUID(), start: PLYPoint2D, end: PLYPoint2D, support: Int, rmsErrorMM: Double) {
        self.id = id
        self.start = start
        self.end = end
        self.support = support
        self.rmsErrorMM = rmsErrorMM
    }

    public var lengthMM: Double { (end - start).length }
    public var direction: PLYPoint2D {
        let d = end - start
        let len = max(d.length, 1e-9)
        return .init(x: d.x / len, y: d.y / len)
    }

    public var angleRadians: Double { atan2(end.y - start.y, end.x - start.x) }
}

public struct PLYWallSeed: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var startMM: PLYPoint2D
    public var lengthMM: Double
    public var angleRadians: Double
    public var heightMM: Double
    public var thicknessMM: Double
    public var confidence: Double
    public var inferenceKind: PLYWallInferenceKind
    public var sourceSegmentIDs: [UUID]

    public init(
        id: UUID = UUID(),
        startMM: PLYPoint2D,
        lengthMM: Double,
        angleRadians: Double,
        heightMM: Double,
        thicknessMM: Double,
        confidence: Double,
        inferenceKind: PLYWallInferenceKind = .pairedFaces,
        sourceSegmentIDs: [UUID]
    ) {
        self.id = id
        self.startMM = startMM
        self.lengthMM = lengthMM
        self.angleRadians = angleRadians
        self.heightMM = heightMM
        self.thicknessMM = thicknessMM
        self.confidence = confidence
        self.inferenceKind = inferenceKind
        self.sourceSegmentIDs = sourceSegmentIDs
    }

    public var endMM: PLYPoint2D {
        .init(
            x: startMM.x + cos(angleRadians) * lengthMM,
            y: startMM.y + sin(angleRadians) * lengthMM
        )
    }
}

public struct PLYStructuralSeed: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: PLYStructuralKind
    /// Plan-space center in the same local millimetre coordinates as wall seeds.
    public var centerMM: PLYPoint2D
    /// Long dimension in plan. For columns this is one footprint dimension; for beams this is span.
    public var widthMM: Double
    /// Short plan dimension / member breadth.
    public var depthMM: Double
    /// Vertical member dimension. Columns use storey height; beams use beam depth.
    public var heightMM: Double
    /// Base elevation above the reconstructed local floor. Columns normally use 0.
    public var elevationMM: Double
    public var rotationRadians: Double
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        kind: PLYStructuralKind,
        centerMM: PLYPoint2D,
        widthMM: Double,
        depthMM: Double,
        heightMM: Double,
        elevationMM: Double = 0,
        rotationRadians: Double = 0,
        confidence: Double
    ) {
        self.id = id
        self.kind = kind
        self.centerMM = centerMM
        self.widthMM = widthMM
        self.depthMM = depthMM
        self.heightMM = heightMM
        self.elevationMM = elevationMM
        self.rotationRadians = rotationRadians
        self.confidence = confidence
    }
}

public struct PLYWallAssessment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { seed.id }
    public var seed: PLYWallSeed
    public var status: PLYCandidateStatus
    public var score: Double
    public var reason: String

    public init(seed: PLYWallSeed, status: PLYCandidateStatus, score: Double, reason: String) {
        self.seed = seed
        self.status = status
        self.score = score
        self.reason = reason
    }
}

public struct PLYStructuralAssessment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { seed.id }
    public var seed: PLYStructuralSeed
    public var status: PLYCandidateStatus
    public var score: Double
    public var reason: String

    public init(seed: PLYStructuralSeed, status: PLYCandidateStatus, score: Double, reason: String) {
        self.seed = seed
        self.status = status
        self.score = score
        self.reason = reason
    }
}

public struct PLYReconstructionQA: Codable, Hashable, Sendable {
    public var status: PLYQAStatus
    /// Fraction of downsampled section points lying within the support-distance of a semantic wall face.
    /// This is evidence support, not a claim that all other points are noise.
    public var wallSupportFraction: Double
    public var meanSupportedResidualMM: Double?
    public var p95SupportedResidualMM: Double?
    public var unresolvedWallEnds: Int
    public var acceptedWallCount: Int
    public var reviewWallCount: Int
    public var suppressedWallCount: Int
    public var acceptedStructuralCount: Int
    public var reviewStructuralCount: Int
    public var suppressedStructuralCount: Int
    public var fittedSegmentCount: Int
    public var semanticWallLengthMM: Double

    public init(
        status: PLYQAStatus = .fail,
        wallSupportFraction: Double = 0,
        meanSupportedResidualMM: Double? = nil,
        p95SupportedResidualMM: Double? = nil,
        unresolvedWallEnds: Int = 0,
        acceptedWallCount: Int = 0,
        reviewWallCount: Int = 0,
        suppressedWallCount: Int = 0,
        acceptedStructuralCount: Int = 0,
        reviewStructuralCount: Int = 0,
        suppressedStructuralCount: Int = 0,
        fittedSegmentCount: Int = 0,
        semanticWallLengthMM: Double = 0
    ) {
        self.status = status
        self.wallSupportFraction = wallSupportFraction
        self.meanSupportedResidualMM = meanSupportedResidualMM
        self.p95SupportedResidualMM = p95SupportedResidualMM
        self.unresolvedWallEnds = unresolvedWallEnds
        self.acceptedWallCount = acceptedWallCount
        self.reviewWallCount = reviewWallCount
        self.suppressedWallCount = suppressedWallCount
        self.acceptedStructuralCount = acceptedStructuralCount
        self.reviewStructuralCount = reviewStructuralCount
        self.suppressedStructuralCount = suppressedStructuralCount
        self.fittedSegmentCount = fittedSegmentCount
        self.semanticWallLengthMM = semanticWallLengthMM
    }
}

public struct PLYReconstructionResult: Codable, Hashable, Sendable {
    public var sourceName: String
    public var sourcePointCount: Int
    public var upAxisUsed: PLYUpAxis
    public var sectionHeightUsedMM: Double
    public var baseZMM: Double
    public var localOriginMM: PLYPoint3D
    public var sectionPointCount: Int
    public var downsampledPointCount: Int
    public var sectionPointsMM: [PLYPoint2D]
    public var segments: [PLYPlanSegment]
    /// Automatically accepted semantic wall candidates.
    public var wallSeeds: [PLYWallSeed]
    /// Plausible but weaker walls retained for explicit human review.
    public var reviewWallSeeds: [PLYWallSeed]
    /// Rejected geometric noise retained only for audit/visual comparison.
    public var suppressedWallSeeds: [PLYWallSeed]
    /// Automatically accepted structural candidates.
    public var structuralSeeds: [PLYStructuralSeed]
    public var reviewStructuralSeeds: [PLYStructuralSeed]
    public var suppressedStructuralSeeds: [PLYStructuralSeed]
    public var wallAssessments: [PLYWallAssessment]
    public var structuralAssessments: [PLYStructuralAssessment]
    public var qa: PLYReconstructionQA

    public init(
        sourceName: String,
        sourcePointCount: Int,
        upAxisUsed: PLYUpAxis = .z,
        sectionHeightUsedMM: Double = 1200,
        baseZMM: Double,
        localOriginMM: PLYPoint3D,
        sectionPointCount: Int,
        downsampledPointCount: Int,
        sectionPointsMM: [PLYPoint2D],
        segments: [PLYPlanSegment],
        wallSeeds: [PLYWallSeed],
        reviewWallSeeds: [PLYWallSeed] = [],
        suppressedWallSeeds: [PLYWallSeed] = [],
        structuralSeeds: [PLYStructuralSeed] = [],
        reviewStructuralSeeds: [PLYStructuralSeed] = [],
        suppressedStructuralSeeds: [PLYStructuralSeed] = [],
        wallAssessments: [PLYWallAssessment] = [],
        structuralAssessments: [PLYStructuralAssessment] = [],
        qa: PLYReconstructionQA = .init()
    ) {
        self.sourceName = sourceName
        self.sourcePointCount = sourcePointCount
        self.upAxisUsed = upAxisUsed
        self.sectionHeightUsedMM = sectionHeightUsedMM
        self.baseZMM = baseZMM
        self.localOriginMM = localOriginMM
        self.sectionPointCount = sectionPointCount
        self.downsampledPointCount = downsampledPointCount
        self.sectionPointsMM = sectionPointsMM
        self.segments = segments
        self.wallSeeds = wallSeeds
        self.reviewWallSeeds = reviewWallSeeds
        self.suppressedWallSeeds = suppressedWallSeeds
        self.structuralSeeds = structuralSeeds
        self.reviewStructuralSeeds = reviewStructuralSeeds
        self.suppressedStructuralSeeds = suppressedStructuralSeeds
        self.wallAssessments = wallAssessments
        self.structuralAssessments = structuralAssessments
        self.qa = qa
    }
}
