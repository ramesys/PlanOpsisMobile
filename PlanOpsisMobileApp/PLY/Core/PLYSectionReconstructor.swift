import Foundation

public struct PLYSectionReconstructor: Sendable {
    public init() {}

    public func reconstruct(cloud: PLYPointCloud, settings: PLYSectionSettings) -> PLYReconstructionResult {
        guard !cloud.points.isEmpty else {
            return .init(
                sourceName: cloud.sourceName,
                sourcePointCount: 0,
                upAxisUsed: settings.upAxis == .auto ? .z : settings.upAxis,
                sectionHeightUsedMM: settings.sectionHeightMM,
                baseZMM: 0,
                localOriginMM: .init(x: 0, y: 0, z: 0),
                sectionPointCount: 0,
                downsampledPointCount: 0,
                sectionPointsMM: [],
                segments: [],
                wallSeeds: []
            )
        }

        // Keep the source cloud in its compact imported representation. Axis remapping and unit
        // conversion are applied on demand so a large PLY is not duplicated in memory on iPhone.
        let scale = cloud.sourceUnit.millimetersPerUnit
        let axis = resolvedUpAxis(points: cloud.points, scale: scale, settings: settings)
        let bounds = projectedBounds(cloud.points, axis: axis, scale: scale)
        let baseZ = lowerPercentileVerticalHistogram(
            cloud.points,
            axis: axis,
            scale: scale,
            minVerticalMM: bounds.minW,
            maxVerticalMM: bounds.maxW,
            percentile: 0.02
        )

        let sectionHeight = resolvedSectionHeight(
            points: cloud.points,
            axis: axis,
            scale: scale,
            baseZMM: baseZ,
            verticalSpanMM: bounds.maxW - bounds.minW,
            settings: settings
        )
        let targetZ = baseZ + sectionHeight
        let halfThickness = max(1, settings.sectionThicknessMM * 0.5)
        let origin = PLYPoint3D(
            x: (bounds.minU + bounds.maxU) * 0.5,
            y: (bounds.minV + bounds.maxV) * 0.5,
            z: baseZ
        )

        var rawSection: [PLYPoint2D] = []
        rawSection.reserveCapacity(min(cloud.points.count / 8, 250_000))
        for p in cloud.points {
            let q = project(p, axis: axis, scale: scale)
            guard abs(q.w - targetZ) <= halfThickness else { continue }
            rawSection.append(.init(x: q.u - origin.x, y: q.v - origin.y))
        }

        let sectionPointCount = rawSection.count
        let downsampled = voxelDownsample(rawSection, cellMM: max(1, settings.voxelSizeMM))
        rawSection.removeAll(keepingCapacity: false)

        var segments = houghSegments(points: downsampled, settings: settings)
        segments = mergeCollinear(segments, settings: settings)
        segments = snapEndpoints(segments, thresholdMM: settings.endpointSnapMM)
        let rawWalls = PLYWallCandidateEngine().makeWallSeeds(from: segments, settings: settings)
        let rawStructure = settings.detectStructuralElements
            ? PLYStructuralCandidateEngine().detect(
                cloud: cloud,
                upAxis: axis,
                baseZMM: baseZ,
                localOriginMM: origin,
                walls: rawWalls,
                settings: settings
            )
            : []

        // v11.8: geometry is not semantic merely because it was detected. Score each candidate
        // against scan support, fitting error, length and topology, then keep weak objects in a
        // review/evidence layer instead of silently polluting the authoritative PlanOpsis model.
        let evaluation = PLYReconstructionQAEngine().evaluate(
            sectionPoints: downsampled,
            segments: segments,
            walls: rawWalls,
            structure: rawStructure,
            settings: settings
        )

        return .init(
            sourceName: cloud.sourceName,
            sourcePointCount: cloud.points.count,
            upAxisUsed: axis,
            sectionHeightUsedMM: sectionHeight,
            baseZMM: baseZ,
            localOriginMM: origin,
            sectionPointCount: sectionPointCount,
            downsampledPointCount: downsampled.count,
            sectionPointsMM: downsampled,
            segments: segments,
            wallSeeds: evaluation.acceptedWalls,
            reviewWallSeeds: evaluation.reviewWalls,
            suppressedWallSeeds: evaluation.suppressedWalls,
            structuralSeeds: evaluation.acceptedStructure,
            reviewStructuralSeeds: evaluation.reviewStructure,
            suppressedStructuralSeeds: evaluation.suppressedStructure,
            wallAssessments: evaluation.wallAssessments,
            structuralAssessments: evaluation.structuralAssessments,
            qa: evaluation.qa
        )
    }

    /// Shared deterministic line fitting used by the high-level wall section and the upper-level
    /// structural beam candidate pass. The input is already expressed in local plan millimetres.
    func fitPlanSegmentsForEvidence(_ points: [PLYPoint2D], settings: PLYSectionSettings) -> [PLYPlanSegment] {
        var segments = houghSegments(points: points, settings: settings)
        segments = mergeCollinear(segments, settings: settings)
        return snapEndpoints(segments, thresholdMM: settings.endpointSnapMM)
    }
}

private extension PLYSectionReconstructor {
    typealias LineCandidate = (index: Int, point: PLYPoint2D, t: Double, distance: Double)
    struct GridKey: Hashable { let x: Int64; let y: Int64 }
    struct Accumulator { var sx = 0.0; var sy = 0.0; var count = 0 }
    struct ProjectedPoint { var u: Double; var v: Double; var w: Double }
    struct ProjectedBounds {
        var minU: Double; var minV: Double; var minW: Double
        var maxU: Double; var maxV: Double; var maxW: Double
    }

    func project(_ p: PLYPoint3D, axis: PLYUpAxis, scale: Double) -> ProjectedPoint {
        switch axis {
        case .x:
            // X is vertical; Y/Z form the plan plane.
            return .init(u: p.y * scale, v: p.z * scale, w: p.x * scale)
        case .y:
            // Common in graphics/mesh exports: Y is vertical; X/Z form the plan plane.
            return .init(u: p.x * scale, v: p.z * scale, w: p.y * scale)
        case .z, .auto:
            return .init(u: p.x * scale, v: p.y * scale, w: p.z * scale)
        }
    }

