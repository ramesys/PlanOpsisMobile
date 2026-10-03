import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

final class PlanOpsisPLYCoreTests: XCTestCase {
    func testASCIIParserReadsXYZInArbitraryPropertyOrder() throws {
        let text = """
        ply
        format ascii 1.0
        element vertex 3
        property float z
        property float x
        property float y
        element face 1
        property list uchar int vertex_indices
        end_header
        0 1 2
        0 3 4
        0 5 6
        3 0 1 2
        """
        let cloud = try PLYParser().parse(data: Data(text.utf8), sourceName: "sample.ply", unit: .meters)
        XCTAssertEqual(cloud.points.count, 3)
        XCTAssertEqual(cloud.points[1], .init(x: 3, y: 4, z: 0))
    }

    func testBinaryLittleEndianParser() throws {
        var data = Data("ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nend_header\n".utf8)
        for value: Float in [1.25, -2.5, 3.75] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        let cloud = try PLYParser().parse(data: data, sourceName: "binary.ply", unit: .meters)
        XCTAssertEqual(cloud.points.count, 1)
        XCTAssertEqual(cloud.points[0].x, 1.25, accuracy: 1e-6)
        XCTAssertEqual(cloud.points[0].y, -2.5, accuracy: 1e-6)
        XCTAssertEqual(cloud.points[0].z, 3.75, accuracy: 1e-6)
    }

    func testMillimeterConversion() {
        let cloud = PLYPointCloud(sourceName: "x", sourceUnit: .meters, points: [.init(x: 1, y: 2, z: 3)])
        XCTAssertEqual(cloud.pointsInMillimeters()[0], .init(x: 1000, y: 2000, z: 3000))
    }

    func testReconstructionFindsRectangularWallFaces() {
        var points: [PLYPoint3D] = []
        // Floor support so the 2% base estimator stays at z=0.
        for x in stride(from: 0.0, through: 5000.0, by: 250.0) {
            for y in stride(from: 0.0, through: 4000.0, by: 250.0) {
                points.append(.init(x: x, y: y, z: 0))
            }
        }
        // Four wall faces represented by paired lines at a 200 mm thickness.
        for x in stride(from: 0.0, through: 5000.0, by: 40.0) {
            points.append(.init(x: x, y: 0, z: 1200)); points.append(.init(x: x, y: 200, z: 1200))
            points.append(.init(x: x, y: 3800, z: 1200)); points.append(.init(x: x, y: 4000, z: 1200))
        }
        for y in stride(from: 0.0, through: 4000.0, by: 40.0) {
            points.append(.init(x: 0, y: y, z: 1200)); points.append(.init(x: 200, y: y, z: 1200))
            points.append(.init(x: 4800, y: y, z: 1200)); points.append(.init(x: 5000, y: y, z: 1200))
        }
        let cloud = PLYPointCloud(sourceName: "room", sourceUnit: .millimeters, points: points)
        var settings = PLYSectionSettings()
        settings.voxelSizeMM = 30
        settings.lineToleranceMM = 35
        settings.minLineSupport = 15
        settings.minSegmentLengthMM = 1000
        settings.maxGapMM = 120
        settings.endpointSnapMM = 60
        let result = PLYSectionReconstructor().reconstruct(cloud: cloud, settings: settings)
        XCTAssertGreaterThanOrEqual(result.segments.count, 8)
        XCTAssertEqual(result.wallSeeds.count, 4)
        XCTAssertTrue(result.wallSeeds.allSatisfy { $0.thicknessMM >= 70 && $0.thicknessMM <= 500 })
    }

    func testDXFUsesMillimetersAndSeparateDiagnosticLayers() {
        let result = PLYReconstructionResult(
            sourceName: "x", sourcePointCount: 0, baseZMM: 0,
            localOriginMM: .init(x: 0, y: 0, z: 0), sectionPointCount: 0, downsampledPointCount: 0,
            sectionPointsMM: [],
            segments: [.init(start: .init(x: 0, y: 0), end: .init(x: 1000, y: 0), support: 10, rmsErrorMM: 1)],
            wallSeeds: []
        )
        let dxf = PLYDXFPreviewExporter().makeDXF(result: result)
        XCTAssertTrue(dxf.contains("$INSUNITS"))
        XCTAssertTrue(dxf.contains("PLY_SECTION_LINES"))
    }
}


