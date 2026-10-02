import Foundation

public struct PLYWallCandidateEngine: Sendable {
    public init() {}

    /// Creates semantic wall candidates from plan-section line evidence.
    ///
    /// Real room scans commonly expose only the *interior face* of each wall, so requiring two
    /// parallel faces (the v11 behavior) rejects perfectly useful scans. v11.2 therefore prefers
    /// paired-face walls when both faces are visible, then converts any unpaired strong segment into
    /// a lower-confidence single-surface wall using the configured default thickness.
    public func makeWallSeeds(from segments: [PLYPlanSegment], settings: PLYSectionSettings) -> [PLYWallSeed] {
        var candidates: [(score: Double, a: Int, b: Int, seed: PLYWallSeed)] = []
        let angleTolerance = max(3, settings.angleStepDegrees * 2) * .pi / 180

        for i in segments.indices {
            for j in segments.indices where j > i {
                let a = segments[i], b = segments[j]
                let da = canonicalDirection(a.direction)
                let db = canonicalDirection(b.direction)
                let angle = acos(min(1, max(-1, abs(da.x * db.x + da.y * db.y))))
                guard angle <= angleTolerance else { continue }

                let normal = PLYPoint2D(x: -da.y, y: da.x)
                let offset = abs((b.start.x - a.start.x) * normal.x + (b.start.y - a.start.y) * normal.y)
                guard offset >= settings.minWallThicknessMM, offset <= settings.maxWallThicknessMM else { continue }

                let intervalA = projectedInterval(a, origin: a.start, direction: da)
                let intervalB = projectedInterval(b, origin: a.start, direction: da)
                let overlap0 = max(intervalA.0, intervalB.0)
                let overlap1 = min(intervalA.1, intervalB.1)
                let overlap = overlap1 - overlap0
                guard overlap >= settings.minSegmentLengthMM else { continue }

                let nSigned = (b.start.x - a.start.x) * normal.x + (b.start.y - a.start.y) * normal.y
                let centerBase = a.start + normal * (nSigned * 0.5)
                let start = centerBase + da * overlap0
                let end = centerBase + da * overlap1
                let angleScore = 1 - min(1, angle / angleTolerance)
                let supportScore = min(1, Double(a.support + b.support) / 80.0)
                let errorScore = 1 - min(1, (a.rmsErrorMM + b.rmsErrorMM) / max(1, settings.lineToleranceMM * 2))
                let confidence = max(0, min(1, 0.45 * angleScore + 0.35 * supportScore + 0.20 * errorScore))
                let seed = PLYWallSeed(
                    startMM: start,
                    lengthMM: (end - start).length,
                    angleRadians: atan2(da.y, da.x),
                    heightMM: settings.defaultWallHeightMM,
                    thicknessMM: offset,
                    confidence: confidence,
                    inferenceKind: .pairedFaces,
                    sourceSegmentIDs: [a.id, b.id]
                )
                candidates.append((confidence * overlap, i, j, seed))
            }
        }

        // Prefer the strongest non-overlapping measured-thickness pairs.
        candidates.sort { $0.score > $1.score }
        var used = Set<Int>()
        var seeds: [PLYWallSeed] = []
        for c in candidates where !used.contains(c.a) && !used.contains(c.b) {
            used.insert(c.a)
            used.insert(c.b)
            seeds.append(c.seed)
        }

        // A laser/LiDAR scan from inside a room normally sees one wall face, not both wall faces.
        // Preserve that evidence instead of returning zero walls. The observed line is used as the
        // wall axis for this MVP; the user can edit the resulting parametric wall after acceptance.
        if settings.allowSingleSurfaceWalls {
            let fallbackThickness = min(
                settings.maxWallThicknessMM,
                max(settings.minWallThicknessMM, settings.defaultWallThicknessMM)
            )
            for index in segments.indices where !used.contains(index) {
                let segment = segments[index]
                guard segment.lengthMM >= settings.minSegmentLengthMM,
                      segment.support >= settings.minLineSupport else { continue }

                let supportScore = min(1, Double(segment.support) / 50.0)
                let lengthScore = min(1, segment.lengthMM / max(1, settings.minSegmentLengthMM * 4))
                let errorScore = 1 - min(1, segment.rmsErrorMM / max(1, settings.lineToleranceMM))
                // Intentionally below paired-face confidence: thickness is assumed, not measured.
                let confidence = max(0.20, min(0.72, 0.30 * supportScore + 0.30 * lengthScore + 0.20 * errorScore + 0.10))
                let d = canonicalDirection(segment.direction)
                let start = canonicalStart(segment, direction: d)
                seeds.append(
                    PLYWallSeed(
                        startMM: start,
                        lengthMM: segment.lengthMM,
                        angleRadians: atan2(d.y, d.x),
                        heightMM: settings.defaultWallHeightMM,
                        thicknessMM: fallbackThickness,
                        confidence: confidence,
                        inferenceKind: .singleSurface,
                        sourceSegmentIDs: [segment.id]
                    )
                )
            }
        }

        // Turn independent fitted wall axes into a coherent architectural network before they
        // cross the semantic boundary. Point-cloud line fitting naturally stops short of corners
        // (occlusion, voxelisation and finite support), and paired-face centre lines are often
        // offset from their observed-face endpoints by roughly half a wall thickness.
        //
        // Merely averaging nearby endpoints produces visibly broken or skewed corners. Instead,
        // solve the intersection of non-parallel wall axes and extend only endpoints that are
        // plausibly close to that intersection. A final cluster pass makes multi-wall junctions
        // exactly coincident and deterministic.
        let unique = deduplicate(seeds, settings: settings)
        guard settings.professionalCleanup else {
            return stitchJunctions(unique, settings: settings).sorted { $0.lengthMM > $1.lengthMM }
        }

        // Professional cleanup operates on the semantic wall axes, not on the raw point evidence.
        // It deliberately bridges door/window-sized gaps because the continuous host wall belongs in
        // the semantic model; openings can be inferred and hosted on that wall in a later pass.
        var cleaned = consolidateCollinearWalls(unique, settings: settings)
        // Collapse scan-generated corner bridges before generic junction extension can move their
        // neighbouring endpoints away from the short bridge evidence.
        cleaned = collapseCornerBridgeWalls(cleaned, settings: settings)
        cleaned = stitchJunctions(cleaned, settings: settings)
        cleaned = resolveTJunctions(cleaned, settings: settings)

        // v11.5: move from local segment cleanup to boundary-first architectural cleanup.
        // Short connector fragments are often not real walls; they are residual scan edges between
        // two longer wall axes. Collapse those bridges first, then close plausible free-end corner
        // gaps by extending the *existing* wall axes to their exact mathematical intersection.
        cleaned = collapseCornerBridgeWalls(cleaned, settings: settings)
        cleaned = consolidateCollinearWalls(cleaned, settings: settings)
        cleaned = closeArchitecturalBoundaryGaps(cleaned, settings: settings)
        cleaned = stitchJunctions(cleaned, settings: settings)
        cleaned = resolveTJunctions(cleaned, settings: settings)
        cleaned = collapseCornerBridgeWalls(cleaned, settings: settings)
        cleaned = consolidateCollinearWalls(cleaned, settings: settings)

        // Remove disconnected scan noise and short one-ended spurs only after the main shell has
        // been reconstructed. Two-ended short edges are preserved because they may be legitimate
        // chamfers/notches in a non-orthogonal room.
        cleaned = pruneSmallDisconnectedNoise(cleaned, settings: settings)
        cleaned = pruneShortOneEndedSpurs(cleaned, settings: settings)
        cleaned = closeArchitecturalBoundaryGaps(cleaned, settings: settings)
        cleaned = stitchJunctions(cleaned, settings: settings)
        cleaned = consolidateCollinearWalls(cleaned, settings: settings)

        // Indoor PLY scans usually capture the room-facing wall surface. A single-surface seed was
        // historically treated as a wall axis, which made the generated wall straddle the measured
        // evidence by half its thickness. When we have a coherent closed boundary, offset those
        // single-surface boundary walls outward by half thickness and re-solve their intersections.
        // The result is a semantic centreline whose *interior face* remains registered to the PLY.
        if settings.registerSingleSurfaceAsInteriorFace {
            cleaned = registerSingleSurfaceBoundaryToInteriorFace(cleaned, settings: settings)
        }

        return cleaned.sorted { $0.lengthMM > $1.lengthMM }
    }