    func projectedBounds(_ points: [PLYPoint3D], axis: PLYUpAxis, scale: Double) -> ProjectedBounds {
        guard let first = points.first else { return .init(minU: 0, minV: 0, minW: 0, maxU: 0, maxV: 0, maxW: 0) }
        let f = project(first, axis: axis, scale: scale)
        var b = ProjectedBounds(minU: f.u, minV: f.v, minW: f.w, maxU: f.u, maxV: f.v, maxW: f.w)
        for p in points.dropFirst() {
            let q = project(p, axis: axis, scale: scale)
            b.minU = min(b.minU, q.u); b.minV = min(b.minV, q.v); b.minW = min(b.minW, q.w)
            b.maxU = max(b.maxU, q.u); b.maxV = max(b.maxV, q.v); b.maxW = max(b.maxW, q.w)
        }
        return b
    }

    /// Auto-axis is intentionally conservative and remains user-overridable. Indoor scans usually
    /// have a vertical extent smaller than both plan extents; the section-support term prevents a
    /// pure bounding-box guess when the cloud is cropped or elongated.
    func resolvedUpAxis(points: [PLYPoint3D], scale: Double, settings: PLYSectionSettings) -> PLYUpAxis {
        guard settings.upAxis == .auto else { return settings.upAxis }
        let candidates: [PLYUpAxis] = [.x, .y, .z]
        var best: (axis: PLYUpAxis, score: Double) = (.z, -.infinity)
        for axis in candidates {
            let b = projectedBounds(points, axis: axis, scale: scale)
            let verticalSpan = max(1, b.maxW - b.minW)
            let planShort = max(1, min(b.maxU - b.minU, b.maxV - b.minV))
            let base = lowerPercentileVerticalHistogram(
                points, axis: axis, scale: scale,
                minVerticalMM: b.minW, maxVerticalMM: b.maxW, percentile: 0.02
            )
            let target = base + settings.sectionHeightMM
            let half = max(1, settings.sectionThicknessMM * 0.5)
            var support = 0
            if target <= b.maxW + half {
                for p in points {
                    if abs(project(p, axis: axis, scale: scale).w - target) <= half { support += 1 }
                }
            }
            let extentRatio = min(4.0, planShort / verticalSpan)
            let supportScore = log(Double(support) + 1.0)
            // If the axis cannot even contain a normal plan section, heavily penalize it.
            let feasibility = verticalSpan >= min(600, settings.sectionHeightMM * 0.75) ? 1.0 : 0.05
            let score = feasibility * (supportScore + 1.25 * extentRatio)
            if score > best.score { best = (axis, score) }
        }
        return best.axis
    }

