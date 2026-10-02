#if os(iOS)
import Foundation
import Combine
import RoomPlan
import ARKit
import simd

/// Owns RoomPlan capture state, but deliberately does not own the heavy RoomCaptureView.
/// SwiftUI owns the view only while the Scan workspace is mounted, so its Metal/AR resources
/// can be released as soon as capture ends.
@MainActor
final class RoomPlanCaptureService: NSObject, ObservableObject, @preconcurrency RoomCaptureViewDelegate {
    enum PendingStopAction {
        case keepStructureSession
        case finishStructure
    }

    @Published private(set) var structureSnapshot: StructureCaptureSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isScanning = false
    @Published private(set) var isBuildingStructure = false
    @Published private(set) var isProcessingRoom = false
    @Published private(set) var capturedRoomCount = 0

    /// Weak by design. Retaining RoomCaptureView here kept its Metal/AR resources alive for the
    /// lifetime of the app even after leaving Scan. The representable owns it instead.
    private weak var captureView: RoomCaptureView?
    private var capturedRooms: [CapturedRoom] = []
    private var pendingStopAction: PendingStopAction?

    override init() {
        super.init()
    }

    /// RoomCaptureViewDelegate inherits NSCoding in Apple's RoomPlan API.
    /// The service has no archiveable state; this initializer only satisfies delegate conformance.
    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {
        // No persisted delegate/view state. PlanOpsis persists only its semantic project model.
    }

    var isSupported: Bool { RoomCaptureSession.isSupported }

    /// True from the first scan start until the structure is either completed or cancelled.
    /// Keeping the Scan workspace mounted across the gap between rooms preserves the shared AR world
    /// required by StructureBuilder for trustworthy multi-room alignment.
    var isStructureCaptureActive: Bool {
        isScanning || isProcessingRoom || isBuildingStructure ||
        (capturedRoomCount > 0 && structureSnapshot == nil)
    }

    func attachCaptureView(_ view: RoomCaptureView) {
        if let current = captureView, current !== view {
            current.delegate = nil
            current.captureSession.stop()
        }
        captureView = view
        view.delegate = self
    }

    func detachCaptureView(_ view: RoomCaptureView) {
        guard captureView === view else { return }
        view.delegate = nil
        captureView = nil
    }

    func startStructure() {
        guard !isScanning, !isBuildingStructure, !isProcessingRoom else { return }
        guard captureView != nil else {
            errorMessage = "The RoomPlan capture view is not ready yet. Reopen Scan and try again."
            return
        }
        capturedRooms.removeAll(keepingCapacity: false)
        capturedRoomCount = 0
        structureSnapshot = nil
        errorMessage = nil
        startNextRoom()
    }

    func startNextRoom() {
        guard isSupported else {
            errorMessage = "RoomPlan requires a LiDAR-capable iPhone or iPad. Use the deterministic mock capture in Simulator."
            return
        }
        guard let captureView else {
            errorMessage = "The RoomPlan capture view is unavailable. Return to Scan and try again."
            return
        }
        guard !isScanning, !isBuildingStructure, !isProcessingRoom else { return }

        errorMessage = nil
        pendingStopAction = nil
        var configuration = RoomCaptureSession.Configuration()
        // Coaching remains enabled because it improves capture quality and is implemented inside RoomPlan.
        // PlanOpsis itself avoids additional translucent/animated overlays during capture.
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
        isScanning = true
    }

    /// Completes the current room but deliberately keeps the shared AR session alive.
    /// This preserves a compatible world space for the next room scan.
    func finishRoom() {
        guard let captureView, isScanning else { return }
        pendingStopAction = .keepStructureSession
        isProcessingRoom = true
        captureView.captureSession.stop(pauseARSession: false)
        isScanning = false
    }

    /// Finishes the current room if necessary, then produces one structure snapshot.
    func finishStructure() {
        guard !isBuildingStructure else { return }

        if isScanning, let captureView {
            pendingStopAction = .finishStructure
            isProcessingRoom = true
            // Default stop pauses AR; no further room needs the shared world after Finish Structure.
            captureView.captureSession.stop()
            isScanning = false
        } else {
            // Important when Finish Room used stop(pauseARSession: false): explicitly pause the shared
            // AR session before normalization/StructureBuilder so camera+Metal work does not continue
            // in the background while PlanOpsis builds the architectural model.
            captureView?.captureSession.stop()
            buildStructureIfPossible()
        }
    }

