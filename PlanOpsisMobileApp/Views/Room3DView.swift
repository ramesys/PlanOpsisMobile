#if os(iOS)
import SwiftUI
import RealityKit
import UIKit

struct Room3DView: UIViewRepresentable {
    let snapshot: DisplayGeometrySnapshot
    let components: [PlanOpsisComponent]
    let selectedID: UUID?
    let selectedIDs: Set<UUID>
    let onSelect: (UUID?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        // On 3x iPhones a full-resolution drawable is unnecessarily expensive for this technical
        // CAD preview. Two pixels per point materially reduces CAMetalLayer allocation pressure.
        view.contentScaleFactor = min(view.traitCollection.displayScale, 2.0)
        // PlanOpsis uses RealityKit as a lightweight CAD viewer, not a cinematic renderer.
        // Disable effects that add GPU passes/memory pressure and are unnecessary for technical review.
        view.renderOptions.insert([
            .disableGroundingShadows,
            .disableHDR,
            .disableMotionBlur,
            .disableDepthOfField,
            .disableCameraGrain,
            .disableAREnvironmentLighting
        ])
        context.coordinator.attach(to: view)
        context.coordinator.rebuild(snapshot: snapshot, components: components, selectedID: selectedID, selectedIDs: selectedIDs)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.rebuild(snapshot: snapshot, components: components, selectedID: selectedID, selectedIDs: selectedIDs)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.teardown(from: uiView)
    }

    final class Coordinator: NSObject {
        var onSelect: (UUID?) -> Void
        private weak var arView: ARView?
        private let sceneAnchor = AnchorEntity(world: .zero)
        private let modelRoot = Entity()
        private let camera = PerspectiveCamera()
        private var yaw: Float = .pi / 4
        private var pitch: Float = 0.55
        private var radius: Float = 6
        private var target = SIMD3<Float>(0, 1, 0)
        private var lastSnapshot: DisplayGeometrySnapshot?
        private var lastComponents: [PlanOpsisComponent] = []
        private var lastSelectedID: UUID?
        private var lastSelectedIDs: Set<UUID> = []

        init(onSelect: @escaping (UUID?) -> Void) {
            self.onSelect = onSelect
        }

        func attach(to view: ARView) {
            arView = view
            view.scene.addAnchor(sceneAnchor)
            sceneAnchor.addChild(modelRoot)
            sceneAnchor.addChild(camera)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
            view.addGestureRecognizer(tap)
            updateCamera()
        }

        func teardown(from view: ARView) {
            // Pause RealityKit's backing ARSession before dismantling the scene. Apple documents that
            // a paused ARSession stops coordinating frame updates with its ARView. This is important
            // when switching repeatedly between Plan / 3D / Scan on memory-constrained devices.
            view.session.pause()
            for child in Array(modelRoot.children) { child.removeFromParent() }
            modelRoot.removeFromParent()
            camera.removeFromParent()
            sceneAnchor.removeFromParent()
            view.scene.anchors.removeAll()
            view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }
            arView = nil
            lastSnapshot = nil
            lastComponents = []
            lastSelectedID = nil
            lastSelectedIDs = []
        }