extension PlanOpsisPLYCoreTests {
    func testReviewedWallSeedsBecomeAuthoritativePlanOpsisWalls() {
        let result = PLYReconstructionResult(
            sourceName: "survey.ply",
            sourcePointCount: 100,
            baseZMM: 0,
            localOriginMM: .init(x: 10_000, y: 20_000, z: 0),
            sectionPointCount: 40,
            downsampledPointCount: 30,
            sectionPointsMM: [],
            segments: [],
            wallSeeds: [
                .init(
                    startMM: .init(x: -2500, y: -2000),
                    lengthMM: 5000,
                    angleRadians: 0,
                    heightMM: 2800,
                    thicknessMM: 200,
                    confidence: 0.9,
                    sourceSegmentIDs: []
                )
            ]
        )
        let adapted = PLYPlanOpsisAdapter().adapt(result)
        XCTAssertEqual(adapted.acceptedWallCount, 1)
        XCTAssertEqual(adapted.rejectedWallCount, 0)
        XCTAssertEqual(adapted.project.rooms.count, 1)
        let wall = adapted.project.rooms[0].walls[0]
        XCTAssertEqual(wall.start, Point2D(x: -2500, y: -2000))
        XCTAssertEqual(wall.length, 5000)
        XCTAssertEqual(wall.height, 2800)
        XCTAssertEqual(wall.thickness, 200)
        XCTAssertEqual(wall.confidence, .high)
        XCTAssertNil(wall.sourceRoomPlanID)

        let geometry = ParametricGeometryEngine().generate(from: adapted.project)
        XCTAssertEqual(geometry.planWallSegments.count, 1)
        XCTAssertEqual(geometry.wallSolids.count, 1)

        let dxf = DXFExchangeEngine().exportValidated(project: adapted.project, representation: .semanticObservations)
        XCTAssertFalse(dxf.text.isEmpty)
        XCTAssertTrue(dxf.text.contains("IfcWall"))

        let ifc = IFC4ExchangeEngine().exportValidated(project: adapted.project)
        XCTAssertTrue(ifc.canWrite)
        XCTAssertTrue(ifc.text.contains("IFCWALL"))
    }
}

extension PlanOpsisPLYCoreTests {
    func testSingleVisibleWallFacesProduceFallbackSemanticCandidates() {
        var points: [PLYPoint3D] = []
        for x in stride(from: 0.0, through: 5000.0, by: 250.0) {
            for y in stride(from: 0.0, through: 4000.0, by: 250.0) {
                points.append(.init(x: x, y: y, z: 0))
            }
        }
        // Typical indoor scan evidence: only one room-facing surface per wall is visible.
        for x in stride(from: 0.0, through: 5000.0, by: 40.0) {
            points.append(.init(x: x, y: 0, z: 1200))
            points.append(.init(x: x, y: 4000, z: 1200))
        }
        for y in stride(from: 0.0, through: 4000.0, by: 40.0) {
            points.append(.init(x: 0, y: y, z: 1200))
            points.append(.init(x: 5000, y: y, z: 1200))
        }

        var settings = PLYSectionSettings()
        settings.voxelSizeMM = 30
        settings.lineToleranceMM = 35
        settings.minLineSupport = 12
        settings.minSegmentLengthMM = 1000
        settings.maxGapMM = 120
        settings.defaultWallThicknessMM = 150
        let result = PLYSectionReconstructor().reconstruct(
            cloud: .init(sourceName: "single-face", sourceUnit: .millimeters, points: points),
            settings: settings
        )

        XCTAssertGreaterThanOrEqual(result.segments.count, 4)
        XCTAssertGreaterThanOrEqual(result.wallSeeds.count, 4)
        XCTAssertTrue(result.wallSeeds.contains { $0.inferenceKind == .singleSurface })
        XCTAssertTrue(result.wallSeeds.filter { $0.inferenceKind == .singleSurface }.allSatisfy { abs($0.thicknessMM - 150) < 1e-6 })
    }

    func testAutoUpAxisRecognizesYUpRoomCloud() {
        var points: [PLYPoint3D] = []
        // Y is vertical; X/Z form a 5 x 4 m room plan.
        for x in stride(from: 0.0, through: 5000.0, by: 250.0) {
            for z in stride(from: 0.0, through: 4000.0, by: 250.0) {
                points.append(.init(x: x, y: 0, z: z))
            }
        }
        for x in stride(from: 0.0, through: 5000.0, by: 40.0) {
            points.append(.init(x: x, y: 1200, z: 0))
            points.append(.init(x: x, y: 1200, z: 4000))
        }
        for z in stride(from: 0.0, through: 4000.0, by: 40.0) {
            points.append(.init(x: 0, y: 1200, z: z))
            points.append(.init(x: 5000, y: 1200, z: z))
        }

        var settings = PLYSectionSettings(upAxis: .auto)
        settings.voxelSizeMM = 30
        settings.lineToleranceMM = 35
        settings.minLineSupport = 12
        settings.minSegmentLengthMM = 1000
        settings.maxGapMM = 120
        let result = PLYSectionReconstructor().reconstruct(
            cloud: .init(sourceName: "y-up", sourceUnit: .millimeters, points: points),
            settings: settings
        )

        XCTAssertEqual(result.upAxisUsed, .y)
        XCTAssertGreaterThanOrEqual(result.wallSeeds.count, 4)
    }
}

