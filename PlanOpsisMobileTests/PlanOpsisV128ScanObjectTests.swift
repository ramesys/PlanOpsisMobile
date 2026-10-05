import XCTest
@testable import PlanOpsisCore

/// v12.8 objects RoomPlan recognises become interior objects in the plan, the DXF and the IFC.
final class PlanOpsisV128ScanObjectTests: XCTestCase {
    func assertEqual(_ a: Point2D, _ b: Point2D, accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testScannedObjectsBecomeComponentsInTheirRoom() throws {
        let project = RoomPlanAdapter().adapt(MockRoomCaptureProvider().snapshot()).project
        let components = project.rooms[0].components
        XCTAssertEqual(components.map(\.kind), [.bed, .storage, .television])
        XCTAssertTrue(components.allSatisfy { $0.sourceRoomPlanID != nil && $0.confidence == .high })

        let bed = components[0]
        assertEqual(bed.position, Point2D(x: 2_000, y: 2_000))
        XCTAssertEqual(bed.width, 1_600, accuracy: 1e-6)
        XCTAssertEqual(bed.depth, 2_000, accuracy: 1e-6)
        XCTAssertEqual(bed.height, 500, accuracy: 1e-6)
        XCTAssertNil(bed.elevationMM, "standing on the floor")
        // Its back (+y) is against the north wall, where the pillows are drawn.
        XCTAssertEqual(bed.normal.y, 1, accuracy: 1e-9)

        let wardrobe = components[1]
        assertEqual(wardrobe.position, Point2D(x: 3_700, y: 900))
        XCTAssertEqual(wardrobe.normal.x, 1, accuracy: 1e-9, "its back is against the east wall")

        let tv = components[2]
        XCTAssertEqual(tv.elevationMM ?? 0, 1_000, accuracy: 1e-6, "hung 1 m above the floor")
        XCTAssertEqual(tv.normal.x, -1, accuracy: 1e-9, "its back is against the west wall")
    }

    func testKitchenInTheSecondRoomAndUnknownCategories() throws {
        var snapshot = MockStructureCaptureProvider().snapshot()
        snapshot.rooms[1].objects.append(CapturedObjectSnapshot(sourceRoomPlanID: UUID(), category: "piano",
                                                                transform: .identity(translationX: 5, y: 0.5, z: -1), dimensions: Dimensions3D(x: 1.5, y: 1, z: 0.6), confidence: .high))
        snapshot.rooms[1].objects.append(CapturedObjectSnapshot(sourceRoomPlanID: UUID(), category: "chair",
                                                                transform: .identity(translationX: 5, y: 0.5, z: -1), dimensions: Dimensions3D(x: 0, y: 1, z: 0.6), confidence: .high))
        let result = RoomPlanAdapter().adapt(snapshot)
        XCTAssertEqual(result.project.rooms[1].components.map(\.kind), [.refrigerator, .stove, .sink])
        XCTAssertEqual(result.project.rooms[1].components.last?.confidence, .medium)
        XCTAssertTrue(result.diagnostics.contains { if case .unsupportedObject(_, "piano") = $0 { return true }; return false })
        XCTAssertTrue(result.diagnostics.contains { if case .invalidObjectGeometry = $0 { return true }; return false })
    }

    func testCapturesRetainedBeforeObjectsStillDecode() throws {
        let old = RoomCaptureSnapshot(sourceRoomPlanID: UUID(), surfaces: MockRoomCaptureProvider().snapshot().surfaces)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "objects")
        let decoded = try JSONDecoder().decode(RoomCaptureSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.objects.isEmpty)
        let snapshot = MockRoomCaptureProvider().snapshot()
        XCTAssertEqual(try JSONDecoder().decode(RoomCaptureSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testEveryRoomPlanCategoryHasAKindAndEveryKindASymbol() {
        let categories = ["storage", "refrigerator", "stove", "bed", "sink", "washerDryer", "toilet", "bathtub", "oven",
                          "dishwasher", "table", "sofa", "chair", "fireplace", "television", "stairs"]
        for category in categories { XCTAssertNotNil(PlanOpsisComponent.Kind(roomPlanCategory: category), category) }
        XCTAssertNil(PlanOpsisComponent.Kind(roomPlanCategory: "unknown"))
        for kind in PlanOpsisComponent.Kind.allCases {
            let symbol = ArchitecturalSymbolLibrary.component(PlanOpsisComponent(kind: kind, position: .zero, rotationRadians: 0.4))
            // A table is its outline; everything else has detail that tells it apart.
            XCTAssertGreaterThanOrEqual(symbol.primitives.count, kind == .table ? 1 : 2, "\(kind) has a recognisable symbol")
        }
    }

    func testObjectsReachTheDXFOnTheirLayersAndRoundTrip() throws {
        let project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        let engine = DXFExchangeEngine()
        let preview = engine.preview(for: project, representation: .semanticObservations)
        let layers = Set(preview.primitives.compactMap { $0.ifcClass == .appliance ? $0.layer : nil })
        XCTAssertEqual(layers, [ArchitecturalDraftingConvention.Layer.appliance.rawValue])
        XCTAssertTrue(preview.primitives.contains { $0.ifcClass == .furnishing })

        let dxf = engine.export(project: project, representation: .semanticObservations)
        XCTAssertTrue(dxf.contains("IfcElectricAppliance"))
        XCTAssertTrue(dxf.contains("IfcFurnishingElement"))
        let imported = try XCTUnwrap(engine.import(dxf).project)
        let kinds = imported.rooms.flatMap(\.components).map(\.kind)
        XCTAssertEqual(Set(kinds), [.bed, .storage, .television, .refrigerator, .stove, .sink])
    }

    func testObjectsReachTheIFCAsTheirClasses() {
        var project = RoomPlanAdapter().adapt(MockStructureCaptureProvider().snapshot()).project
        project.rooms[0].components.append(PlanOpsisComponent(kind: .stairs, position: Point2D(x: 500, y: 1_500)))
        project.rooms[0].components.append(PlanOpsisComponent(kind: .bathtub, position: Point2D(x: 1_000, y: 500)))
        let ifc = IFC4ExchangeEngine().export(project: project)
        XCTAssertTrue(ifc.contains("IFCELECTRICAPPLIANCE("))
        XCTAssertTrue(ifc.contains(".FRIDGE_FREEZER."))
        XCTAssertTrue(ifc.contains(".ELECTRICCOOKER."))
        XCTAssertTrue(ifc.contains("IFCAUDIOVISUALAPPLIANCE("))
        XCTAssertTrue(ifc.contains(".TV."))
        XCTAssertTrue(ifc.contains("IFCSTAIR("))
        XCTAssertTrue(ifc.contains(".BATH."))
        XCTAssertTrue(ifc.contains("'Storage'"))
        XCTAssertTrue(IFC4ExchangeEngine().exportValidated(project: project).canWrite)
    }
}