    /// v11.9 post-review topology refinement.
    ///
    /// The input walls have already passed through scan-face registration, so this pass deliberately
    /// does **not** offset single-surface walls again. It only reconciles the human-selected semantic
    /// network: deduplication, collinear consolidation, false-corner collapse, exact corner/T-junction
    /// solving, and plausible boundary-gap closure.
    ///
    /// Disable this from the review UI when the user intentionally wants to preserve raw selected
    /// fragments exactly as detected.
    public func refineReviewedWallNetwork(
        _ input: [PLYWallSeed],
        settings: PLYSectionSettings
    ) -> [PLYWallSeed] {
        guard !input.isEmpty else { return [] }
        let unique = deduplicate(input, settings: settings)
        guard settings.professionalCleanup else {
            return stitchJunctions(unique, settings: settings).sorted { $0.lengthMM > $1.lengthMM }
        }

        var cleaned = consolidateCollinearWalls(unique, settings: settings)
        cleaned = collapseCornerBridgeWalls(cleaned, settings: settings)
        cleaned = stitchJunctions(cleaned, settings: settings)
        cleaned = resolveTJunctions(cleaned, settings: settings)
        cleaned = closeArchitecturalBoundaryGaps(cleaned, settings: settings)
        cleaned = stitchJunctions(cleaned, settings: settings)
        cleaned = resolveTJunctions(cleaned, settings: settings)
        cleaned = collapseCornerBridgeWalls(cleaned, settings: settings)
        cleaned = consolidateCollinearWalls(cleaned, settings: settings)
        return cleaned.sorted { $0.lengthMM > $1.lengthMM }
    }
}

private extension PLYWallCandidateEngine {
    func canonicalDirection(_ d: PLYPoint2D) -> PLYPoint2D {
        if d.x < 0 || (abs(d.x) < 1e-9 && d.y < 0) { return .init(x: -d.x, y: -d.y) }
        return d
    }

    func canonicalStart(_ segment: PLYPlanSegment, direction: PLYPoint2D) -> PLYPoint2D {
        let raw = segment.end - segment.start
        let dot = raw.x * direction.x + raw.y * direction.y
        return dot >= 0 ? segment.start : segment.end
    }

    func projectedInterval(_ segment: PLYPlanSegment, origin: PLYPoint2D, direction: PLYPoint2D) -> (Double, Double) {
        let a = segment.start - origin, b = segment.end - origin
        let ta = a.x * direction.x + a.y * direction.y
        let tb = b.x * direction.x + b.y * direction.y
        return (min(ta, tb), max(ta, tb))
    }