extension PlanOpsisPLYCoreTests {
    func testPLYWallNetworkExtendsShortSegmentsToTrueCornerIntersections() throws {
        let segments: [PLYPlanSegment] = [
            .init(start: .init(x: 180, y: 0), end: .init(x: 4_820, y: 0), support: 80, rmsErrorMM: 6),
            .init(start: .init(x: 5_000, y: 180), end: .init(x: 5_000, y: 3_820), support: 80, rmsErrorMM: 6),
            .init(start: .init(x: 4_820, y: 4_000), end: .init(x: 180, y: 4_000), support: 80, rmsErrorMM: 6),
            .init(start: .init(x: 0, y: 3_820), end: .init(x: 0, y: 180), support: 80, rmsErrorMM: 6)
        ]
        var settings = PLYSectionSettings()
        settings.minSegmentLengthMM = 500
        settings.defaultWallThicknessMM = 150
        settings.endpointSnapMM = 80
        settings.maxGapMM = 220
        settings.allowSingleSurfaceWalls = true
        settings.registerSingleSurfaceAsInteriorFace = false // this test asserts raw axis intersections

        let walls = PLYWallCandidateEngine().makeWallSeeds(from: segments, settings: settings)
        XCTAssertEqual(walls.count, 4)

        let corners = [
            PLYPoint2D(x: 0, y: 0),
            PLYPoint2D(x: 5_000, y: 0),
            PLYPoint2D(x: 5_000, y: 4_000),
            PLYPoint2D(x: 0, y: 4_000)
        ]
        let endpoints = walls.flatMap { [$0.startMM, $0.endMM] }
        for corner in corners {
            let coincident = endpoints.filter { ($0 - corner).length <= 1.0 }
            XCTAssertEqual(coincident.count, 2, "Expected exactly two wall axes to share corner \(corner)")
        }
    }

    func testPLYJoinedWallNetworkCreatesClosedPlanOpsisRoom() {
        let segments: [PLYPlanSegment] = [
            .init(start: .init(x: 180, y: 0), end: .init(x: 4_820, y: 0), support: 80, rmsErrorMM: 6),
            .init(start: .init(x: 5_000, y: 180), end: .init(x: 5_000, y: 3_820), support: 80, rmsErrorMM: 6),
            .init(start: .init(x: 4_820, y: 4_000), end: .init(x: 180, y: 4_000), support: 80, rmsErrorMM: 6),
            .init(start: .init(x: 0, y: 3_820), end: .init(x: 0, y: 180), support: 80, rmsErrorMM: 6)
        ]
        var settings = PLYSectionSettings()
        settings.minSegmentLengthMM = 500
        settings.endpointSnapMM = 80
        settings.maxGapMM = 220
        let walls = PLYWallCandidateEngine().makeWallSeeds(from: segments, settings: settings)

        let reconstruction = PLYReconstructionResult(
            sourceName: "gapped-room.ply",
            sourcePointCount: 0,
            baseZMM: 0,
            localOriginMM: .init(x: 0, y: 0, z: 0),
            sectionPointCount: 0,
            downsampledPointCount: 0,
            sectionPointsMM: [],
            segments: segments,
            wallSeeds: walls
        )
        let project = PLYPlanOpsisAdapter().adapt(reconstruction).project
        let geometry = ParametricGeometryEngine().generate(from: project)
        let readiness = ArchitecturalSurveyReadinessEngine().evaluate(project: project, geometry: geometry)

        XCTAssertEqual(readiness.closedRoomCount, 1)
        XCTAssertFalse(readiness.issues.contains { $0.code == .openRoomBoundary })
    }
}

extension PlanOpsisPLYCoreTests {
    func testProfessionalCleanupConsolidatesOpeningSizedFragmentsAndPrunesTinyNoise() {
        let segments: [PLYPlanSegment] = [
            // Bottom wall split by a 900 mm door-sized gap.
            .init(start: .init(x: 150, y: 0), end: .init(x: 2_050, y: 0), support: 55, rmsErrorMM: 8),
            .init(start: .init(x: 2_950, y: 0), end: .init(x: 4_850, y: 0), support: 55, rmsErrorMM: 8),
            // Right wall.
            .init(start: .init(x: 5_000, y: 150), end: .init(x: 5_000, y: 3_850), support: 90, rmsErrorMM: 7),
            // Top wall split by sparse scan evidence.
            .init(start: .init(x: 4_850, y: 4_000), end: .init(x: 2_600, y: 4_000), support: 60, rmsErrorMM: 8),
            .init(start: .init(x: 1_900, y: 4_000), end: .init(x: 150, y: 4_000), support: 50, rmsErrorMM: 8),
            // Left wall.
            .init(start: .init(x: 0, y: 3_850), end: .init(x: 0, y: 150), support: 90, rmsErrorMM: 7),
            // Small isolated furniture/scan edge.
            .init(start: .init(x: 2_100, y: 1_900), end: .init(x: 2_520, y: 1_900), support: 12, rmsErrorMM: 12)
        ]
        var settings = PLYSectionSettings()
        settings.minSegmentLengthMM = 400
        settings.wallContinuityGapMM = 1_300
        settings.maxGapMM = 220
        settings.endpointSnapMM = 90
        settings.defaultWallThicknessMM = 150
        settings.professionalCleanup = true

        let walls = PLYWallCandidateEngine().makeWallSeeds(from: segments, settings: settings)
        XCTAssertEqual(walls.count, 4)
        XCTAssertTrue(walls.allSatisfy { $0.lengthMM > 3_500 })

        let reconstruction = PLYReconstructionResult(
            sourceName: "fragmented-room.ply",
            sourcePointCount: 0,
            baseZMM: 0,
            localOriginMM: .init(x: 0, y: 0, z: 0),
            sectionPointCount: 0,
            downsampledPointCount: 0,
            sectionPointsMM: [],
            segments: segments,
            wallSeeds: walls
        )
        let project = PLYPlanOpsisAdapter().adapt(reconstruction).project
        let geometry = ParametricGeometryEngine().generate(from: project)
        let readiness = ArchitecturalSurveyReadinessEngine().evaluate(project: project, geometry: geometry)
        XCTAssertEqual(readiness.closedRoomCount, 1)
    }