    /// If the requested 1.2 m section happens to cross an occluded/sparse band, choose a nearby
    /// architectural section height with materially stronger evidence. This avoids returning zero
    /// lines just because the scan has gaps at one exact elevation.
    func resolvedSectionHeight(
        points: [PLYPoint3D],
        axis: PLYUpAxis,
        scale: Double,
        baseZMM: Double,
        verticalSpanMM: Double,
        settings: PLYSectionSettings
    ) -> Double {
        let half = max(1, settings.sectionThicknessMM * 0.5)
        var heights = [settings.sectionHeightMM, 600, 900, 1200, 1500, 1800, 2100]
        heights = Array(Set(heights.map { Int($0.rounded()) }))
            .map(Double.init)
            .filter { $0 >= 250 && $0 <= max(250, verticalSpanMM + half) }
            .sorted()
        guard !heights.isEmpty else { return settings.sectionHeightMM }

        var counts = Dictionary(uniqueKeysWithValues: heights.map { ($0, 0) })
        for p in points {
            let w = project(p, axis: axis, scale: scale).w
            for h in heights where abs(w - (baseZMM + h)) <= half {
                counts[h, default: 0] += 1
            }
        }
        let requested = heights.min(by: { abs($0 - settings.sectionHeightMM) < abs($1 - settings.sectionHeightMM) }) ?? heights[0]
        let requestedCount = counts[requested] ?? 0
        let best = heights.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) }) ?? requested
        let bestCount = counts[best] ?? 0
        let sufficient = max(settings.minLineSupport * 3, 24)
        if requestedCount >= sufficient && Double(requestedCount) >= Double(bestCount) * 0.55 {
            return requested
        }
        return bestCount > requestedCount ? best : requested
    }

    /// Approximate a low vertical percentile with a compact deterministic histogram rather than
    /// sorting an O(n) copy. This is used as the local floor/base estimate for the chosen up axis.
    func lowerPercentileVerticalHistogram(
        _ points: [PLYPoint3D],
        axis: PLYUpAxis,
        scale: Double,
        minVerticalMM: Double,
        maxVerticalMM: Double,
        percentile: Double
    ) -> Double {
        let span = maxVerticalMM - minVerticalMM
        guard !points.isEmpty, span > 1e-9 else { return minVerticalMM }

        let binCount = 4096
        var bins = Array(repeating: 0, count: binCount)
        let invSpan = Double(binCount - 1) / span
        for p in points {
            let w = project(p, axis: axis, scale: scale).w
            let raw = Int((w - minVerticalMM) * invSpan)
            let index = min(binCount - 1, max(0, raw))
            bins[index] += 1
        }

        let p = min(max(percentile, 0), 1)
        let target = max(0, min(points.count - 1, Int(Double(points.count - 1) * p)))
        var cumulative = 0
        for (index, count) in bins.enumerated() {
            cumulative += count
            if cumulative > target {
                let t = Double(index) / Double(binCount - 1)
                return minVerticalMM + t * span
            }
        }
        return maxVerticalMM
    }

    func voxelDownsample(_ points: [PLYPoint2D], cellMM: Double) -> [PLYPoint2D] {
        var cells: [GridKey: Accumulator] = [:]
        cells.reserveCapacity(points.count)
        for p in points {
            let key = GridKey(x: Int64(floor(p.x / cellMM)), y: Int64(floor(p.y / cellMM)))
            var a = cells[key] ?? .init()
            a.sx += p.x; a.sy += p.y; a.count += 1
            cells[key] = a
        }
        return cells.keys
            .sorted { lhs, rhs in lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x }
            .compactMap { key in
                guard let a = cells[key] else { return nil }
                return .init(x: a.sx / Double(a.count), y: a.sy / Double(a.count))
            }
    }

    func houghSegments(points: [PLYPoint2D], settings: PLYSectionSettings) -> [PLYPlanSegment] {
        guard points.count >= settings.minLineSupport else { return [] }
        var remaining = points
        var output: [PLYPlanSegment] = []
        let angleStep = max(0.5, settings.angleStepDegrees) * .pi / 180
        let angleBins = max(2, Int(ceil(.pi / angleStep)))
        let tolerance = max(1, settings.lineToleranceMM)
        let rhoResolution = max(tolerance, settings.voxelSizeMM)

        while remaining.count >= settings.minLineSupport && output.count < settings.maxSegments {
            let center = centroid(remaining)
            var maxRadius = 0.0
            for p in remaining { maxRadius = max(maxRadius, hypot(p.x - center.x, p.y - center.y)) }
            let rhoBins = max(3, Int(ceil((2 * maxRadius) / rhoResolution)) + 3)
            var votes = Array(repeating: 0, count: angleBins * rhoBins)

            for p in remaining {
                let px = p.x - center.x, py = p.y - center.y
                for ai in 0..<angleBins {
                    let theta = Double(ai) * angleStep
                    let rho = px * cos(theta) + py * sin(theta)
                    let ri = Int(floor((rho + maxRadius) / rhoResolution)) + 1
                    if ri >= 0 && ri < rhoBins { votes[ai * rhoBins + ri] += 1 }
                }
            }

            guard let bestFlat = votes.indices.max(by: { votes[$0] < votes[$1] }) else { break }
            let bestVotes = votes[bestFlat]
            if bestVotes < settings.minLineSupport { break }
            let ai = bestFlat / rhoBins
            let ri = bestFlat % rhoBins
            let theta = Double(ai) * angleStep
            let normal = PLYPoint2D(x: cos(theta), y: sin(theta))
            let direction = PLYPoint2D(x: -sin(theta), y: cos(theta))
            let rho = (Double(ri - 1) + 0.5) * rhoResolution - maxRadius

            var candidates: [LineCandidate] = []
            candidates.reserveCapacity(bestVotes * 2)
            for (index, p) in remaining.enumerated() {
                let rel = p - center
                let pointRho = rel.x * normal.x + rel.y * normal.y
                let distance = abs(pointRho - rho)
                if distance <= tolerance {
                    let t = rel.x * direction.x + rel.y * direction.y
                    candidates.append((index, p, t, distance))
                }
            }
            if candidates.count < settings.minLineSupport { break }
            candidates.sort { $0.t < $1.t }

            let clusters = splitByGap(candidates, maxGapMM: max(settings.maxGapMM, settings.voxelSizeMM * 2))
            guard let cluster = clusters
                .filter({ $0.count >= settings.minLineSupport })
                .max(by: { clusterScore($0) < clusterScore($1) }) else { break }

            guard let first = cluster.first, let last = cluster.last else { break }
            let length = last.t - first.t
            if length < settings.minSegmentLengthMM {
                let remove = Set(cluster.map(\.index))
                remaining = remaining.enumerated().compactMap { remove.contains($0.offset) ? nil : $0.element }
                continue
            }

            let linePoint = center + normal * rho
            let start = linePoint + direction * first.t
            let end = linePoint + direction * last.t
            let rms = sqrt(cluster.reduce(0.0) { $0 + $1.distance * $1.distance } / Double(cluster.count))
            output.append(.init(start: start, end: end, support: cluster.count, rmsErrorMM: rms))

            let remove = Set(cluster.map(\.index))
            remaining = remaining.enumerated().compactMap { remove.contains($0.offset) ? nil : $0.element }
        }
        return output
    }

    func centroid(_ points: [PLYPoint2D]) -> PLYPoint2D {
        guard !points.isEmpty else { return .init(x: 0, y: 0) }
        var x = 0.0, y = 0.0
        for p in points { x += p.x; y += p.y }
        return .init(x: x / Double(points.count), y: y / Double(points.count))
    }

    func splitByGap(_ points: [LineCandidate], maxGapMM: Double) -> [[LineCandidate]] {
        guard !points.isEmpty else { return [] }
        var result: [[LineCandidate]] = [[points[0]]]
        for item in points.dropFirst() {
            if let last = result[result.count - 1].last, item.t - last.t > maxGapMM {
                result.append([item])
            } else {
                result[result.count - 1].append(item)
            }
        }
        return result
    }

    func clusterScore(_ cluster: [LineCandidate]) -> Double {
        guard let first = cluster.first, let last = cluster.last else { return 0 }
        return Double(cluster.count) * max(1, last.t - first.t)
    }

    func mergeCollinear(_ input: [PLYPlanSegment], settings: PLYSectionSettings) -> [PLYPlanSegment] {
        var segments = input.sorted { $0.lengthMM > $1.lengthMM }
        var output: [PLYPlanSegment] = []
        let angleTolerance = max(2, settings.angleStepDegrees * 1.5) * .pi / 180
        let distanceTolerance = max(settings.lineToleranceMM * 1.5, settings.voxelSizeMM)
        let gapTolerance = max(settings.maxGapMM, settings.voxelSizeMM * 2)

        while !segments.isEmpty {
            var base = segments.removeFirst()
            var didMerge = true
            while didMerge {
                didMerge = false
                var index = 0
                while index < segments.count {
                    let other = segments[index]
                    if areCollinear(base, other, angleTolerance: angleTolerance, distanceTolerance: distanceTolerance, gapTolerance: gapTolerance) {
                        base = merge(base, other)
                        segments.remove(at: index)
                        didMerge = true
                    } else {
                        index += 1
                    }
                }
            }
            output.append(base)
        }
        return output
    }

    func areCollinear(_ a: PLYPlanSegment, _ b: PLYPlanSegment, angleTolerance: Double, distanceTolerance: Double, gapTolerance: Double) -> Bool {
        let da = a.direction, db = b.direction
        let dot = abs(da.x * db.x + da.y * db.y)
        let angle = acos(min(1, max(-1, dot)))
        guard angle <= angleTolerance else { return false }
        let normal = PLYPoint2D(x: -da.y, y: da.x)
        let lineDistance = abs((b.start.x - a.start.x) * normal.x + (b.start.y - a.start.y) * normal.y)
        guard lineDistance <= distanceTolerance else { return false }
        let tA0 = 0.0, tA1 = a.lengthMM
        let relB0 = b.start - a.start, relB1 = b.end - a.start
        let tB0 = relB0.x * da.x + relB0.y * da.y
        let tB1 = relB1.x * da.x + relB1.y * da.y
        let bMin = min(tB0, tB1), bMax = max(tB0, tB1)
        let gap = max(0, max(bMin - tA1, tA0 - bMax))
        return gap <= gapTolerance
    }

    func merge(_ a: PLYPlanSegment, _ b: PLYPlanSegment) -> PLYPlanSegment {
        let d = a.direction
        let points = [a.start, a.end, b.start, b.end]
        let ts = points.map { p -> Double in
            let r = p - a.start
            return r.x * d.x + r.y * d.y
        }
        let minT = ts.min() ?? 0, maxT = ts.max() ?? a.lengthMM
        return .init(
            id: a.id,
            start: a.start + d * minT,
            end: a.start + d * maxT,
            support: a.support + b.support,
            rmsErrorMM: (a.rmsErrorMM * Double(a.support) + b.rmsErrorMM * Double(b.support)) / Double(max(1, a.support + b.support))
        )
    }

    func snapEndpoints(_ input: [PLYPlanSegment], thresholdMM: Double) -> [PLYPlanSegment] {
        guard thresholdMM > 0 else { return input }
        var output = input
        for i in output.indices {
            for j in output.indices where j > i {
                var candidates: [(Double, Int, Int)] = []
                let a = [output[i].start, output[i].end]
                let b = [output[j].start, output[j].end]
                for ai in 0...1 { for bi in 0...1 { candidates.append(((a[ai] - b[bi]).length, ai, bi)) } }
                guard let best = candidates.min(by: { $0.0 < $1.0 }), best.0 <= thresholdMM else { continue }
                let pA = best.1 == 0 ? output[i].start : output[i].end
                let pB = best.2 == 0 ? output[j].start : output[j].end
                let snap = PLYPoint2D(x: (pA.x + pB.x) * 0.5, y: (pA.y + pB.y) * 0.5)
                if best.1 == 0 { output[i].start = snap } else { output[i].end = snap }
                if best.2 == 0 { output[j].start = snap } else { output[j].end = snap }
            }
        }
        return output.filter { $0.lengthMM > 1 }
    }
}