    func cancelStructure() {
        // Always stop, including the between-room state where isScanning == false but the shared
        // ARSession was intentionally left alive by stop(pauseARSession: false).
        captureView?.captureSession.stop()
        isScanning = false
        isBuildingStructure = false
        isProcessingRoom = false
        pendingStopAction = nil
        capturedRooms.removeAll(keepingCapacity: false)
        capturedRoomCount = 0
        structureSnapshot = nil
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            captureView?.captureSession.stop()
            errorMessage = error.localizedDescription
            isScanning = false
            isProcessingRoom = false
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        isScanning = false
        isProcessingRoom = false
        if let error {
            captureView?.captureSession.stop()
            errorMessage = error.localizedDescription
            pendingStopAction = nil
            return
        }

        // A CapturedRoom is transient capture evidence only. Retain it only until a final structure
        // snapshot is produced. This matters on memory-constrained devices because CapturedRoom may
        // keep substantial RoomPlan evidence alive.
        capturedRooms.append(processedResult)
        capturedRoomCount = capturedRooms.count

        let action = pendingStopAction
        pendingStopAction = nil

        if case .finishStructure? = action {
            buildStructureIfPossible()
        }
    }

    private func buildStructureIfPossible() {
        guard !capturedRooms.isEmpty else {
            errorMessage = "Capture at least one room before finishing the structure."
            return
        }

        // Ensure RoomPlan is no longer spending camera/AR/Metal resources during conversion.
        captureView?.captureSession.stop()
        isBuildingStructure = true
        errorMessage = nil
        let rooms = capturedRooms

        // Fast path for the product's primary LiDAR -> DXF workflow. A single room already has one
        // coherent RoomPlan coordinate system and does not need StructureBuilder at all.
        if rooms.count == 1, let room = rooms.first {
            let snapshot = StructureCaptureSnapshot(room: RoomPlanSnapshotNormalizer.snapshot(from: room))
            capturedRooms.removeAll(keepingCapacity: false)
            isBuildingStructure = false
            structureSnapshot = snapshot
            return
        }

        Task { @MainActor in
            do {
                let structure = try await StructureBuilder(options: []).capturedStructure(from: rooms)
                let snapshot = RoomPlanSnapshotNormalizer.snapshot(from: structure)
                capturedRooms.removeAll(keepingCapacity: false)
                isBuildingStructure = false
                structureSnapshot = snapshot
            } catch {
                // Do not silently import independently normalized rooms after a merge failure:
                // they may not occupy a trustworthy common world space.
                errorMessage = "RoomPlan could not merge the room scans into one structure: \(error.localizedDescription)"
                isBuildingStructure = false
            }
        }
    }
}

enum RoomPlanSnapshotNormalizer {
    static func snapshot(from room: CapturedRoom) -> RoomCaptureSnapshot {
        var surfaces: [CapturedSurfaceSnapshot] = []
        surfaces.reserveCapacity(room.walls.count + room.doors.count + room.windows.count + room.openings.count)
        surfaces.append(contentsOf: room.walls.map { surface($0, category: .wall) })
        surfaces.append(contentsOf: room.doors.map { surface($0, category: .door) })
        surfaces.append(contentsOf: room.windows.map { surface($0, category: .window) })
        surfaces.append(contentsOf: room.openings.map { surface($0, category: .opening) })
        return RoomCaptureSnapshot(sourceRoomPlanID: room.identifier, surfaces: surfaces)
    }

    static func snapshot(from structure: CapturedStructure) -> StructureCaptureSnapshot {
        StructureCaptureSnapshot(
            sourceStructureRoomPlanID: structure.identifier,
            rooms: structure.rooms.map { snapshot(from: $0) }
        )
    }

    private static func surface(
        _ surface: CapturedRoom.Surface,
        category: CapturedSurfaceCategory
    ) -> CapturedSurfaceSnapshot {
        CapturedSurfaceSnapshot(
            sourceRoomPlanID: surface.identifier,
            parentIdentifier: surface.parentIdentifier,
            category: category,
            transform: transform(surface.transform),
            dimensions: Dimensions3D(
                x: Double(surface.dimensions.x),
                y: Double(surface.dimensions.y),
                z: Double(surface.dimensions.z)
            ),
            confidence: confidence(surface.confidence),
            shapeHints: CapturedSurfaceShapeHints(
                hasCurve: surface.curve != nil,
                polygonCornerCount: surface.polygonCorners.count,
                completedEdgeCount: surface.completedEdges.count
            )
        )
    }

    private static func transform(_ matrix: simd_float4x4) -> TransformSnapshot {
        TransformSnapshot(values: [
            Double(matrix.columns.0.x), Double(matrix.columns.0.y), Double(matrix.columns.0.z), Double(matrix.columns.0.w),
            Double(matrix.columns.1.x), Double(matrix.columns.1.y), Double(matrix.columns.1.z), Double(matrix.columns.1.w),
            Double(matrix.columns.2.x), Double(matrix.columns.2.y), Double(matrix.columns.2.z), Double(matrix.columns.2.w),
            Double(matrix.columns.3.x), Double(matrix.columns.3.y), Double(matrix.columns.3.z), Double(matrix.columns.3.w)
        ])
    }

    private static func confidence(_ value: CapturedRoom.Confidence) -> CaptureConfidence {
        switch value {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        @unknown default: return .unknown
        }
    }
}
#endif