    func testProfessionalCleanupCanBeDisabledForRawReview() {
        let segments: [PLYPlanSegment] = [
            .init(start: .init(x: 0, y: 0), end: .init(x: 1_800, y: 0), support: 40, rmsErrorMM: 5),
            .init(start: .init(x: 2_700, y: 0), end: .init(x: 5_000, y: 0), support: 40, rmsErrorMM: 5)
        ]
        var settings = PLYSectionSettings()
        settings.minSegmentLengthMM = 400
        settings.professionalCleanup = false
        settings.allowSingleSurfaceWalls = true

        let walls = PLYWallCandidateEngine().makeWallSeeds(from: segments, settings: settings)
        XCTAssertEqual(walls.count, 2)
    }
}

extension PlanOpsisPLYCoreTests {
    func testBoundarySolverCollapsesShortFalseCornerConnector() {
        let segments: [PLYPlanSegment] = [
            .init(start: .init(x: 0, y: 0), end: .init(x: 4_500, y: 0), support: 80, rmsErrorMM: 7),
            // Residual scan edge bridging the missed true corner. This should not survive as a wall.
            .init(start: .init(x: 4_500, y: 0), end: .init(x: 5_000, y: 500), support: 20, rmsErrorMM: 10),
            .init(start: .init(x: 5_000, y: 500), end: .init(x: 5_000, y: 4_000), support: 80, rmsErrorMM: 7)
        ]
        var settings = PLYSectionSettings()
        settings.minSegmentLengthMM = 350
        settings.wallContinuityGapMM = 1_600
        settings.endpointSnapMM = 90
        settings.professionalCleanup = true

        let walls = PLYWallCandidateEngine().makeWallSeeds(from: segments, settings: settings)
        XCTAssertEqual(walls.count, 2)
        let expected = PLYPoint2D(x: 5_000, y: 0)
        let endpoints = walls.flatMap { [$0.startMM, $0.endMM] }
        XCTAssertEqual(endpoints.filter { ($0 - expected).length <= 1.0 }.count, 2)
    }