// MARK: - Reconstruction QA / noise suppression

/// Converts geometric detections into three explicit states: accepted semantic candidates,
/// human-review candidates, and suppressed scan noise. The scoring is deterministic and leaves
/// every rejected candidate available in the reconstruction result for audit/visual comparison.
public struct PLYReconstructionQAEngine {
    public init() {}
    struct Evaluation {
        var acceptedWalls: [PLYWallSeed]
        var reviewWalls: [PLYWallSeed]
        var suppressedWalls: [PLYWallSeed]
        var acceptedStructure: [PLYStructuralSeed]
        var reviewStructure: [PLYStructuralSeed]
        var suppressedStructure: [PLYStructuralSeed]
        var wallAssessments: [PLYWallAssessment]
        var structuralAssessments: [PLYStructuralAssessment]
        var qa: PLYReconstructionQA
    }

    func evaluate(
        sectionPoints: [PLYPoint2D],
        segments: [PLYPlanSegment],
        walls: [PLYWallSeed],
        structure: [PLYStructuralSeed],
        settings: PLYSectionSettings
    ) -> Evaluation {
        let segmentByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let connectionTolerance = min(300.0, max(55.0, settings.endpointSnapMM * 1.6, settings.lineToleranceMM * 1.6))

        var wallAssessments: [PLYWallAssessment] = []
        for (index, wall) in walls.enumerated() {
            let source = wall.sourceSegmentIDs.compactMap { segmentByID[$0] }
            let support = source.reduce(0) { $0 + $1.support }
            let averageRMS: Double
            if source.isEmpty {
                averageRMS = settings.lineToleranceMM
            } else {
                averageRMS = source.reduce(0.0) { $0 + $1.rmsErrorMM } / Double(source.count)
            }
            let connected = connectedEndpointCount(wallIndex: index, walls: walls, toleranceMM: connectionTolerance)
            let supportScore = clamp(Double(support) / Double(max(30, settings.minLineSupport * 5)))
            let errorScore = clamp(1.0 - averageRMS / max(1.0, settings.lineToleranceMM * 1.6))
            let lengthScore = clamp(wall.lengthMM / max(1_200.0, settings.minSegmentLengthMM * 4.0))
            let topologyScore = Double(connected) / 2.0
            let pairedBonus = wall.inferenceKind == .pairedFaces ? 0.05 : 0.0
            let score = clamp(
                0.34 * clamp(wall.confidence) +
                0.20 * supportScore +
                0.17 * errorScore +
                0.14 * lengthScore +
                0.15 * topologyScore + pairedBonus
            )

            let status: PLYCandidateStatus
            let reason: String
            if !settings.noiseSuppressionEnabled {
                status = .accepted
                reason = "Noise suppression disabled."
            } else if score >= settings.automaticWallAcceptanceScore || (connected == 2 && score >= settings.wallSuppressionScore + 0.08) {
                status = .accepted
                reason = "Strong scan support and/or joined wall topology."
            } else if score < settings.wallSuppressionScore && connected == 0 && wall.lengthMM < max(1_300, settings.minSegmentLengthMM * 2.4) {
                status = .suppressed
                reason = "Weak isolated wall-like fragment."
            } else {
                status = .review
                reason = connected == 0 ? "Plausible wall but disconnected from the main network." : "Plausible wall with marginal scan support."
            }
            wallAssessments.append(.init(seed: wall, status: status, score: score, reason: reason))
        }

        var structuralAssessments: [PLYStructuralAssessment] = []
        for seed in structure {
            let dimensionalScore: Double
            switch seed.kind {
            case .column:
                let long = max(seed.widthMM, seed.depthMM)
                let short = min(seed.widthMM, seed.depthMM)
                dimensionalScore = clamp(short / max(long, 1) * 1.8)
            case .beam:
                dimensionalScore = clamp(seed.widthMM / 2_500.0)
            }
            let score = clamp(0.78 * seed.confidence + 0.22 * dimensionalScore)
            let acceptThreshold = seed.kind == .column ? 0.82 : 0.80
            let suppressThreshold = seed.kind == .column ? 0.66 : 0.64
            let status: PLYCandidateStatus
            let reason: String
            if !settings.noiseSuppressionEnabled {
                status = .accepted
                reason = "Noise suppression disabled."
            } else if score >= acceptThreshold {
                status = .accepted
                reason = "Persistent high-confidence structural geometry."
            } else if score < suppressThreshold {
                status = .suppressed
                reason = "Insufficient evidence for automatic structural promotion."
            } else {
                status = .review
                reason = "Possible structural element; human confirmation required."
            }
            structuralAssessments.append(.init(seed: seed, status: status, score: score, reason: reason))
        }

        let acceptedWalls = wallAssessments.filter { $0.status == .accepted }.map(\.seed)
        let reviewWalls = wallAssessments.filter { $0.status == .review }.map(\.seed)
        let suppressedWalls = wallAssessments.filter { $0.status == .suppressed }.map(\.seed)
        let acceptedStructure = structuralAssessments.filter { $0.status == .accepted }.map(\.seed)
        let reviewStructure = structuralAssessments.filter { $0.status == .review }.map(\.seed)
        let suppressedStructure = structuralAssessments.filter { $0.status == .suppressed }.map(\.seed)

        let residuals = supportedWallResiduals(
            points: sectionPoints,
            walls: acceptedWalls,
            supportDistanceMM: max(40, settings.qaWallSupportDistanceMM)
        )
        let supportFraction = sectionPoints.isEmpty ? 0 : Double(residuals.count) / Double(sectionPoints.count)
        let mean = residuals.isEmpty ? nil : residuals.reduce(0, +) / Double(residuals.count)
        let p95 = percentile(residuals, 0.95)
        let unresolved = unresolvedWallEnds(in: acceptedWalls, toleranceMM: connectionTolerance)

        let status: PLYQAStatus
        if acceptedWalls.isEmpty {
            status = .fail
        } else if unresolved > max(2, acceptedWalls.count / 2) {
            status = .fail
        } else if unresolved > 0 || supportFraction < 0.12 || (p95 ?? 0) > max(180, settings.qaWallSupportDistanceMM * 1.25) || !reviewWalls.isEmpty {
            status = .review
        } else {
            status = .pass
        }

        let qa = PLYReconstructionQA(
            status: status,
            wallSupportFraction: supportFraction,
            meanSupportedResidualMM: mean,
            p95SupportedResidualMM: p95,
            unresolvedWallEnds: unresolved,
            acceptedWallCount: acceptedWalls.count,
            reviewWallCount: reviewWalls.count,
            suppressedWallCount: suppressedWalls.count,
            acceptedStructuralCount: acceptedStructure.count,
            reviewStructuralCount: reviewStructure.count,
            suppressedStructuralCount: suppressedStructure.count,
            fittedSegmentCount: segments.count,
            semanticWallLengthMM: acceptedWalls.reduce(0) { $0 + $1.lengthMM }
        )

        return .init(
            acceptedWalls: acceptedWalls,
            reviewWalls: reviewWalls,
            suppressedWalls: suppressedWalls,
            acceptedStructure: acceptedStructure,
            reviewStructure: reviewStructure,
            suppressedStructure: suppressedStructure,
            wallAssessments: wallAssessments,
            structuralAssessments: structuralAssessments,
            qa: qa
        )
    }

