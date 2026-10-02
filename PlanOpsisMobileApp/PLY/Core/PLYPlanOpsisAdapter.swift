import Foundation

/// Converts reviewed PLY reconstruction evidence into the authoritative PlanOpsis semantic model.
/// The point cloud and detected segments remain evidence only; editable geometry is represented by
/// ordinary PlanOpsisWall values so all existing 2D, 3D, DXF, IFC, editing and persistence code is reused.
public struct PLYPlanOpsisAdapter: Sendable {
    public struct Result: Sendable {
        public var project: PlanOpsisProject
        public var acceptedWallCount: Int
        public var rejectedWallCount: Int
        public var acceptedStructuralCount: Int
        public var rejectedStructuralCount: Int

        public init(
            project: PlanOpsisProject,
            acceptedWallCount: Int,
            rejectedWallCount: Int,
            acceptedStructuralCount: Int = 0,
            rejectedStructuralCount: Int = 0
        ) {
            self.project = project
            self.acceptedWallCount = acceptedWallCount
            self.rejectedWallCount = rejectedWallCount
            self.acceptedStructuralCount = acceptedStructuralCount
            self.rejectedStructuralCount = rejectedStructuralCount
        }
    }

    public init() {}

    public func adapt(_ reconstruction: PLYReconstructionResult) -> Result {
        var walls: [PlanOpsisWall] = []
        var rejected = 0

        for seed in reconstruction.wallSeeds {
            guard seed.startMM.x.isFinite,
                  seed.startMM.y.isFinite,
                  seed.lengthMM.isFinite,
                  seed.angleRadians.isFinite,
                  seed.heightMM.isFinite,
                  seed.thicknessMM.isFinite,
                  seed.lengthMM >= 100,
                  seed.heightMM > 0,
                  seed.thicknessMM > 0 else {
                rejected += 1
                continue
            }

            walls.append(
                PlanOpsisWall(
                    start: Point2D(x: seed.startMM.x, y: seed.startMM.y),
                    length: seed.lengthMM,
                    angleRadians: seed.angleRadians,
                    height: seed.heightMM,
                    thickness: seed.thicknessMM,
                    confidence: captureConfidence(for: seed.confidence)
                )
            )
        }

        var components: [PlanOpsisComponent] = []
        var rejectedStructure = 0
        for seed in reconstruction.structuralSeeds {
            // v11.8: reconstruction.structuralSeeds already contains only automatic-QA accepts plus
            // any candidates explicitly accepted by the user. The semantic adapter validates geometry
            // but does not second-guess that review decision with a second hidden confidence threshold.
            guard seed.centerMM.x.isFinite, seed.centerMM.y.isFinite,
                  seed.widthMM.isFinite, seed.depthMM.isFinite, seed.heightMM.isFinite,
                  seed.elevationMM.isFinite, seed.rotationRadians.isFinite,
                  seed.widthMM >= 80, seed.depthMM >= 80, seed.heightMM >= 80 else {
                rejectedStructure += 1
                continue
            }
            let kind: PlanOpsisComponent.Kind = seed.kind == .column ? .column : .beam
            components.append(
                PlanOpsisComponent(
                    kind: kind,
                    position: Point2D(x: seed.centerMM.x, y: seed.centerMM.y),
                    width: seed.widthMM,
                    depth: seed.depthMM,
                    height: seed.heightMM,
                    elevationMM: seed.kind == .beam ? seed.elevationMM : 0,
                    rotationRadians: seed.rotationRadians
                )
            )
        }

        // Keep the reconstruction ordering deterministic for a given result while minting fresh
        // PlanOpsis UUIDs at the semantic boundary. IDs then persist through normal project saving.
        let room = PlanOpsisRoom(walls: walls, components: components)
        return Result(
            project: PlanOpsisProject(rooms: [room]),
            acceptedWallCount: walls.count,
            rejectedWallCount: rejected,
            acceptedStructuralCount: components.count,
            rejectedStructuralCount: rejectedStructure
        )
    }

    private func captureConfidence(for value: Double) -> CaptureConfidence {
        guard value.isFinite else { return .unknown }
        if value >= 0.80 { return .high }
        if value >= 0.50 { return .medium }
        return .low
    }
}
