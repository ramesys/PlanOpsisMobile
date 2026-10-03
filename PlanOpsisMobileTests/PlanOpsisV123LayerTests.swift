import XCTest
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

/// v12.3: DXF geometry is layered by IFC class.
final class PlanOpsisV123LayerTests: XCTestCase {
    typealias Layer = ArchitecturalDraftingConvention.Layer

    func testLayerNamesInBothNamingsResolveBack() {
        XCTAssertEqual(Layer.wall.dxfName(.ifcClass), "IfcWall")
        XCTAssertEqual(Layer.doorSwing.dxfName(.ifcClass), "IfcDoor")
        XCTAssertEqual(Layer.sanitary.dxfName(.ifcClass), "IfcSanitaryTerminal")
        XCTAssertEqual(Layer.wall.dxfName(.discipline), "A-WALL")
        for layer in Layer.allCases {
            XCTAssertEqual(Layer(dxfName: layer.dxfName(.discipline)), layer, "legacy names import exactly")
            XCTAssertNotNil(Layer(dxfName: layer.dxfName(.ifcClass)))
        }
        XCTAssertEqual(Layer(dxfName: "ifcwall"), .wall)
        XCTAssertEqual(Layer(dxfName: "IfcDoor"), .door)
        XCTAssertNil(Layer(dxfName: "Furniture"))
        // Every IFC class layer is named exactly as the IFC entity the IFC4 export writes.
        for ifc in ArchitecturalDraftingConvention.IFCClass.allCases {
            XCTAssertEqual(ArchitecturalDraftingConvention.layer(for: ifc).dxfName(.ifcClass), ifc.rawValue)
        }
    }

    func testCompatibleExportPutsEveryElementOnItsIFCClassLayer() throws {
        let project = GoldenExchangeTests.project()
        let export = DXFExchangeEngine().exportValidated(project: project, representation: .semanticObservations)
        XCTAssertTrue(export.canWrite, export.issues.map(\.message).joined(separator: "; "))
        let document = try CADDocumentReader().read(text: export.text)
        var classes = Set<String>()
        for entity in document.entities {
            guard let values = entity.xdata[DXFExchangeEngine.applicationID], values.first == "IFC", values.count > 1 else { continue }
            XCTAssertEqual(entity.layer, values[1], "\(entity.type) of \(values[1]) is on \(entity.layer)")
            classes.insert(values[1])
        }
        XCTAssertTrue(classes.isSuperset(of: ["IfcWall", "IfcDoor", "IfcWindow", "IfcFurnishingElement"]), "\(classes)")
        let layerNames = Set(document.layers.map(\.name))
        XCTAssertTrue(layerNames.isSuperset(of: ["IfcWall", "IfcDoor", "IfcWindow", "IfcSpace", "IfcAnnotation", "IfcAnnotation-Dimensions", "IfcWall-Axis"]))
        XCTAssertFalse(layerNames.contains { $0.hasPrefix("A-") || $0.hasPrefix("S-") || $0.hasPrefix("P-") })
        XCTAssertFalse(document.layer(named: "IfcWall-Axis").isOn, "technical layers stay off")
    }

    func testRhinoEditableBlocksKeepIFCLayersInsteadOfLayerZero() throws {
        let project = GoldenExchangeTests.project()
        let export = EditableDXFWriter().export(project: project, dimensions: SurveyDimensionBuilder().build(project: project), revisionID: UUID())
        XCTAssertTrue(export.canWrite, export.issues.joined(separator: "; "))
        let document = try CADDocumentReader().read(text: export.text)
        let symbolBlocks = document.blocks.filter { $0.key.hasPrefix("PO12_") }
        XCTAssertEqual(symbolBlocks.count, project.rooms.flatMap { $0.components.map(\.id) + $0.openings.map(\.id) }.count)
        for (name, block) in symbolBlocks {
            XCTAssertFalse(block.entities.isEmpty)
            let layers = Set(block.entities.map(\.layer))
            XCTAssertFalse(layers.contains("0"), "\(name) has geometry on layer 0")
            let insert = try XCTUnwrap(document.entities.first { if case let .insert(i) = $0.geometry { return i.blockName == name }; return false })
            XCTAssertEqual(layers, [insert.layer], "\(name): block content and INSERT share the IFC class layer")
            XCTAssertTrue(insert.layer.hasPrefix("Ifc"))
        }
        for (name, block) in document.blocks where name.hasPrefix("*D") {
            XCTAssertTrue(block.entities.allSatisfy { $0.layer == "IfcAnnotation-Dimensions" }, name)
        }
        XCTAssertTrue(document.entities.filter { $0.type == "DIMENSION" }.allSatisfy { $0.layer == "IfcAnnotation-Dimensions" })
        // The reviewed Rhino return still recognises the drawing.
        let drawing = EditableDXFReader().read(export.text)
        XCTAssertTrue(drawing.issues.isEmpty, drawing.issues.joined(separator: "; "))
        XCTAssertEqual(drawing.controls.filter { $0.kind == "wall" }.count, project.rooms.flatMap(\.walls).count)
    }

    func testDisciplineNamingAndLegacyFilesStillImport() throws {
        let project = GoldenExchangeTests.project()
        let legacy = DXFExchangeEngine(layerNaming: .discipline).export(project: project, representation: .semanticObservations)
        XCTAssertTrue(legacy.contains("A-WALL-CNTR"))
        let fromLegacy = try XCTUnwrap(DXFExchangeEngine().import(legacy).project)
        let fromIFC = try XCTUnwrap(DXFExchangeEngine().import(DXFExchangeEngine().export(project: project, representation: .semanticObservations)).project)
        XCTAssertEqual(fromLegacy.rooms.flatMap(\.walls).count, project.rooms.flatMap(\.walls).count)
        XCTAssertEqual(fromIFC.rooms.flatMap(\.walls).map(\.id).sorted { $0.uuidString < $1.uuidString },
                       fromLegacy.rooms.flatMap(\.walls).map(\.id).sorted { $0.uuidString < $1.uuidString })
        let editable = EditableDXFWriter().export(project: project, dimensions: SurveyDimensionBuilder().build(project: project), revisionID: UUID(), layerNaming: .discipline)
        XCTAssertTrue(EditableDXFReader().read(editable.text).issues.isEmpty)
        XCTAssertTrue(editable.text.contains("A-DIMS"))
    }

    func testProjectViewerUsesTheChosenNaming() {
        let preview = ProjectDerivation(project: GoldenExchangeTests.project()).drawing
        let ifc = CADDocument(preview: preview)
        XCTAssertTrue(ifc.entities.allSatisfy { !$0.layer.hasPrefix("A-") })
        XCTAssertTrue(ifc.layers.contains { $0.name == "IfcWall" })
        let discipline = CADDocument(preview: preview, layerNaming: .discipline)
        XCTAssertTrue(discipline.layers.contains { $0.name == "A-DOOR-SWNG" })
    }
}