        func rebuild(snapshot: DisplayGeometrySnapshot, components: [PlanOpsisComponent], selectedID: UUID?, selectedIDs: Set<UUID>) {
            guard snapshot != lastSnapshot || components != lastComponents || selectedID != lastSelectedID || selectedIDs != lastSelectedIDs else { return }
            let geometryChanged = snapshot != lastSnapshot || components != lastComponents
            lastSnapshot = snapshot
            lastComponents = components
            lastSelectedID = selectedID
            lastSelectedIDs = selectedIDs

            for child in Array(modelRoot.children) { child.removeFromParent() }

            for roomFloor in snapshot.roomFloors {
                let floor = roomFloor.bounds
                let width = max(0.01, Float(floor.width / 1000))
                let depth = max(0.01, Float(floor.depth / 1000))
                let mesh = MeshResource.generateBox(size: SIMD3<Float>(width, 0.02, depth))
                let entity = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: .systemGray5, isMetallic: false)])
                entity.name = "room-floor:\(roomFloor.roomID.uuidString)"
                entity.position = SIMD3<Float>(
                    Float(floor.center.x / 1000),
                    -0.01,
                    Float(-floor.center.y / 1000)
                )
                modelRoot.addChild(entity)
            }

            if geometryChanged, let floor = snapshot.floor {
                let width = max(0.01, Float(floor.width / 1000))
                let depth = max(0.01, Float(floor.depth / 1000))
                target = SIMD3<Float>(Float(floor.center.x / 1000), 1.0, Float(-floor.center.y / 1000))
                radius = max(2.0, max(width, depth) * 1.35)
            }

            for solid in snapshot.wallSolids where solid.length > 0 && solid.height > 0 && solid.thickness > 0 {
                let mesh = MeshResource.generateBox(size: SIMD3<Float>(
                    Float(solid.renderLength / 1000),
                    Float(solid.height / 1000),
                    Float(solid.thickness / 1000)
                ))
                let isSelected = solid.sourceWallIDs.contains(where: selectedIDs.contains)
                let material = SimpleMaterial(color: isSelected ? .systemOrange : .systemGray, isMetallic: false)
                let entity = ModelEntity(mesh: mesh, materials: [material])
                if let selectionID = solid.primarySelectionID { entity.name = "wall:\(selectionID.uuidString)" }
                entity.position = SIMD3<Float>(
                    Float(solid.renderCenter.x / 1000),
                    Float((solid.bottom + solid.height * 0.5) / 1000),
                    Float(-solid.renderCenter.y / 1000)
                )
                entity.orientation = simd_quatf(angle: Float(solid.renderAngleRadians), axis: SIMD3<Float>(0, 1, 0))
                entity.generateCollisionShapes(recursive: false)
                modelRoot.addChild(entity)
            }

            for opening in snapshot.hostedOpenings where opening.width > 0 {
                let isSelected = opening.sourceOpeningIDs.contains(where: selectedIDs.contains)
                let entity: ModelEntity
                if opening.kind == .window && opening.height > 0 {
                    let mesh = MeshResource.generateBox(size: SIMD3<Float>(
                        max(0.01, Float(opening.width / 1000)),
                        max(0.01, Float(opening.height / 1000)),
                        0.008
                    ))
                    let windowColor: UIColor = opening.cutsWall ? .systemTeal.withAlphaComponent(0.25) : .systemPink.withAlphaComponent(0.45)
                    let material = SimpleMaterial(
                        color: isSelected ? .systemOrange : windowColor,
                        isMetallic: false
                    )
                    entity = ModelEntity(mesh: mesh, materials: [material])
                    entity.position = SIMD3<Float>(
                        Float(opening.center.x / 1000),
                        Float((opening.sillHeight + opening.height * 0.5) / 1000),
                        Float(-opening.center.y / 1000)
                    )
                } else {
                    // Thin threshold marker keeps the void visually open while preserving tap selection.
                    let mesh = MeshResource.generateBox(size: SIMD3<Float>(
                        max(0.01, Float(opening.width / 1000)),
                        0.01,
                        max(0.01, Float(opening.thickness / 1000))
                    ))
                    let markerColor: UIColor = opening.cutsWall ? .systemBlue.withAlphaComponent(0.35) : .systemPink.withAlphaComponent(0.45)
                    let material = SimpleMaterial(
                        color: isSelected ? .systemOrange : markerColor,
                        isMetallic: false
                    )
                    entity = ModelEntity(mesh: mesh, materials: [material])
                    entity.position = SIMD3<Float>(
                        Float(opening.center.x / 1000),
                        Float(opening.sillHeight / 1000) + 0.005,
                        Float(-opening.center.y / 1000)
                    )
                }
                if let selectionID = opening.primarySelectionID { entity.name = "opening:\(selectionID.uuidString)" }
                entity.orientation = simd_quatf(angle: Float(opening.angleRadians), axis: SIMD3<Float>(0, 1, 0))
                entity.generateCollisionShapes(recursive: false)
                modelRoot.addChild(entity)
            }

            for component in components {
                let width = max(0.01, Float(component.width / 1000))
                let depth = max(0.01, Float(component.depth / 1000))
                let height = max(0.01, Float(component.height / 1000))
                let isSelected = selectedIDs.contains(component.id)
                let baseColor: UIColor
                switch component.kind {
                case .column: baseColor = .systemGray2
                case .beam: baseColor = .systemIndigo.withAlphaComponent(0.78)
                case .wc, .sink: baseColor = .systemCyan.withAlphaComponent(0.7)
                case .bed, .table, .chair, .sofa: baseColor = .systemBrown.withAlphaComponent(0.65)
                }
                let material = SimpleMaterial(color: isSelected ? .systemOrange : baseColor, isMetallic: false)

                if component.kind == .chair {
                    // v9.9.3: a chair is a small assembly rather than one solid
                    // box, matching the more legible 2D/DXF chair symbol.
                    let root = Entity()
                    root.name = "component:\(component.id.uuidString)"
                    root.position = SIMD3<Float>(
                        Float(component.position.x / 1000),
                        0,
                        Float(-component.position.y / 1000)
                    )
                    root.orientation = simd_quatf(angle: Float(component.rotationRadians), axis: SIMD3<Float>(0, 1, 0))

                    let seatThickness = max(0.025, min(0.055, height * 0.065))
                    let seatY = max(0.22, min(height * 0.53, 0.48))
                    let seat = ModelEntity(
                        mesh: .generateBox(size: SIMD3<Float>(width * 0.82, seatThickness, depth * 0.72)),
                        materials: [material]
                    )
                    seat.position = SIMD3<Float>(0, seatY, 0.015)
                    root.addChild(seat)

                    let backHeight = max(0.16, height - seatY)
                    let back = ModelEntity(
                        mesh: .generateBox(size: SIMD3<Float>(width * 0.84, backHeight * 0.72, max(0.025, depth * 0.075))),
                        materials: [material]
                    )
                    back.position = SIMD3<Float>(0, seatY + backHeight * 0.42, -depth * 0.39)
                    root.addChild(back)

                    let legThickness = max(0.025, min(width, depth) * 0.075)
                    let legHeight = max(0.12, seatY - seatThickness * 0.5)
                    for xSign: Float in [-1, 1] {
                        for zSign: Float in [-1, 1] {
                            let leg = ModelEntity(
                                mesh: .generateBox(size: SIMD3<Float>(legThickness, legHeight, legThickness)),
                                materials: [material]
                            )
                            leg.position = SIMD3<Float>(
                                xSign * width * 0.33,
                                legHeight * 0.5,
                                zSign * depth * 0.29
                            )
                            root.addChild(leg)
                        }
                    }
                    root.generateCollisionShapes(recursive: true)
                    modelRoot.addChild(root)
                } else {
                    let mesh = MeshResource.generateBox(size: SIMD3<Float>(width, height, depth))
                    let entity = ModelEntity(mesh: mesh, materials: [material])
                    entity.name = "component:\(component.id.uuidString)"
                    entity.position = SIMD3<Float>(
                        Float(component.position.x / 1000),
                        Float(component.baseElevationMM / 1000) + height * 0.5,
                        Float(-component.position.y / 1000)
                    )
                    entity.orientation = simd_quatf(angle: Float(component.rotationRadians), axis: SIMD3<Float>(0, 1, 0))
                    entity.generateCollisionShapes(recursive: false)
                    modelRoot.addChild(entity)
                }
            }

            updateCamera()
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: arView)
            gesture.setTranslation(.zero, in: arView)
            yaw -= Float(delta.x) * 0.006
            pitch = min(1.35, max(0.12, pitch - Float(delta.y) * 0.006))
            updateCamera()
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            radius = min(30, max(1.5, radius / Float(gesture.scale)))
            gesture.scale = 1
            updateCamera()
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = arView else { return }
            let location = gesture.location(in: view)
            guard let entity = view.entity(at: location) else {
                onSelect(nil)
                return
            }
            var current: Entity? = entity
            while let candidate = current {
                if candidate.name.hasPrefix("wall:"),
                   let id = UUID(uuidString: String(candidate.name.dropFirst(5))) {
                    onSelect(id)
                    return
                }
                if candidate.name.hasPrefix("opening:"),
                   let id = UUID(uuidString: String(candidate.name.dropFirst(8))) {
                    onSelect(id)
                    return
                }
                if candidate.name.hasPrefix("component:"),
                   let id = UUID(uuidString: String(candidate.name.dropFirst(10))) {
                    onSelect(id)
                    return
                }
                current = candidate.parent
            }
            onSelect(nil)
        }

        private func updateCamera() {
            let horizontal = radius * cos(pitch)
            let position = SIMD3<Float>(
                target.x + horizontal * cos(yaw),
                target.y + radius * sin(pitch),
                target.z + horizontal * sin(yaw)
            )
            camera.look(at: target, from: position, relativeTo: nil)
        }
    }
}
#endif