    func testBoundarySolverBuildsClosedIrregularRoomFromTrimmedFragmentedEvidence() {
        let vertices: [PLYPoint2D] = [
            .init(x: 0, y: 0),
            .init(x: 6_000, y: 0),
            .init(x: 6_500, y: 4_500),
            .init(x: 4_200, y: 6_000),
            .init(x: 1_000, y: 5_600),
            .init(x: -1_500, y: 3_500),
            .init(x: -1_200, y: 1_200)
        ]

        func point(_ a: PLYPoint2D, _ b: PLYPoint2D, t: Double) -> PLYPoint2D {
            .init(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }

        var segments: [PLYPlanSegment] = []
        for i in vertices.indices {
            let a = vertices[i]
            let b = vertices[(i + 1) % vertices.count]
            let length = (b - a).length
            let trimT = 300.0 / length
            if i == 0 {
                // Same wall, but interrupted by an opening/occlusion-sized gap.
                segments.append(.init(start: point(a, b, t: trimT), end: point(a, b, t: 0.42), support: 65, rmsErrorMM: 8))
                segments.append(.init(start: point(a, b, t: 0.58), end: point(a, b, t: 1 - trimT), support: 65, rmsErrorMM: 8))
            } else {
                segments.append(.init(start: point(a, b, t: trimT), end: point(a, b, t: 1 - trimT), support: 70, rmsErrorMM: 8))
            }
        }
        // Disconnected furniture/scan artefact.
        segments.append(.init(start: .init(x: 2_000, y: 2_500), end: .init(x: 2_500, y: 2_500), support: 14, rmsErrorMM: 11))

        var settings = PLYSectionSettings()
        settings.minSegmentLengthMM = 350
        settings.wallContinuityGapMM = 1_600
        settings.endpointSnapMM = 90
        settings.lineToleranceMM = 45
        settings.professionalCleanup = true
        settings.registerSingleSurfaceAsInteriorFace = false // topology test uses observed axes directly

        let walls = PLYWallCandidateEngine().makeWallSeeds(from: segments, settings: settings)
        XCTAssertEqual(walls.count, vertices.count)

        let endpoints = walls.flatMap { [$0.startMM, $0.endMM] }
        for vertex in vertices {
            XCTAssertEqual(
                endpoints.filter { ($0 - vertex).length <= 2.0 }.count,
                2,
                "Expected exactly two semantic wall axes to share boundary vertex \(vertex)"
            )
        }

        let reconstruction = PLYReconstructionResult(
            sourceName: "irregular-fragmented.ply",
            sourcePointCount: 0,
            baseZMM: 0,
            localOriginMM: .init(x: 0, y: 0, z: 0),
            sectionPointCount: 0,
            downsampledPointCount: 0,
            sectionPointsMM: [],
            segments: segments,
            wallSeeds: walls
        )
        let project = PLYPlanOpsisAdapter().adapt(reconstruction).project
        let geometry = ParametricGeometryEngine().generate(from: project)
        let readiness = ArchitecturalSurveyReadinessEngine().evaluate(project: project, geometry: geometry)
        XCTAssertEqual(readiness.closedRoomCount, 1)
        XCTAssertFalse(readiness.issues.contains { $0.code == .openRoomBoundary })
    }
}

extension PlanOpsisPLYCoreTests {
    func testSingleSurfaceBoundaryRegistersMeasuredFaceToInteriorWallFace() {
        let segments: [PLYPlanSegment] = [
            .init(start: .init(x: 0, y: 0), end: .init(x: 5_000, y: 0), support: 80, rmsErrorMM: 5),
            .init(start: .init(x: 5_000, y: 0), end: .init(x: 5_000, y: 4_000), support: 80, rmsErrorMM: 5),
            .init(start: .init(x: 5_000, y: 4_000), end: .init(x: 0, y: 4_000), support: 80, rmsErrorMM: 5),
            .init(start: .init(x: 0, y: 4_000), end: .init(x: 0, y: 0), support: 80, rmsErrorMM: 5)
        ]
        var settings = PLYSectionSettings()
        settings.minSegmentLengthMM = 500
        settings.defaultWallThicknessMM = 200
        settings.professionalCleanup = true
        settings.registerSingleSurfaceAsInteriorFace = true

        let walls = PLYWallCandidateEngine().makeWallSeeds(from: segments, settings: settings)
        XCTAssertEqual(walls.count, 4)
        let endpoints = walls.flatMap { [$0.startMM, $0.endMM] }
        XCTAssertEqual(endpoints.map(\.x).min()!, -100, accuracy: 2)
        XCTAssertEqual(endpoints.map(\.x).max()!, 5_100, accuracy: 2)
        XCTAssertEqual(endpoints.map(\.y).min()!, -100, accuracy: 2)
        XCTAssertEqual(endpoints.map(\.y).max()!, 4_100, accuracy: 2)
    }
}

extension PlanOpsisPLYCoreTests {
    func testPLYStructuralCandidatesDetectCompactColumnAndUpperBeam() {
        var points: [PLYPoint3D] = []
        // Floor/base support.
        for x in stride(from: 0.0, through: 5_000.0, by: 250.0) {
            for y in stride(from: 0.0, through: 4_000.0, by: 250.0) {
                points.append(.init(x: x, y: y, z: 0))
            }
        }
        // Four room-facing wall surfaces at the plan section.
        for x in stride(from: 0.0, through: 5_000.0, by: 40.0) {
            points.append(.init(x: x, y: 0, z: 1_200))
            points.append(.init(x: x, y: 4_000, z: 1_200))
        }
        for y in stride(from: 0.0, through: 4_000.0, by: 40.0) {
            points.append(.init(x: 0, y: y, z: 1_200))
            points.append(.init(x: 5_000, y: y, z: 1_200))
        }

        // Compact freestanding column evidence repeated through height.
        let columnCenter = PLYPoint2D(x: 2_500, y: 2_000)
        for z in [500.0, 1_320.0, 2_100.0] {
            for x in stride(from: columnCenter.x - 180, through: columnCenter.x + 180, by: 60.0) {
                for y in stride(from: columnCenter.y - 180, through: columnCenter.y + 180, by: 60.0) {
                    points.append(.init(x: x, y: y, z: z))
                }
            }
        }

        // Beam side evidence high in the room, spanning through the column.
        for x in stride(from: 1_000.0, through: 4_000.0, by: 45.0) {
            points.append(.init(x: x, y: 1_875, z: 2_450))
            points.append(.init(x: x, y: 2_125, z: 2_450))
        }

        var settings = PLYSectionSettings()
        settings.upAxis = .z
        settings.sectionThicknessMM = 100
        settings.voxelSizeMM = 30
        settings.lineToleranceMM = 40
        settings.minLineSupport = 10
        settings.minSegmentLengthMM = 700
        settings.detectStructuralElements = true
        settings.structuralGridMM = 120
        settings.defaultBeamWidthMM = 250
        settings.defaultBeamDepthMM = 350

        let result = PLYSectionReconstructor().reconstruct(
            cloud: .init(sourceName: "structure.ply", sourceUnit: .millimeters, points: points),
            settings: settings
        )
        XCTAssertFalse(result.wallSeeds.isEmpty)
        XCTAssertTrue(result.structuralSeeds.contains { $0.kind == .column })
        XCTAssertTrue(result.structuralSeeds.contains { $0.kind == .beam && $0.widthMM >= 800 && $0.elevationMM > 1_500 })
    }