    /// Recomputes reconstruction quality for the exact human-reviewed geometry that would be
    /// committed to PlanOpsis. Unlike `evaluate`, this method does not reclassify the chosen
    /// candidates; human inclusion/exclusion decisions are treated as authoritative for the review
    /// stage and the report only measures support, residuals and topology.
    public func reviewedReport(
        sectionPoints: [PLYPoint2D],
        segments: [PLYPlanSegment],
        walls: [PLYWallSeed],
        structure: [PLYStructuralSeed],
        settings: PLYSectionSettings
    ) -> PLYReconstructionQA {
        let connectionTolerance = min(
            300.0,
            max(55.0, settings.endpointSnapMM * 1.6, settings.lineToleranceMM * 1.6)
        )
        let residuals = supportedWallResiduals(
            points: sectionPoints,
            walls: walls,
            supportDistanceMM: max(40, settings.qaWallSupportDistanceMM)
        )
        let supportFraction = sectionPoints.isEmpty ? 0 : Double(residuals.count) / Double(sectionPoints.count)
        let mean = residuals.isEmpty ? nil : residuals.reduce(0, +) / Double(residuals.count)
        let p95 = percentile(residuals, 0.95)
        let unresolved = unresolvedWallEnds(in: walls, toleranceMM: connectionTolerance)

        let status: PLYQAStatus
        if walls.isEmpty {
            status = .fail
        } else if unresolved > max(2, walls.count / 2) {
            status = .fail
        } else if unresolved > 0 ||
                    supportFraction < 0.12 ||
                    (p95 ?? 0) > max(180, settings.qaWallSupportDistanceMM * 1.25) {
            status = .review
        } else {
            status = .pass
        }

        return .init(
            status: status,
            wallSupportFraction: supportFraction,
            meanSupportedResidualMM: mean,
            p95SupportedResidualMM: p95,
            unresolvedWallEnds: unresolved,
            acceptedWallCount: walls.count,
            reviewWallCount: 0,
            suppressedWallCount: 0,
            acceptedStructuralCount: structure.count,
            reviewStructuralCount: 0,
            suppressedStructuralCount: 0,
            fittedSegmentCount: segments.count,
            semanticWallLengthMM: walls.reduce(0) { $0 + $1.lengthMM }
        )
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }

    private func connectedEndpointCount(wallIndex: Int, walls: [PLYWallSeed], toleranceMM: Double) -> Int {
        guard walls.indices.contains(wallIndex) else { return 0 }
        let wall = walls[wallIndex]
        return [wall.startMM, wall.endMM].reduce(0) { count, point in
            count + (endpointConnected(point, owner: wallIndex, walls: walls, toleranceMM: toleranceMM) ? 1 : 0)
        }
    }

    private func endpointConnected(_ point: PLYPoint2D, owner: Int, walls: [PLYWallSeed], toleranceMM: Double) -> Bool {
        for index in walls.indices where index != owner {
            if (walls[index].startMM - point).length <= toleranceMM ||
                (walls[index].endMM - point).length <= toleranceMM ||
                pointToSegmentDistance(point, a: walls[index].startMM, b: walls[index].endMM) <= toleranceMM {
                return true
            }
        }
        return false
    }