    func deduplicate(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        var output: [PLYWallSeed] = []
        let angleTolerance = max(4, settings.angleStepDegrees * 2.5) * .pi / 180
        let distanceTolerance = max(settings.lineToleranceMM * 2, settings.defaultWallThicknessMM)

        for seed in input.sorted(by: { lhs, rhs in
            if lhs.inferenceKind != rhs.inferenceKind { return lhs.inferenceKind == .pairedFaces }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.lengthMM > rhs.lengthMM
        }) {
            let d = PLYPoint2D(x: cos(seed.angleRadians), y: sin(seed.angleRadians))
            let normal = PLYPoint2D(x: -d.y, y: d.x)
            let midpoint = seed.startMM + d * (seed.lengthMM * 0.5)
            let duplicate = output.contains { existing in
                let e = PLYPoint2D(x: cos(existing.angleRadians), y: sin(existing.angleRadians))
                let dot = abs(d.x * e.x + d.y * e.y)
                let angle = acos(min(1, max(-1, dot)))
                guard angle <= angleTolerance else { return false }
                let eMid = existing.startMM + e * (existing.lengthMM * 0.5)
                let normalDistance = abs((eMid.x - midpoint.x) * normal.x + (eMid.y - midpoint.y) * normal.y)
                guard normalDistance <= distanceTolerance else { return false }
                let overlap = intervalOverlap(
                    a0: 0,
                    a1: seed.lengthMM,
                    b0: (existing.startMM - seed.startMM).x * d.x + (existing.startMM - seed.startMM).y * d.y,
                    b1: (existing.endMM - seed.startMM).x * d.x + (existing.endMM - seed.startMM).y * d.y
                )
                return overlap >= min(seed.lengthMM, existing.lengthMM) * 0.70
            }
            if !duplicate { output.append(seed) }
        }
        return output
    }



    func stitchJunctions(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        guard input.count > 1 else { return input }
        var walls = input

        let minimumAngle = max(8.0, settings.angleStepDegrees * 4.0) * .pi / 180.0
        let clusterTolerance = max(20.0, settings.endpointSnapMM)

        // Two passes are intentional: resolving one corner can make the next junction eligible
        // for exact endpoint clustering without making the operation order-sensitive in practice.
        for _ in 0..<2 {
            for i in walls.indices {
                for j in walls.indices where j > i {
                    let di = unitDirection(walls[i])
                    let dj = unitDirection(walls[j])
                    let angularDot = min(1.0, max(-1.0, abs(di.x * dj.x + di.y * dj.y)))
                    let angle = acos(angularDot)
                    guard angle >= minimumAngle else { continue }
                    guard let intersection = lineIntersection(walls[i], walls[j]) else { continue }

                    let extensionLimit = min(900.0, max(
                        250.0,
                        settings.maxGapMM * 2.5,
                        settings.endpointSnapMM * 4.0,
                        max(walls[i].thicknessMM, walls[j].thicknessMM) * 3.0
                    ))

                    let ei = nearestEndpoint(of: walls[i], to: intersection)
                    let ej = nearestEndpoint(of: walls[j], to: intersection)
                    guard ei.distance <= extensionLimit, ej.distance <= extensionLimit else { continue }

                    setEndpoint(&walls[i], isStart: ei.isStart, to: intersection)
                    setEndpoint(&walls[j], isStart: ej.isStart, to: intersection)
                }
            }
            walls = clusterCloseEndpoints(walls, toleranceMM: clusterTolerance)
        }

        return walls.filter {
            $0.startMM.x.isFinite && $0.startMM.y.isFinite &&
            $0.lengthMM.isFinite && $0.lengthMM >= 100 &&
            $0.angleRadians.isFinite
        }
    }

    func unitDirection(_ wall: PLYWallSeed) -> PLYPoint2D {
        PLYPoint2D(x: cos(wall.angleRadians), y: sin(wall.angleRadians))
    }