    func testPLYStructuralSeedsBecomeColumnAndBeamWithIFCAndDXFLayers() {
        let result = PLYReconstructionResult(
            sourceName: "structure.ply",
            sourcePointCount: 100,
            baseZMM: 0,
            localOriginMM: .init(x: 0, y: 0, z: 0),
            sectionPointCount: 20,
            downsampledPointCount: 20,
            sectionPointsMM: [],
            segments: [],
            wallSeeds: [
                .init(startMM: .init(x: 0, y: 0), lengthMM: 5_000, angleRadians: 0, heightMM: 2_800,
                      thicknessMM: 180, confidence: 0.9, sourceSegmentIDs: [])
            ],
            structuralSeeds: [
                .init(kind: .column, centerMM: .init(x: 1_000, y: 1_000), widthMM: 350, depthMM: 350,
                      heightMM: 2_800, confidence: 0.85),
                .init(kind: .beam, centerMM: .init(x: 2_500, y: 2_000), widthMM: 3_500, depthMM: 250,
                      heightMM: 350, elevationMM: 2_450, rotationRadians: 0, confidence: 0.75)
            ]
        )
        let adapted = PLYPlanOpsisAdapter().adapt(result)
        XCTAssertEqual(adapted.acceptedStructuralCount, 2)
        XCTAssertEqual(adapted.project.rooms[0].components.filter { $0.kind == .column }.count, 1)
        let beam = try! XCTUnwrap(adapted.project.rooms[0].components.first { $0.kind == .beam })
        XCTAssertEqual(beam.baseElevationMM, 2_450, accuracy: 0.001)

        let dxf = DXFExchangeEngine().exportValidated(project: adapted.project, representation: .semanticObservations)
        XCTAssertTrue(dxf.text.contains("IfcColumn"))
        XCTAssertTrue(dxf.text.contains("IfcBeam"))
        let ifc = IFC4ExchangeEngine().exportValidated(project: adapted.project)
        XCTAssertTrue(ifc.text.contains("IFCCOLUMN"))
        XCTAssertTrue(ifc.text.contains("IFCBEAM"))
    }
}

extension PlanOpsisPLYCoreTests {
    func testReconstructionQAReportsResidualsAndClosedWallSupport() {
        var points: [PLYPoint3D] = []
        // Dense room-facing section evidence at z=1200 mm plus floor evidence for base estimation.
        for x in stride(from: 0.0, through: 5_000.0, by: 35.0) {
            points.append(.init(x: x, y: 0, z: 1_200))
            points.append(.init(x: x, y: 4_000, z: 1_200))
            points.append(.init(x: x, y: 0, z: 0))
        }
        for y in stride(from: 0.0, through: 4_000.0, by: 35.0) {
            points.append(.init(x: 0, y: y, z: 1_200))
            points.append(.init(x: 5_000, y: y, z: 1_200))
            points.append(.init(x: 0, y: y, z: 0))
        }

        var settings = PLYSectionSettings()
        settings.upAxis = .z
        settings.sectionThicknessMM = 100
        settings.voxelSizeMM = 30
        settings.lineToleranceMM = 45
        settings.minLineSupport = 8
        settings.minSegmentLengthMM = 500
        settings.detectStructuralElements = false
        settings.noiseSuppressionEnabled = true

        let result = PLYSectionReconstructor().reconstruct(
            cloud: .init(sourceName: "qa-room.ply", sourceUnit: .millimeters, points: points),
            settings: settings
        )

        XCTAssertEqual(result.wallSeeds.count, 4)
        XCTAssertEqual(result.qa.unresolvedWallEnds, 0)
        XCTAssertGreaterThan(result.qa.wallSupportFraction, 0.80)
        XCTAssertNotNil(result.qa.meanSupportedResidualMM)
        XCTAssertLessThan(result.qa.meanSupportedResidualMM ?? .infinity, 80)
        XCTAssertEqual(result.qa.suppressedWallCount, result.suppressedWallSeeds.count)
    }

    func testQAReviewAndSuppressedWallsDoNotEnterSemanticModelUnlessPromoted() {
        let accepted = PLYWallSeed(
            startMM: .init(x: 0, y: 0), lengthMM: 4_000, angleRadians: 0,
            heightMM: 2_700, thicknessMM: 180, confidence: 0.9, sourceSegmentIDs: []
        )
        let review = PLYWallSeed(
            startMM: .init(x: 0, y: 1_000), lengthMM: 1_200, angleRadians: 0,
            heightMM: 2_700, thicknessMM: 180, confidence: 0.5, sourceSegmentIDs: []
        )
        let suppressed = PLYWallSeed(
            startMM: .init(x: 2_000, y: 2_000), lengthMM: 450, angleRadians: 0,
            heightMM: 2_700, thicknessMM: 180, confidence: 0.2, sourceSegmentIDs: []
        )
        let result = PLYReconstructionResult(
            sourceName: "qa-boundary.ply",
            sourcePointCount: 0,
            baseZMM: 0,
            localOriginMM: .init(x: 0, y: 0, z: 0),
            sectionPointCount: 0,
            downsampledPointCount: 0,
            sectionPointsMM: [],
            segments: [],
            wallSeeds: [accepted],
            reviewWallSeeds: [review],
            suppressedWallSeeds: [suppressed]
        )
        let adapted = PLYPlanOpsisAdapter().adapt(result)
        XCTAssertEqual(adapted.project.rooms.first?.walls.count, 1)
        XCTAssertEqual(adapted.acceptedWallCount, 1)
    }