    private func unresolvedWallEnds(in walls: [PLYWallSeed], toleranceMM: Double) -> Int {
        var count = 0
        for index in walls.indices {
            for point in [walls[index].startMM, walls[index].endMM] where !endpointConnected(point, owner: index, walls: walls, toleranceMM: toleranceMM) {
                count += 1
            }
        }
        return count
    }

    private func supportedWallResiduals(points: [PLYPoint2D], walls: [PLYWallSeed], supportDistanceMM: Double) -> [Double] {
        guard !walls.isEmpty else { return [] }
        var output: [Double] = []
        output.reserveCapacity(points.count)
        for point in points {
            var best = Double.infinity
            for wall in walls {
                best = min(best, distanceToNearestWallFace(point, wall: wall))
            }
            if best <= supportDistanceMM { output.append(best) }
        }
        return output
    }

    private func distanceToNearestWallFace(_ point: PLYPoint2D, wall: PLYWallSeed) -> Double {
        let d = PLYPoint2D(x: cos(wall.angleRadians), y: sin(wall.angleRadians))
        let n = PLYPoint2D(x: -d.y, y: d.x)
        let offset = n * (wall.thicknessMM * 0.5)
        let a0 = wall.startMM + offset, a1 = wall.endMM + offset
        let b0 = wall.startMM - offset, b1 = wall.endMM - offset
        return min(pointToSegmentDistance(point, a: a0, b: a1), pointToSegmentDistance(point, a: b0, b: b1))
    }

    private func pointToSegmentDistance(_ p: PLYPoint2D, a: PLYPoint2D, b: PLYPoint2D) -> Double {
        let ab = b - a
        let denom = max(1e-9, ab.x * ab.x + ab.y * ab.y)
        let ap = p - a
        let t = min(1.0, max(0.0, (ap.x * ab.x + ap.y * ab.y) / denom))
        return (p - (a + ab * t)).length
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}

// MARK: - Structural candidates

/// Deterministic, review-first structural inference from PLY evidence.
/// It intentionally produces *candidates*: columns require persistent compact vertical evidence and
/// beams require elongated upper-level evidence away from reconstructed wall axes. The user commits
/// these candidates at the same semantic boundary as the reviewed wall reconstruction.
private struct PLYStructuralCandidateEngine {
    struct GridKey: Hashable { var x: Int; var y: Int }
    struct Projected { var plan: PLYPoint2D; var w: Double }

    func detect(
        cloud: PLYPointCloud,
        upAxis: PLYUpAxis,
        baseZMM: Double,
        localOriginMM: PLYPoint3D,
        walls: [PLYWallSeed],
        settings: PLYSectionSettings
    ) -> [PLYStructuralSeed] {
        guard !cloud.points.isEmpty else { return [] }
        let scale = cloud.sourceUnit.millimetersPerUnit
        let grid = max(60, settings.structuralGridMM)
        let bands = structuralBands(defaultHeight: settings.defaultWallHeightMM)
        let halfBand = max(80, min(220, settings.sectionThicknessMM * 0.65))
        let boundary = convexHull(walls.flatMap { [$0.startMM, $0.endMM] })

        var occupancy: [GridKey: UInt8] = [:]
        occupancy.reserveCapacity(min(cloud.points.count / 12, 50_000))

        // A cell gets one bit per vertical band. Wall-adjacent cells are removed before grouping so
        // long wall faces do not masquerade as columns.
        for point in cloud.points {
            let q = project(point, axis: upAxis, scale: scale, origin: localOriginMM)
            let relative = q.w - baseZMM
            var bits: UInt8 = 0
            for (index, band) in bands.enumerated() where abs(relative - band) <= halfBand {
                bits |= UInt8(1 << index)
            }
            guard bits != 0, distanceToWalls(q.plan, walls: walls) > max(180, settings.defaultWallThicknessMM * 0.8) else { continue }
            let key = GridKey(x: Int(floor(q.plan.x / grid)), y: Int(floor(q.plan.y / grid)))
            occupancy[key, default: 0] |= bits
        }

        let persistent = Set(occupancy.compactMap { key, bits in
            // A professional automatic column candidate must persist through all sampled heights.
            // Two-band evidence is too easily produced by furniture, door leaves and scan clutter.
            bits.nonzeroBitCount >= bands.count ? key : nil
        })
        var output = columnSeeds(from: persistent, grid: grid, cloud: cloud, axis: upAxis, scale: scale,
                                 origin: localOriginMM, baseZMM: baseZMM, defaultHeight: settings.defaultWallHeightMM)
            .filter { structuralCenterIsPlausible($0.centerMM, boundary: boundary, marginMM: 260) }

        // Beam evidence is sampled high in the room. Remove reconstructed wall influence, then fit
        // elongated residual lines. This is conservative by design: uncertain members stay candidates.
        let upper = verticalQuantile(cloud.points, axis: upAxis, scale: scale, percentile: 0.97)
        let upperRelative = max(0, upper - baseZMM)
        let beamDepth = max(150, settings.defaultBeamDepthMM)
        let requestedMid = max(1_800, settings.defaultWallHeightMM - beamDepth * 0.5)
        let targetRelative = min(requestedMid, max(1_800, upperRelative - beamDepth * 0.5))
        let beamHalfBand = max(130, beamDepth * 0.65)
        var upperPoints: [PLYPoint2D] = []
        upperPoints.reserveCapacity(min(cloud.points.count / 20, 80_000))
        for point in cloud.points {
            let q = project(point, axis: upAxis, scale: scale, origin: localOriginMM)
            guard abs((q.w - baseZMM) - targetRelative) <= beamHalfBand else { continue }
            guard distanceToWalls(q.plan, walls: walls) > max(220, settings.defaultWallThicknessMM * 1.25) else { continue }
            upperPoints.append(q.plan)
        }
        upperPoints = voxelDownsample(upperPoints, cell: max(35, grid * 0.5))

        if upperPoints.count >= 12 {
            var beamSettings = settings
            beamSettings.professionalCleanup = false
            beamSettings.allowSingleSurfaceWalls = true
            beamSettings.minLineSupport = max(8, min(settings.minLineSupport, 14))
            beamSettings.minSegmentLengthMM = max(800, settings.minSegmentLengthMM)
            beamSettings.lineToleranceMM = max(45, settings.lineToleranceMM)
            beamSettings.maxGapMM = max(300, settings.maxGapMM)
            beamSettings.maxSegments = min(24, settings.maxSegments)
            let segments = PLYSectionReconstructor().fitPlanSegmentsForEvidence(upperPoints, settings: beamSettings)
            let beamBase = max(0, targetRelative - beamDepth * 0.5)
            for segment in segments where segment.lengthMM >= 1_000 {
                let center = PLYPoint2D(x: (segment.start.x + segment.end.x) * 0.5, y: (segment.start.y + segment.end.y) * 0.5)
                guard segment.support >= max(12, beamSettings.minLineSupport),
                      segment.rmsErrorMM <= beamSettings.lineToleranceMM * 1.15,
                      structuralCenterIsPlausible(center, boundary: boundary, marginMM: 180) else { continue }

                // Residual ceiling/wall-top edges are a common false positive. If a candidate is
                // close to a reconstructed wall and nearly parallel to it, keep it as wall evidence
                // rather than inventing a beam.
                if let nearest = nearestWall(to: center, walls: walls) {
                    let angleDelta = abs(sin(segment.angleRadians - nearest.wall.angleRadians))
                    if nearest.distance < max(480, nearest.wall.thicknessMM * 2.5), angleDelta < 0.16 { continue }
                }

                let supportScore = min(1.0, Double(segment.support) / 55.0)
                let errorScore = max(0.0, 1.0 - segment.rmsErrorMM / max(1, beamSettings.lineToleranceMM))
                let lengthScore = min(1.0, segment.lengthMM / 2_500.0)
                let confidence = min(0.94, max(0.50, 0.30 + 0.30 * supportScore + 0.22 * errorScore + 0.12 * lengthScore))
                guard confidence >= 0.68 else { continue }
                output.append(.init(
                    kind: .beam,
                    centerMM: center,
                    widthMM: segment.lengthMM,
                    depthMM: max(120, settings.defaultBeamWidthMM),
                    heightMM: beamDepth,
                    elevationMM: beamBase,
                    rotationRadians: segment.angleRadians,
                    confidence: confidence
                ))
            }
        }

        return deduplicated(output)
    }