    func lineIntersection(_ a: PLYWallSeed, _ b: PLYWallSeed) -> PLYPoint2D? {
        let p = a.startMM
        let q = b.startMM
        let r = unitDirection(a)
        let s = unitDirection(b)
        let denominator = cross(r, s)
        guard abs(denominator) > 1e-8 else { return nil }
        let qp = q - p
        let t = cross(qp, s) / denominator
        let point = p + r * t
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    func cross(_ a: PLYPoint2D, _ b: PLYPoint2D) -> Double {
        a.x * b.y - a.y * b.x
    }

    func nearestEndpoint(of wall: PLYWallSeed, to point: PLYPoint2D) -> (isStart: Bool, distance: Double) {
        let ds = (wall.startMM - point).length
        let de = (wall.endMM - point).length
        return ds <= de ? (true, ds) : (false, de)
    }

    func setEndpoint(_ wall: inout PLYWallSeed, isStart: Bool, to point: PLYPoint2D) {
        let opposite = isStart ? wall.endMM : wall.startMM
        let start = isStart ? point : opposite
        let end = isStart ? opposite : point
        let vector = end - start
        let length = vector.length
        guard length > 1e-6 else { return }
        wall.startMM = start
        wall.lengthMM = length
        wall.angleRadians = atan2(vector.y, vector.x)
    }

    func clusterCloseEndpoints(_ input: [PLYWallSeed], toleranceMM: Double) -> [PLYWallSeed] {
        guard input.count > 1, toleranceMM > 0 else { return input }
        var walls = input
        let endpointCount = walls.count * 2
        var parent = Array(0..<endpointCount)

        func root(_ index: Int, parent: inout [Int]) -> Int {
            var x = index
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        func unite(_ a: Int, _ b: Int, parent: inout [Int]) {
            let ra = root(a, parent: &parent)
            let rb = root(b, parent: &parent)
            if ra != rb { parent[rb] = ra }
        }

        func point(_ endpoint: Int) -> PLYPoint2D {
            let wallIndex = endpoint / 2
            return endpoint % 2 == 0 ? walls[wallIndex].startMM : walls[wallIndex].endMM
        }

        for a in 0..<endpointCount {
            for b in (a + 1)..<endpointCount {
                // Never collapse both ends of the same wall.
                if a / 2 == b / 2 { continue }
                if (point(a) - point(b)).length <= toleranceMM {
                    unite(a, b, parent: &parent)
                }
            }
        }

        var sums: [Int: (x: Double, y: Double, count: Int)] = [:]
        for endpoint in 0..<endpointCount {
            let r = root(endpoint, parent: &parent)
            let p = point(endpoint)
            let current = sums[r] ?? (0, 0, 0)
            sums[r] = (current.x + p.x, current.y + p.y, current.count + 1)
        }

        for wallIndex in walls.indices {
            let startIndex = wallIndex * 2
            let endIndex = startIndex + 1
            let sr = root(startIndex, parent: &parent)
            let er = root(endIndex, parent: &parent)
            guard let ss = sums[sr], let es = sums[er], ss.count > 0, es.count > 0 else { continue }
            let start = PLYPoint2D(x: ss.x / Double(ss.count), y: ss.y / Double(ss.count))
            let end = PLYPoint2D(x: es.x / Double(es.count), y: es.y / Double(es.count))
            let vector = end - start
            let length = vector.length
            guard length > 1e-6 else { continue }
            walls[wallIndex].startMM = start
            walls[wallIndex].lengthMM = length
            walls[wallIndex].angleRadians = atan2(vector.y, vector.x)
        }
        return walls
    }


    /// Consolidates near-collinear scan fragments into one semantic host wall. Real PLY sections are
    /// commonly interrupted by doors, windows, furniture, occlusion and sparse photogrammetry. Those
    /// gaps should not force PlanOpsis to create a dozen independent wall objects.
    func consolidateCollinearWalls(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        guard input.count > 1 else { return input }
        var walls = input
        let angleTolerance = max(3.5, settings.angleStepDegrees * 2.5) * .pi / 180.0
        let lineTolerance = min(420.0, max(
            settings.lineToleranceMM * 3.0,
            settings.voxelSizeMM * 3.5,
            settings.defaultWallThicknessMM * 1.6
        ))
        let gapTolerance = min(2_500.0, max(
            settings.wallContinuityGapMM,
            settings.maxGapMM * 4.0,
            settings.endpointSnapMM * 6.0
        ))

        while walls.count > 1 {
            var best: (i: Int, j: Int, score: Double)?
            for i in walls.indices {
                for j in walls.indices where j > i {
                    guard let metrics = collinearMetrics(
                        walls[i], walls[j],
                        angleTolerance: angleTolerance,
                        lineTolerance: lineTolerance,
                        gapTolerance: gapTolerance
                    ) else { continue }
                    // Prefer overlapping / small-gap fragments on nearly the same fitted axis.
                    let score = metrics.angle / max(angleTolerance, 1e-9)
                        + metrics.lineDistance / max(lineTolerance, 1)
                        + metrics.gap / max(gapTolerance, 1)
                    if best.map({ score < $0.score }) ?? true { best = (i, j, score) }
                }
            }
            guard let best else { break }
            let merged = mergeWallSeeds(walls[best.i], walls[best.j])
            walls[best.i] = merged
            walls.remove(at: best.j)
        }
        return walls
    }

    func collinearMetrics(
        _ a: PLYWallSeed,
        _ b: PLYWallSeed,
        angleTolerance: Double,
        lineTolerance: Double,
        gapTolerance: Double
    ) -> (angle: Double, lineDistance: Double, gap: Double)? {
        let da = canonicalDirection(unitDirection(a))
        let db = canonicalDirection(unitDirection(b))
        let dot = min(1.0, max(-1.0, abs(da.x * db.x + da.y * db.y)))
        let angle = acos(dot)
        guard angle <= angleTolerance else { return nil }

        let normal = PLYPoint2D(x: -da.y, y: da.x)
        let midA = a.startMM + da * (a.lengthMM * 0.5)
        let midB = b.startMM + db * (b.lengthMM * 0.5)
        let lineDistance = abs((midB.x - midA.x) * normal.x + (midB.y - midA.y) * normal.y)
        guard lineDistance <= lineTolerance else { return nil }

        let a0 = 0.0
        let a1 = a.lengthMM
        let rb0 = b.startMM - a.startMM
        let rb1 = b.endMM - a.startMM
        let b0 = rb0.x * da.x + rb0.y * da.y
        let b1 = rb1.x * da.x + rb1.y * da.y
        let gap = max(0, max(min(b0, b1) - a1, a0 - max(b0, b1)))
        guard gap <= gapTolerance else { return nil }
        return (angle, lineDistance, gap)
    }

    func mergeWallSeeds(_ a: PLYWallSeed, _ b: PLYWallSeed) -> PLYWallSeed {
        let wa = max(1.0, a.lengthMM * max(0.20, a.confidence))
        let wb = max(1.0, b.lengthMM * max(0.20, b.confidence))

        // Average undirected line angle with the doubled-angle formulation so 0° and 180° are equal.
        let vx = cos(2 * a.angleRadians) * wa + cos(2 * b.angleRadians) * wb
        let vy = sin(2 * a.angleRadians) * wa + sin(2 * b.angleRadians) * wb
        var angle = 0.5 * atan2(vy, vx)
        var direction = PLYPoint2D(x: cos(angle), y: sin(angle))
        direction = canonicalDirection(direction)
        angle = atan2(direction.y, direction.x)
        let normal = PLYPoint2D(x: -direction.y, y: direction.x)

        let midA = a.startMM + unitDirection(a) * (a.lengthMM * 0.5)
        let midB = b.startMM + unitDirection(b) * (b.lengthMM * 0.5)
        let lineOffset = ((midA.x * normal.x + midA.y * normal.y) * wa
                        + (midB.x * normal.x + midB.y * normal.y) * wb) / (wa + wb)
        let points = [a.startMM, a.endMM, b.startMM, b.endMM]
        let ts = points.map { $0.x * direction.x + $0.y * direction.y }
        let minT = ts.min() ?? 0
        let maxT = ts.max() ?? minT
        let start = direction * minT + normal * lineOffset

        let measuredA = a.inferenceKind == .pairedFaces
        let measuredB = b.inferenceKind == .pairedFaces
        let thickness: Double
        if measuredA && !measuredB {
            thickness = a.thicknessMM
        } else if measuredB && !measuredA {
            thickness = b.thicknessMM
        } else {
            thickness = (a.thicknessMM * wa + b.thicknessMM * wb) / (wa + wb)
        }

        var sourceIDs = a.sourceSegmentIDs
        for id in b.sourceSegmentIDs where !sourceIDs.contains(id) { sourceIDs.append(id) }
        return PLYWallSeed(
            id: a.id,
            startMM: start,
            lengthMM: max(0, maxT - minT),
            angleRadians: angle,
            heightMM: (a.heightMM * wa + b.heightMM * wb) / (wa + wb),
            thicknessMM: thickness,
            confidence: min(1.0, max(a.confidence, b.confidence) + 0.04),
            inferenceKind: measuredA || measuredB ? .pairedFaces : .singleSurface,
            sourceSegmentIDs: sourceIDs
        )
    }

    /// Snaps a free wall endpoint onto the interior of a non-parallel host wall. This resolves
    /// T-junctions without splitting the host wall into artificial semantic fragments.
    func resolveTJunctions(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        guard input.count > 1 else { return input }
        var walls = input
        let minimumAngle = max(12.0, settings.angleStepDegrees * 5.0) * .pi / 180.0
        let attachTolerance = min(360.0, max(
            140.0,
            settings.lineToleranceMM * 4.0,
            settings.endpointSnapMM * 2.5,
            settings.defaultWallThicknessMM * 1.25
        ))

        for _ in 0..<2 {
            for i in walls.indices {
                for useStart in [true, false] {
                    let endpoint = useStart ? walls[i].startMM : walls[i].endMM
                    var best: (distance: Double, point: PLYPoint2D)?
                    for j in walls.indices where j != i {
                        let di = unitDirection(walls[i])
                        let dj = unitDirection(walls[j])
                        let angle = acos(min(1.0, max(-1.0, abs(di.x * dj.x + di.y * dj.y))))
                        guard angle >= minimumAngle else { continue }
                        let rel = endpoint - walls[j].startMM
                        let t = rel.x * dj.x + rel.y * dj.y
                        guard t >= -settings.endpointSnapMM, t <= walls[j].lengthMM + settings.endpointSnapMM else { continue }
                        let clampedT = min(walls[j].lengthMM, max(0, t))
                        let projection = walls[j].startMM + dj * clampedT
                        let distance = (projection - endpoint).length
                        guard distance <= attachTolerance else { continue }
                        if best.map({ distance < $0.distance }) ?? true { best = (distance, projection) }
                    }
                    if let best { setEndpoint(&walls[i], isStart: useStart, to: best.point) }
                }
            }
            walls = clusterCloseEndpoints(walls, toleranceMM: max(20, settings.endpointSnapMM))
        }
        return walls
    }

    /// Removes tiny disconnected components that are characteristic of furniture edges and sparse
    /// scan artefacts. Long independent partitions are intentionally retained.
    func pruneSmallDisconnectedNoise(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        guard input.count > 1 else { return input }
        var parent = Array(input.indices)

        func root(_ i: Int, _ parent: inout [Int]) -> Int {
            var x = i
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func unite(_ a: Int, _ b: Int, _ parent: inout [Int]) {
            let ra = root(a, &parent), rb = root(b, &parent)
            if ra != rb { parent[rb] = ra }
        }

        let connectivityTolerance = min(260.0, max(
            80.0, settings.endpointSnapMM * 1.5, settings.lineToleranceMM * 2.0
        ))
        for i in input.indices {
            for j in input.indices where j > i {
                if wallDistance(input[i], input[j]) <= connectivityTolerance {
                    unite(i, j, &parent)
                }
            }
        }

        var stats: [Int: (total: Double, maxLength: Double, count: Int)] = [:]
        for i in input.indices {
            let r = root(i, &parent)
            let old = stats[r] ?? (0, 0, 0)
            stats[r] = (old.total + input[i].lengthMM, max(old.maxLength, input[i].lengthMM), old.count + 1)
        }
        let largestRoot = stats.max(by: { $0.value.total < $1.value.total })?.key
        let minimumComponentTotal = max(1_200.0, settings.minSegmentLengthMM * 2.25)
        let minimumIndependentWall = max(900.0, settings.minSegmentLengthMM * 1.8)

        return input.enumerated().compactMap { index, wall in
            let r = root(index, &parent)
            guard let stat = stats[r] else { return wall }
            if r == largestRoot { return wall }
            if stat.total >= minimumComponentTotal || stat.maxLength >= minimumIndependentWall { return wall }
            return nil
        }
    }

    func wallDistance(_ a: PLYWallSeed, _ b: PLYWallSeed) -> Double {
        min(
            pointToWallDistance(a.startMM, wall: b),
            pointToWallDistance(a.endMM, wall: b),
            pointToWallDistance(b.startMM, wall: a),
            pointToWallDistance(b.endMM, wall: a)
        )
    }

    func pointToWallDistance(_ point: PLYPoint2D, wall: PLYWallSeed) -> Double {
        let d = unitDirection(wall)
        let rel = point - wall.startMM
        let t = min(wall.lengthMM, max(0, rel.x * d.x + rel.y * d.y))
        return (point - (wall.startMM + d * t)).length
    }



    /// Collapses a short connector that merely bridges two longer non-parallel walls near their
    /// true axis intersection. This removes the characteristic 300–800 mm "extra wall" produced
    /// when a scan misses a corner and the line extractor fits the residual edge separately.
    ///
    /// A short edge is preserved when it is connected at both ends but the neighbouring long walls
    /// are parallel/collinear, because that may represent a real notch or offset rather than a corner.
    func collapseCornerBridgeWalls(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        guard input.count >= 3 else { return input }
        var walls = input
        let bridgeMaximum = min(1_050.0, max(
            800.0,
            settings.minSegmentLengthMM * 2.0,
            settings.defaultWallThicknessMM * 5.5
        ))
        let connectionTolerance = min(420.0, max(
            120.0,
            settings.endpointSnapMM * 2.0,
            settings.lineToleranceMM * 3.0,
            settings.defaultWallThicknessMM * 1.5
        ))
        let minimumAngle = max(10.0, settings.angleStepDegrees * 4.0) * .pi / 180.0
        let collapseReach = min(1_300.0, max(
            550.0,
            settings.wallContinuityGapMM * 0.65,
            bridgeMaximum * 1.5
        ))

        for _ in 0..<6 {
            var didCollapse = false
            for bridgeIndex in walls.indices {
                let bridge = walls[bridgeIndex]
                guard bridge.lengthMM <= bridgeMaximum else { continue }

                guard let first = nearestWallEndpoint(
                    to: bridge.startMM,
                    in: walls,
                    excluding: bridgeIndex,
                    toleranceMM: connectionTolerance
                ), let second = nearestWallEndpoint(
                    to: bridge.endMM,
                    in: walls,
                    excluding: bridgeIndex,
                    toleranceMM: connectionTolerance
                ), first.wallIndex != second.wallIndex else { continue }

                let a = walls[first.wallIndex]
                let b = walls[second.wallIndex]
                guard a.lengthMM >= bridge.lengthMM * 1.35,
                      b.lengthMM >= bridge.lengthMM * 1.35 else { continue }
                // Preserve strongly observed short chamfers. A false connector is expected to have
                // materially weaker evidence than the two long wall runs it is bridging.
                let neighbourConfidence = min(a.confidence, b.confidence)
                guard bridge.confidence + 0.08 < neighbourConfidence else { continue }

                let da = unitDirection(a), db = unitDirection(b)
                let angle = acos(min(1.0, max(-1.0, abs(da.x * db.x + da.y * db.y))))
                guard angle >= minimumAngle, let intersection = lineIntersection(a, b) else { continue }

                let ea = nearestEndpoint(of: a, to: intersection)
                let eb = nearestEndpoint(of: b, to: intersection)
                guard ea.distance <= collapseReach, eb.distance <= collapseReach else { continue }
                let bridgeMid = bridge.startMM + unitDirection(bridge) * (bridge.lengthMM * 0.5)
                guard (bridgeMid - intersection).length <= collapseReach else { continue }

                // Mutate the two long neighbours first, then remove the bridge. Use descending-index
                // safe lookup after mutation so removing one element cannot invalidate the other.
                setEndpoint(&walls[first.wallIndex], isStart: ea.isStart, to: intersection)
                setEndpoint(&walls[second.wallIndex], isStart: eb.isStart, to: intersection)
                walls.remove(at: bridgeIndex)
                didCollapse = true
                break
            }
            if !didCollapse { break }
        }
        return walls
    }

    func nearestWallEndpoint(
        to point: PLYPoint2D,
        in walls: [PLYWallSeed],
        excluding excludedIndex: Int,
        toleranceMM: Double
    ) -> (wallIndex: Int, isStart: Bool, distance: Double)? {
        var best: (wallIndex: Int, isStart: Bool, distance: Double)?
        for index in walls.indices where index != excludedIndex {
            let ds = (walls[index].startMM - point).length
            let de = (walls[index].endMM - point).length
            let candidate: (Int, Bool, Double) = ds <= de ? (index, true, ds) : (index, false, de)
            guard candidate.2 <= toleranceMM else { continue }
            if best.map({ candidate.2 < $0.distance }) ?? true { best = candidate }
        }
        return best
    }

    /// Closes remaining architectural corner gaps using only existing wall axes. No arbitrary bridge
    /// segment is created: two non-parallel walls are extended/trimmed to the exact intersection of
    /// their fitted axes. The outward-ray test prevents an endpoint from being dragged backwards
    /// through its own wall, which is important around interior partitions.
    func closeArchitecturalBoundaryGaps(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        guard input.count > 1 else { return input }
        var walls = input
        let connectedTolerance = min(260.0, max(
            45.0,
            settings.endpointSnapMM * 1.5,
            settings.lineToleranceMM * 1.5
        ))
        let closureLimit = min(2_600.0, max(
            800.0,
            settings.wallContinuityGapMM * 1.35,
            settings.maxGapMM * 6.0
        ))
        let minimumAngle = max(9.0, settings.angleStepDegrees * 4.0) * .pi / 180.0
        let maxIterations = min(32, max(4, walls.count * 2))

        for _ in 0..<maxIterations {
            let loose = looseEndpoints(in: walls, toleranceMM: connectedTolerance)
            guard loose.count >= 2 else { break }
            var best: (a: LooseEndpoint, b: LooseEndpoint, intersection: PLYPoint2D, score: Double)?

            for ai in loose.indices {
                for bi in loose.indices where bi > ai {
                    let a = loose[ai], b = loose[bi]
                    guard a.wallIndex != b.wallIndex else { continue }
                    let wa = walls[a.wallIndex], wb = walls[b.wallIndex]
                    let da = unitDirection(wa), db = unitDirection(wb)
                    let angle = acos(min(1.0, max(-1.0, abs(da.x * db.x + da.y * db.y))))
                    guard angle >= minimumAngle, let intersection = lineIntersection(wa, wb) else { continue }

                    guard let extA = outwardExtensionDistance(
                        wall: wa, isStart: a.isStart, intersection: intersection, slackMM: connectedTolerance
                    ), let extB = outwardExtensionDistance(
                        wall: wb, isStart: b.isStart, intersection: intersection, slackMM: connectedTolerance
                    ) else { continue }
                    guard extA <= closureLimit, extB <= closureLimit else { continue }

                    let endpointGap = (a.point - b.point).length
                    guard endpointGap <= closureLimit * 1.65 else { continue }
                    // Prefer the least geometric invention. A small turn-angle penalty avoids choosing
                    // a very acute remote intersection when an equally close orthogonal/oblique one exists.
                    let anglePenalty = max(0, (20.0 * .pi / 180.0 - angle)) * 250.0
                    let score = extA + extB + endpointGap * 0.15 + anglePenalty
                    if best.map({ score < $0.score }) ?? true { best = (a, b, intersection, score) }
                }
            }

            guard let best else { break }
            setEndpoint(&walls[best.a.wallIndex], isStart: best.a.isStart, to: best.intersection)
            setEndpoint(&walls[best.b.wallIndex], isStart: best.b.isStart, to: best.intersection)
            walls = clusterCloseEndpoints(walls, toleranceMM: connectedTolerance)
        }
        return walls
    }

    struct LooseEndpoint {
        var wallIndex: Int
        var isStart: Bool
        var point: PLYPoint2D
    }

    func looseEndpoints(in walls: [PLYWallSeed], toleranceMM: Double) -> [LooseEndpoint] {
        var output: [LooseEndpoint] = []
        for wallIndex in walls.indices {
            for isStart in [true, false] {
                let point = isStart ? walls[wallIndex].startMM : walls[wallIndex].endMM
                if !endpointIsConnected(point, owner: wallIndex, walls: walls, toleranceMM: toleranceMM) {
                    output.append(.init(wallIndex: wallIndex, isStart: isStart, point: point))
                }
            }
        }
        return output
    }

    func endpointIsConnected(
        _ point: PLYPoint2D,
        owner: Int,
        walls: [PLYWallSeed],
        toleranceMM: Double
    ) -> Bool {
        for index in walls.indices where index != owner {
            if (walls[index].startMM - point).length <= toleranceMM ||
                (walls[index].endMM - point).length <= toleranceMM { return true }
            if pointToWallDistance(point, wall: walls[index]) <= toleranceMM {
                let d = unitDirection(walls[index])
                let rel = point - walls[index].startMM
                let t = rel.x * d.x + rel.y * d.y
                if t > toleranceMM && t < walls[index].lengthMM - toleranceMM { return true }
            }
        }
        return false
    }

    func outwardExtensionDistance(
        wall: PLYWallSeed,
        isStart: Bool,
        intersection: PLYPoint2D,
        slackMM: Double
    ) -> Double? {
        let endpoint = isStart ? wall.startMM : wall.endMM
        let vector = intersection - endpoint
        let distance = vector.length
        if distance <= slackMM { return distance }
        guard distance > 1e-9 else { return 0 }
        let d = unitDirection(wall)
        let outward = isStart ? PLYPoint2D(x: -d.x, y: -d.y) : d
        let alignment = (vector.x * outward.x + vector.y * outward.y) / distance
        guard alignment >= 0.72 else { return nil }
        return distance
    }

    /// Removes only short walls that behave as one-ended spurs after the shell has been closed. A
    /// short wall connected at both ends is retained because it may be a genuine chamfer or recess.
    func pruneShortOneEndedSpurs(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        guard input.count > 2 else { return input }
        var walls = input
        let tolerance = min(260.0, max(
            60.0, settings.endpointSnapMM * 1.5, settings.lineToleranceMM * 1.75
        ))
        let maximumSpur = min(900.0, max(
            450.0, settings.minSegmentLengthMM * 1.5, settings.defaultWallThicknessMM * 4.0
        ))

        for _ in 0..<4 {
            var removal: Int?
            for index in walls.indices where walls[index].lengthMM <= maximumSpur {
                let startConnected = endpointIsConnected(
                    walls[index].startMM, owner: index, walls: walls, toleranceMM: tolerance
                )
                let endConnected = endpointIsConnected(
                    walls[index].endMM, owner: index, walls: walls, toleranceMM: tolerance
                )
                if startConnected != endConnected || (!startConnected && !endConnected) {
                    removal = index
                    break
                }
            }
            guard let removal else { break }
            walls.remove(at: removal)
        }
        return walls
    }

    func intervalOverlap(a0: Double, a1: Double, b0: Double, b1: Double) -> Double {
        let lo = max(min(a0, a1), min(b0, b1))
        let hi = min(max(a0, a1), max(b0, b1))
        return max(0, hi - lo)
    }

    // MARK: - Scan-face registration

    struct BoundaryCycleEdge {
        var wallIndex: Int
        var from: PLYPoint2D
        var to: PLYPoint2D
    }

    /// Finds the largest simple closed wall cycle. The professional cleanup stage has already made
    /// shared corners coincident, so a small endpoint clustering tolerance is sufficient here.
    /// Interior partitions/T-junctions do not participate unless they themselves form a larger cycle.
    func dominantClosedBoundaryCycle(_ walls: [PLYWallSeed], toleranceMM: Double) -> [BoundaryCycleEdge]? {
        guard walls.count >= 3 else { return nil }
        let endpointCount = walls.count * 2
        var parent = Array(0..<endpointCount)

        func endpoint(_ index: Int) -> PLYPoint2D {
            let wall = walls[index / 2]
            return index.isMultiple(of: 2) ? wall.startMM : wall.endMM
        }
        func root(_ i: Int, _ parent: inout [Int]) -> Int {
            var x = i
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func unite(_ a: Int, _ b: Int, _ parent: inout [Int]) {
            let ra = root(a, &parent), rb = root(b, &parent)
            if ra != rb { parent[rb] = ra }
        }

        for a in 0..<endpointCount {
            for b in (a + 1)..<endpointCount where a / 2 != b / 2 {
                if (endpoint(a) - endpoint(b)).length <= toleranceMM { unite(a, b, &parent) }
            }
        }

        var sums: [Int: (x: Double, y: Double, count: Int)] = [:]
        for i in 0..<endpointCount {
            let r = root(i, &parent), p = endpoint(i)
            let current = sums[r] ?? (0, 0, 0)
            sums[r] = (current.x + p.x, current.y + p.y, current.count + 1)
        }
        func nodePoint(_ r: Int) -> PLYPoint2D? {
            guard let s = sums[r], s.count > 0 else { return nil }
            return .init(x: s.x / Double(s.count), y: s.y / Double(s.count))
        }

        struct Edge { var wallIndex: Int; var a: Int; var b: Int }
        var edges: [Edge] = []
        for i in walls.indices {
            edges.append(.init(wallIndex: i, a: root(i * 2, &parent), b: root(i * 2 + 1, &parent)))
        }

        var adjacency: [Int: [Int]] = [:]
        for (edgeIndex, edge) in edges.enumerated() {
            adjacency[edge.a, default: []].append(edgeIndex)
            adjacency[edge.b, default: []].append(edgeIndex)
        }

        // Connected edge components. Only pure degree-2 components are simple closed cycles.
        var unseen = Set(edges.indices)
        var best: (area: Double, cycle: [BoundaryCycleEdge])?
        while let seedEdge = unseen.min() {
            var queue = [seedEdge]
            var componentEdges = Set<Int>()
            var componentNodes = Set<Int>()
            unseen.remove(seedEdge)
            while let edgeIndex = queue.popLast() {
                componentEdges.insert(edgeIndex)
                let edge = edges[edgeIndex]
                for node in [edge.a, edge.b] {
                    componentNodes.insert(node)
                    for neighbour in adjacency[node] ?? [] where unseen.remove(neighbour) != nil {
                        queue.append(neighbour)
                    }
                }
            }
            guard componentEdges.count >= 3, componentNodes.allSatisfy({ (adjacency[$0] ?? []).filter(componentEdges.contains).count == 2 }) else { continue }

            guard let startEdgeIndex = componentEdges.min() else { continue }
            let startEdge = edges[startEdgeIndex]
            var currentNode = startEdge.a
            var currentEdgeIndex = startEdgeIndex
            var used = Set<Int>()
            var cycle: [BoundaryCycleEdge] = []

            while !used.contains(currentEdgeIndex) {
                used.insert(currentEdgeIndex)
                let edge = edges[currentEdgeIndex]
                let nextNode = edge.a == currentNode ? edge.b : edge.a
                guard let from = nodePoint(currentNode), let to = nodePoint(nextNode) else { break }
                cycle.append(.init(wallIndex: edge.wallIndex, from: from, to: to))
                currentNode = nextNode
                guard let nextEdge = (adjacency[currentNode] ?? []).first(where: { componentEdges.contains($0) && !used.contains($0) }) else { break }
                currentEdgeIndex = nextEdge
            }

            guard cycle.count == componentEdges.count, currentNode == startEdge.a else { continue }
            let polygon = cycle.map(\.from)
            var signedArea = 0.0
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i + 1) % polygon.count]
                signedArea += a.x * b.y - b.x * a.y
            }
            let area = abs(signedArea) * 0.5
            if best.map({ area > $0.area }) ?? true { best = (area, cycle) }
        }
        return best?.cycle
    }

    func registerSingleSurfaceBoundaryToInteriorFace(_ input: [PLYWallSeed], settings: PLYSectionSettings) -> [PLYWallSeed] {
        let tolerance = min(180.0, max(35.0, settings.endpointSnapMM * 1.25, settings.lineToleranceMM))
        guard let cycle = dominantClosedBoundaryCycle(input, toleranceMM: tolerance), cycle.count >= 3 else { return input }

        var signedArea = 0.0
        for i in cycle.indices {
            let a = cycle[i].from, b = cycle[(i + 1) % cycle.count].from
            signedArea += a.x * b.y - b.x * a.y
        }
        guard abs(signedArea) > 1e-6 else { return input }
        let ccw = signedArea > 0
        var walls = input

        // Reorient every boundary member consistently around the cycle. Single-surface members are
        // shifted outward; paired-face members are already centreline measurements and stay put.
        for edge in cycle {
            var from = edge.from
            var to = edge.to
            let vector = to - from
            let length = vector.length
            guard length > 1e-6 else { continue }
            let d = vector * (1.0 / length)
            if walls[edge.wallIndex].inferenceKind == .singleSurface {
                let outward = ccw ? PLYPoint2D(x: d.y, y: -d.x) : PLYPoint2D(x: -d.y, y: d.x)
                let shift = outward * (walls[edge.wallIndex].thicknessMM * 0.5)
                from = from + shift
                to = to + shift
            }
            let resolved = to - from
            walls[edge.wallIndex].startMM = from
            walls[edge.wallIndex].lengthMM = resolved.length
            walls[edge.wallIndex].angleRadians = atan2(resolved.y, resolved.x)
        }

        // Shifted adjacent axes no longer share the old measured-face corner. Re-intersect each pair
        // so the semantic wall centrelines remain exactly joined while their interior faces remain
        // registered to the scan boundary.
        for i in cycle.indices {
            let aIndex = cycle[i].wallIndex
            let bIndex = cycle[(i + 1) % cycle.count].wallIndex
            guard let intersection = lineIntersection(walls[aIndex], walls[bIndex]) else { continue }
            setEndpoint(&walls[aIndex], isStart: false, to: intersection)
            setEndpoint(&walls[bIndex], isStart: true, to: intersection)
        }

        return walls
    }

}