    func testDiagnosticDXFSeparatesAcceptedReviewAndSuppressedQALayers() {
        let base = PLYWallSeed(
            startMM: .init(x: 0, y: 0), lengthMM: 1_000, angleRadians: 0,
            heightMM: 2_700, thicknessMM: 180, confidence: 0.8, sourceSegmentIDs: []
        )
        var review = base; review.id = UUID(); review.startMM = .init(x: 0, y: 500)
        var suppressed = base; suppressed.id = UUID(); suppressed.startMM = .init(x: 0, y: 1_000)
        let result = PLYReconstructionResult(
            sourceName: "qa-dxf.ply", sourcePointCount: 0, baseZMM: 0,
            localOriginMM: .init(x: 0, y: 0, z: 0), sectionPointCount: 0,
            downsampledPointCount: 0, sectionPointsMM: [], segments: [], wallSeeds: [base],
            reviewWallSeeds: [review], suppressedWallSeeds: [suppressed]
        )
        let dxf = PLYDXFPreviewExporter().makeDXF(result: result)
        XCTAssertTrue(dxf.contains("PLY_WALL_ACCEPTED"))
        XCTAssertTrue(dxf.contains("PLY_WALL_REVIEW"))
        XCTAssertTrue(dxf.contains("PLY_WALL_SUPPRESSED"))
    }
}

extension PlanOpsisPLYCoreTests {
    func testV119ReviewedTopologyMergesHumanSelectedCollinearFragments() {
        let walls: [PLYWallSeed] = [
            .init(startMM: .init(x: 0, y: 0), lengthMM: 1_800, angleRadians: 0, heightMM: 2_700,
                  thicknessMM: 180, confidence: 0.7, inferenceKind: .singleSurface, sourceSegmentIDs: []),
            .init(startMM: .init(x: 2_700, y: 0), lengthMM: 2_300, angleRadians: 0, heightMM: 2_700,
                  thicknessMM: 180, confidence: 0.7, inferenceKind: .singleSurface, sourceSegmentIDs: [])
        ]
        var settings = PLYSectionSettings()
        settings.professionalCleanup = true
        settings.wallContinuityGapMM = 1_200
        settings.registerSingleSurfaceAsInteriorFace = true

        let reviewed = PLYWallCandidateEngine().refineReviewedWallNetwork(walls, settings: settings)
        XCTAssertEqual(reviewed.count, 1)
        XCTAssertEqual(reviewed[0].startMM.x, 0, accuracy: 1)
        XCTAssertEqual(reviewed[0].startMM.y, 0, accuracy: 1)
        XCTAssertEqual(reviewed[0].lengthMM, 5_000, accuracy: 2)
    }

    func testV119ReviewedQAReflectsExactHumanSelectedNetwork() {
        let rectangle: [PLYWallSeed] = [
            .init(startMM: .init(x: 0, y: 0), lengthMM: 5_000, angleRadians: 0, heightMM: 2_700, thicknessMM: 180, confidence: 0.9, sourceSegmentIDs: []),
            .init(startMM: .init(x: 5_000, y: 0), lengthMM: 4_000, angleRadians: .pi / 2, heightMM: 2_700, thicknessMM: 180, confidence: 0.9, sourceSegmentIDs: []),
            .init(startMM: .init(x: 5_000, y: 4_000), lengthMM: 5_000, angleRadians: .pi, heightMM: 2_700, thicknessMM: 180, confidence: 0.9, sourceSegmentIDs: []),
            .init(startMM: .init(x: 0, y: 4_000), lengthMM: 4_000, angleRadians: -.pi / 2, heightMM: 2_700, thicknessMM: 180, confidence: 0.9, sourceSegmentIDs: [])
        ]
        let isolated = PLYWallSeed(startMM: .init(x: 2_000, y: 2_000), lengthMM: 500, angleRadians: 0,
                                   heightMM: 2_700, thicknessMM: 180, confidence: 0.4, sourceSegmentIDs: [])
        let points = rectangle.flatMap { wall -> [PLYPoint2D] in
            let d = PLYPoint2D(x: cos(wall.angleRadians), y: sin(wall.angleRadians))
            return stride(from: 0.0, through: wall.lengthMM, by: 250).map { wall.startMM + d * $0 }
        }
        let settings = PLYSectionSettings()
        let engine = PLYReconstructionQAEngine()
        let clean = engine.reviewedReport(sectionPoints: points, segments: [], walls: rectangle, structure: [], settings: settings)
        let noisy = engine.reviewedReport(sectionPoints: points, segments: [], walls: rectangle + [isolated], structure: [], settings: settings)
        XCTAssertEqual(clean.unresolvedWallEnds, 0)
        XCTAssertGreaterThan(noisy.unresolvedWallEnds, clean.unresolvedWallEnds)
        XCTAssertEqual(clean.acceptedWallCount, 4)
        XCTAssertEqual(noisy.acceptedWallCount, 5)
    }