    private func structuralBands(defaultHeight: Double) -> [Double] {
        let high = max(1_700, min(2_300, defaultHeight * 0.78))
        return [500, 1_250, high]
    }

    private func project(_ p: PLYPoint3D, axis: PLYUpAxis, scale: Double, origin: PLYPoint3D) -> Projected {
        let u: Double, v: Double, w: Double
        switch axis {
        case .x:
            u = p.y * scale; v = p.z * scale; w = p.x * scale
        case .y:
            u = p.x * scale; v = p.z * scale; w = p.y * scale
        case .z, .auto:
            u = p.x * scale; v = p.y * scale; w = p.z * scale
        }
        return .init(plan: .init(x: u - origin.x, y: v - origin.y), w: w)
    }

    private func distanceToWalls(_ point: PLYPoint2D, walls: [PLYWallSeed]) -> Double {
        walls.reduce(.infinity) { current, wall in
            min(current, pointToSegmentDistance(point, a: wall.startMM, b: wall.endMM))
        }
    }

    private func pointToSegmentDistance(_ p: PLYPoint2D, a: PLYPoint2D, b: PLYPoint2D) -> Double {
        let ab = b - a
        let denom = max(1e-9, ab.x * ab.x + ab.y * ab.y)
        let ap = p - a
        let t = min(1.0, max(0.0, (ap.x * ab.x + ap.y * ab.y) / denom))
        return (p - (a + ab * t)).length
    }

    private func columnSeeds(
        from cells: Set<GridKey>,
        grid: Double,
        cloud: PLYPointCloud,
        axis: PLYUpAxis,
        scale: Double,
        origin: PLYPoint3D,
        baseZMM: Double,
        defaultHeight: Double
    ) -> [PLYStructuralSeed] {
        var remaining = cells
        var seeds: [PLYStructuralSeed] = []
        let neighbours = (-1...1).flatMap { dx in (-1...1).map { dy in (dx, dy) } }.filter { $0 != (0, 0) }

        while let first = remaining.min(by: { lhs, rhs in lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x }) {
            var queue = [first]
            remaining.remove(first)
            var component: [GridKey] = []
            while let current = queue.popLast() {
                component.append(current)
                for (dx, dy) in neighbours {
                    let next = GridKey(x: current.x + dx, y: current.y + dy)
                    if remaining.remove(next) != nil { queue.append(next) }
                }
            }
            guard component.count >= 2 else { continue }
            let centers = component.map { PLYPoint2D(x: (Double($0.x) + 0.5) * grid, y: (Double($0.y) + 0.5) * grid) }
            let fit = orientedBounds(centers, padding: grid)
            let long = max(fit.width, fit.depth), short = min(fit.width, fit.depth)
            guard short >= 140, long <= 850, short <= 700, long / max(short, 1) <= 2.6 else { continue }
            let height = localVerticalExtent(cloud: cloud, axis: axis, scale: scale, origin: origin, baseZMM: baseZMM,
                                             center: fit.center, radius: max(long, short) * 0.8 + grid)
            guard height >= max(1_650, defaultHeight * 0.62) else { continue }
            let resolvedHeight = min(6_000, max(1_800, height))
            let compactness = min(1.0, short / max(long, 1) * 2.0)
            let evidence = min(1.0, Double(component.count) / 12.0)
            let confidence = min(0.96, max(0.58, 0.56 + 0.24 * compactness + 0.18 * evidence))
            guard confidence >= 0.72 else { continue }
            seeds.append(.init(kind: .column, centerMM: fit.center, widthMM: fit.width, depthMM: fit.depth,
                               heightMM: resolvedHeight, elevationMM: 0, rotationRadians: fit.angle, confidence: confidence))
        }
        return seeds
    }

    private func orientedBounds(_ points: [PLYPoint2D], padding: Double) -> (center: PLYPoint2D, width: Double, depth: Double, angle: Double) {
        guard !points.isEmpty else { return (.init(x: 0, y: 0), padding, padding, 0) }
        let mean = PLYPoint2D(x: points.reduce(0) { $0 + $1.x } / Double(points.count),
                              y: points.reduce(0) { $0 + $1.y } / Double(points.count))
        var xx = 0.0, yy = 0.0, xy = 0.0
        for p in points {
            let dx = p.x - mean.x, dy = p.y - mean.y
            xx += dx * dx; yy += dy * dy; xy += dx * dy
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let d = PLYPoint2D(x: cos(angle), y: sin(angle))
        let n = PLYPoint2D(x: -sin(angle), y: cos(angle))
        var minD = Double.infinity, maxD = -Double.infinity, minN = Double.infinity, maxN = -Double.infinity
        for p in points {
            let r = p - mean
            let pd = r.x * d.x + r.y * d.y, pn = r.x * n.x + r.y * n.y
            minD = min(minD, pd); maxD = max(maxD, pd); minN = min(minN, pn); maxN = max(maxN, pn)
        }
        return (mean, max(padding, maxD - minD + padding), max(padding, maxN - minN + padding), angle)
    }

    private func localVerticalExtent(cloud: PLYPointCloud, axis: PLYUpAxis, scale: Double, origin: PLYPoint3D,
                                     baseZMM: Double, center: PLYPoint2D, radius: Double) -> Double {
        var high = baseZMM
        let r2 = radius * radius
        for p in cloud.points {
            let q = project(p, axis: axis, scale: scale, origin: origin)
            let dx = q.plan.x - center.x, dy = q.plan.y - center.y
            if dx * dx + dy * dy <= r2 { high = max(high, q.w) }
        }
        return high - baseZMM
    }

    private func verticalQuantile(_ points: [PLYPoint3D], axis: PLYUpAxis, scale: Double, percentile: Double) -> Double {
        guard let first = points.first else { return 0 }
        func w(_ p: PLYPoint3D) -> Double {
            switch axis { case .x: return p.x * scale; case .y: return p.y * scale; case .z, .auto: return p.z * scale }
        }
        var lo = w(first), hi = lo
        for p in points.dropFirst() { let value = w(p); lo = min(lo, value); hi = max(hi, value) }
        guard hi > lo else { return lo }
        let binsCount = 2048
        var bins = Array(repeating: 0, count: binsCount)
        let inv = Double(binsCount - 1) / (hi - lo)
        for p in points { bins[min(binsCount - 1, max(0, Int((w(p) - lo) * inv)))] += 1 }
        let target = Int(Double(max(0, points.count - 1)) * min(1, max(0, percentile)))
        var total = 0
        for (i, count) in bins.enumerated() {
            total += count
            if total > target { return lo + Double(i) / Double(binsCount - 1) * (hi - lo) }
        }
        return hi
    }

    private func voxelDownsample(_ points: [PLYPoint2D], cell: Double) -> [PLYPoint2D] {
        struct Sum { var x = 0.0; var y = 0.0; var count = 0 }
        var cells: [GridKey: Sum] = [:]
        for p in points {
            let key = GridKey(x: Int(floor(p.x / cell)), y: Int(floor(p.y / cell)))
            var sum = cells[key] ?? Sum(); sum.x += p.x; sum.y += p.y; sum.count += 1; cells[key] = sum
        }
        return cells.keys
            .sorted { lhs, rhs in lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x }
            .compactMap { key in
                guard let value = cells[key] else { return nil }
                return .init(x: value.x / Double(value.count), y: value.y / Double(value.count))
            }
    }

    private func convexHull(_ points: [PLYPoint2D]) -> [PLYPoint2D] {
        let unique = Array(Set(points)).sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard unique.count > 2 else { return unique }
        func turn(_ o: PLYPoint2D, _ a: PLYPoint2D, _ b: PLYPoint2D) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [PLYPoint2D] = []
        for p in unique {
            while lower.count >= 2 && turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [PLYPoint2D] = []
        for p in unique.reversed() {
            while upper.count >= 2 && turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    private func structuralCenterIsPlausible(_ point: PLYPoint2D, boundary: [PLYPoint2D], marginMM: Double) -> Bool {
        guard boundary.count >= 3 else { return true }
        if pointInPolygon(point, polygon: boundary) { return true }
        return distanceToPolygon(point, polygon: boundary) <= marginMM
    }

    private func pointInPolygon(_ point: PLYPoint2D, polygon: [PLYPoint2D]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            let dy = b.y - a.y
            let denominator = abs(dy) < 1e-12 ? (dy < 0 ? -1e-12 : 1e-12) : dy
            let crosses = ((a.y > point.y) != (b.y > point.y)) &&
                (point.x < (b.x - a.x) * (point.y - a.y) / denominator + a.x)
            if crosses { inside.toggle() }
            j = i
        }
        return inside
    }

    private func distanceToPolygon(_ point: PLYPoint2D, polygon: [PLYPoint2D]) -> Double {
        guard polygon.count > 1 else { return .infinity }
        var best = Double.infinity
        for i in polygon.indices {
            best = min(best, pointToSegmentDistance(point, a: polygon[i], b: polygon[(i + 1) % polygon.count]))
        }
        return best
    }

    private func nearestWall(to point: PLYPoint2D, walls: [PLYWallSeed]) -> (wall: PLYWallSeed, distance: Double)? {
        walls.map { ($0, pointToSegmentDistance(point, a: $0.startMM, b: $0.endMM)) }
            .min { $0.1 < $1.1 }
    }

    private func deduplicated(_ seeds: [PLYStructuralSeed]) -> [PLYStructuralSeed] {
        var output: [PLYStructuralSeed] = []
        let ordered = seeds.sorted { lhs, rhs in
            if abs(lhs.confidence - rhs.confidence) > 1e-12 { return lhs.confidence > rhs.confidence }
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            if abs(lhs.centerMM.x - rhs.centerMM.x) > 1e-9 { return lhs.centerMM.x < rhs.centerMM.x }
            if abs(lhs.centerMM.y - rhs.centerMM.y) > 1e-9 { return lhs.centerMM.y < rhs.centerMM.y }
            if abs(lhs.widthMM - rhs.widthMM) > 1e-9 { return lhs.widthMM < rhs.widthMM }
            return lhs.depthMM < rhs.depthMM
        }
        for candidate in ordered {
            let duplicate = output.contains { existing in
                guard existing.kind == candidate.kind else { return false }
                let spatial = (existing.centerMM - candidate.centerMM).length
                if candidate.kind == .column { return spatial < max(180, min(existing.widthMM, existing.depthMM)) }
                let angle = abs(sin(existing.rotationRadians - candidate.rotationRadians))
                return spatial < max(350, min(existing.widthMM, candidate.widthMM) * 0.25) && angle < 0.12
            }
            if !duplicate { output.append(candidate) }
        }
        return output
    }
}