    func testV119PostReviewTopologyDoesNotApplyScanFaceOffsetTwice() {
        let registered: [PLYWallSeed] = [
            .init(startMM: .init(x: -100, y: -100), lengthMM: 5_200, angleRadians: 0, heightMM: 2_700,
                  thicknessMM: 200, confidence: 0.8, inferenceKind: .singleSurface, sourceSegmentIDs: []),
            .init(startMM: .init(x: 5_100, y: -100), lengthMM: 4_200, angleRadians: .pi / 2, heightMM: 2_700,
                  thicknessMM: 200, confidence: 0.8, inferenceKind: .singleSurface, sourceSegmentIDs: []),
            .init(startMM: .init(x: 5_100, y: 4_100), lengthMM: 5_200, angleRadians: .pi, heightMM: 2_700,
                  thicknessMM: 200, confidence: 0.8, inferenceKind: .singleSurface, sourceSegmentIDs: []),
            .init(startMM: .init(x: -100, y: 4_100), lengthMM: 4_200, angleRadians: -.pi / 2, heightMM: 2_700,
                  thicknessMM: 200, confidence: 0.8, inferenceKind: .singleSurface, sourceSegmentIDs: [])
        ]
        var settings = PLYSectionSettings()
        settings.professionalCleanup = true
        settings.registerSingleSurfaceAsInteriorFace = true
        let refined = PLYWallCandidateEngine().refineReviewedWallNetwork(registered, settings: settings)
        let endpoints = refined.flatMap { [$0.startMM, $0.endMM] }
        XCTAssertEqual(endpoints.map(\.x).min()!, -100, accuracy: 2)
        XCTAssertEqual(endpoints.map(\.x).max()!, 5_100, accuracy: 2)
        XCTAssertEqual(endpoints.map(\.y).min()!, -100, accuracy: 2)
        XCTAssertEqual(endpoints.map(\.y).max()!, 4_100, accuracy: 2)
    }
}


extension PlanOpsisPLYCoreTests {
    func testPreV12ParserRejectsNegativeElementCount() {
        let text = """
        ply
        format ascii 1.0
        element vertex -1
        property float x
        property float y
        property float z
        end_header
        """
        XCTAssertThrowsError(try PLYParser().parse(data: Data(text.utf8), sourceName: "negative-count.ply", unit: .millimeters))
    }

    func testPreV12ParserRejectsNegativeASCIIListCount() {
        let text = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        element face 1
        property list uchar int vertex_indices
        end_header
        0 0 0
        -1
        """
        XCTAssertThrowsError(try PLYParser().parse(data: Data(text.utf8), sourceName: "negative-list.ply", unit: .millimeters))
    }

    func testPreV12ParserRejectsFloatingListCountType() {
        let text = """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        element face 1
        property list float int vertex_indices
        end_header
        0 0 0
        0
        """
        XCTAssertThrowsError(try PLYParser().parse(data: Data(text.utf8), sourceName: "float-list-count.ply", unit: .millimeters))
    }
}

extension PlanOpsisPLYCoreTests {
    func testPreV12ReconstructionGeometryIsRepeatableIgnoringEphemeralIDs() {
        var points: [PLYPoint3D] = []
        for x in stride(from: 0.0, through: 5_000.0, by: 50.0) {
            points.append(.init(x: x, y: 0, z: 1_200))
            points.append(.init(x: x, y: 4_000, z: 1_200))
        }
        for y in stride(from: 0.0, through: 4_000.0, by: 50.0) {
            points.append(.init(x: 0, y: y, z: 1_200))
            points.append(.init(x: 5_000, y: y, z: 1_200))
        }
        for x in stride(from: 0.0, through: 5_000.0, by: 250.0) {
            points.append(.init(x: x, y: 2_000, z: 0))
        }

        let cloud = PLYPointCloud(sourceName: "repeatable", sourceUnit: .millimeters, points: points)
        var settings = PLYSectionSettings()
        settings.allowSingleSurfaceWalls = true
        settings.professionalCleanup = true
        settings.voxelSizeMM = 35
        settings.minLineSupport = 10
        settings.minSegmentLengthMM = 900

        let a = PLYSectionReconstructor().reconstruct(cloud: cloud, settings: settings)
        let b = PLYSectionReconstructor().reconstruct(cloud: cloud, settings: settings)

        func wallSignature(_ result: PLYReconstructionResult) -> [[Int]] {
            result.wallSeeds.map { wall in
                [Int(wall.startMM.x.rounded()), Int(wall.startMM.y.rounded()),
                 Int(wall.endMM.x.rounded()), Int(wall.endMM.y.rounded()),
                 Int(wall.thicknessMM.rounded())]
            }.sorted { $0.lexicographicallyPrecedes($1) }
        }
        func segmentSignature(_ result: PLYReconstructionResult) -> [[Int]] {
            result.segments.map { segment in
                [Int(segment.start.x.rounded()), Int(segment.start.y.rounded()),
                 Int(segment.end.x.rounded()), Int(segment.end.y.rounded()), segment.support]
            }.sorted { $0.lexicographicallyPrecedes($1) }
        }

        XCTAssertEqual(segmentSignature(a), segmentSignature(b))
        XCTAssertEqual(wallSignature(a), wallSignature(b))
        XCTAssertEqual(a.qa.unresolvedWallEnds, b.qa.unresolvedWallEnds)
    }
}

extension PlanOpsisPLYCoreTests {
    func testPreV12ParserDoesNotTreatCommentSubstringAsEndHeader() throws {
        let text = """
        ply
        format ascii 1.0
        comment this text mentions end_header but is not the terminator
        element vertex 1
        property float x
        property float y
        property float z
        end_header
        1 2 3
        """
        let cloud = try PLYParser().parse(data: Data(text.utf8), sourceName: "comment-marker.ply", unit: .millimeters)
        XCTAssertEqual(cloud.points, [.init(x: 1, y: 2, z: 3)])
    }

    func testPreV12ParserRejectsMissingCoordinateFromHeaderEvenWithZeroVertices() {
        let text = """
        ply
        format ascii 1.0
        element vertex 0
        property float x
        property float y
        end_header
        """
        XCTAssertThrowsError(try PLYParser().parse(data: Data(text.utf8), sourceName: "missing-z.ply", unit: .millimeters))
    }
}
