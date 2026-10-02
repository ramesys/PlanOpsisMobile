import Foundation

/// A drawing open in the v12.3 viewer: the parsed document and its drawable scene.
public struct CADViewerDocument: Identifiable, Sendable {
    public enum Source: Hashable, Sendable {
        /// The current PlanOpsis project's drawing.
        case project
        /// A DXF opened for viewing only; it is never imported into the project.
        case file(name: String)
    }

    public let id: UUID
    public let source: Source
    public let document: CADDocument
    public let scene: CADScene

    public init(source: Source, document: CADDocument, id: UUID = UUID()) {
        self.id = id
        self.source = source
        self.document = document
        scene = CADScene(document: document)
    }

    public var title: String {
        switch source {
        case .project: return "Project drawing"
        case let .file(name): return name
        }
    }

    /// Reads a DXF file for viewing.
    public static func open(data: Data, fileName: String) throws -> CADViewerDocument {
        CADViewerDocument(source: .file(name: fileName), document: try CADDocumentReader().read(data: data))
    }

    /// The model-space entity a scene item was drawn from.
    public func entity(for item: CADSceneItem) -> CADEntity? {
        document.entities.indices.contains(item.entityIndex) ? document.entities[item.entityIndex] : nil
    }
}

extension CADDocument {
    /// The PlanOpsis drawing (`ProjectDerivation.drawing`) as a CAD document, with the drafting
    /// convention's layers, so the project and third-party drawings share one viewer.
    /// PlanOpsis object IDs are kept as `PLANOPSIS` extended data for inspection.
    public init(preview: DXFPreviewSnapshot) {
        var layers: [CADLayer] = []
        var seen = Set<String>()
        for layer in ArchitecturalDraftingConvention.Layer.allCases {
            seen.insert(layer.rawValue)
            let index = ArchitecturalDraftingConvention.dxfColorIndex(for: layer)
            layers.append(CADLayer(
                name: layer.rawValue,
                color: .aci(index),
                colorIndex: index,
                isOn: ArchitecturalDraftingConvention.isInitiallyVisible(layer),
                isPlotted: ArchitecturalDraftingConvention.isPlotLayer(layer),
                lineWeight: .hundredthsMM(ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(for: layer))
            ))
        }
        var entities: [CADEntity] = []
        for primitive in preview.primitives {
            if seen.insert(primitive.layer).inserted { layers.append(CADLayer(name: primitive.layer)) }
            let geometry: CADGeometry
            switch primitive.kind {
            case .line:
                guard primitive.points.count >= 2 else { continue }
                geometry = .line(primitive.points[0], primitive.points[1])
            case .polyline:
                guard primitive.points.count >= 2 else { continue }
                geometry = .polyline(CADPolyline(vertices: primitive.points.map { CADVertex($0) }, closed: primitive.closed))
            case .arc:
                guard let center = primitive.center, let radius = primitive.radius, let start = primitive.startAngleDegrees, let end = primitive.endAngleDegrees else { continue }
                geometry = .arc(center: center, radius: radius, startAngle: start * .pi / 180, endAngle: end * .pi / 180)
            case .text:
                guard let point = primitive.points.first, let text = primitive.text else { continue }
                geometry = .text(CADText(
                    position: point,
                    height: primitive.textHeight ?? 180,
                    rotation: (primitive.rotationDegrees ?? 0) * .pi / 180,
                    string: text,
                    horizontal: .center,
                    vertical: .middle
                ))
            }
            var xdata: [String: [String]] = [:]
            var values = primitive.objectIDs.map(\.uuidString)
            if let semantic = primitive.semanticType { values.insert(semantic, at: 0) }
            if let ifc = primitive.ifcClass { values.insert(ifc.rawValue, at: 0) }
            if !values.isEmpty { xdata[DXFExchangeEngine.applicationID] = values }
            entities.append(CADEntity(
                type: primitive.kind.rawValue.uppercased(),
                layer: primitive.layer,
                lineWeight: .hundredthsMM(ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(primitive.lineWeightMM)),
                geometry: geometry,
                xdata: xdata
            ))
        }
        self.init(version: nil, units: .millimetres, layers: layers, entities: entities)
    }
}

/// One row of the viewer's entity inspector.
public struct CADInspectionRow: Hashable, Sendable, Identifiable {
    public var title: String
    public var value: String
    public var id: String { title }

    public init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }
}

extension CADViewerDocument {
    /// Type, layer, block and measured properties of a picked item, formatted in the drawing's units.
    public func inspection(of item: CADSceneItem) -> [CADInspectionRow] {
        let units = document.units
        var rows: [CADInspectionRow] = []
        let entity = entity(for: item)
        rows.append(CADInspectionRow("Type", entity?.type ?? "Entity"))
        rows.append(CADInspectionRow("Layer", item.layer))
        if let block = item.blockName { rows.append(CADInspectionRow(block.hasPrefix("*D") ? "Dimension block" : "Block", block)) }
        if let arc = item.arc {
            rows.append(CADInspectionRow("Centre", "\(CADMeasurement.formatLength(arc.center.x, units: units)), \(CADMeasurement.formatLength(arc.center.y, units: units))"))
            rows.append(CADInspectionRow("Radius", CADMeasurement.formatLength(arc.radius, units: units)))
            if arc.isFullCircle {
                rows.append(CADInspectionRow("Diameter", CADMeasurement.formatLength(arc.radius * 2, units: units)))
                rows.append(CADInspectionRow("Area", CADMeasurement.formatArea(.pi * arc.radius * arc.radius, units: units)))
            } else {
                rows.append(CADInspectionRow("Arc length", CADMeasurement.formatLength(abs(arc.sweep) * arc.radius, units: units)))
                rows.append(CADInspectionRow("Angle", CADMeasurement.formatAngle(abs(arc.sweep) * 180 / .pi)))
            }
        } else {
            switch item.shape {
            case let .path(points, closed):
                if points.count == 2, !closed {
                    rows.append(CADInspectionRow("Length", CADMeasurement.formatLength(CADMeasurement.distance(points[0], points[1]), units: units)))
                    rows.append(CADInspectionRow("Angle", CADMeasurement.formatAngle(CADMeasurement.angleDegrees(points[0], points[1]))))
                    rows.append(CADInspectionRow("ΔX", CADMeasurement.formatLength(points[1].x - points[0].x, units: units)))
                    rows.append(CADInspectionRow("ΔY", CADMeasurement.formatLength(points[1].y - points[0].y, units: units)))
                } else {
                    rows.append(CADInspectionRow(closed ? "Perimeter" : "Length", CADMeasurement.formatLength(CADMeasurement.chainLength(points, closed: closed), units: units)))
                    if closed { rows.append(CADInspectionRow("Area", CADMeasurement.formatArea(CADMeasurement.area(points), units: units))) }
                }
            case let .fill(loops):
                let area = loops.map(CADMeasurement.area).max() ?? 0
                rows.append(CADInspectionRow("Area", CADMeasurement.formatArea(area, units: units)))
            case let .text(text):
                rows.append(CADInspectionRow("Text", text.string))
                rows.append(CADInspectionRow("Height", CADMeasurement.formatLength(text.height, units: units)))
            case let .point(p):
                rows.append(CADInspectionRow("Position", "\(CADMeasurement.formatLength(p.x, units: units)), \(CADMeasurement.formatLength(p.y, units: units))"))
            case .segments:
                break
            }
        }
        if let handle = entity?.handle { rows.append(CADInspectionRow("Handle", handle)) }
        if let values = entity?.xdata[DXFExchangeEngine.applicationID], !values.isEmpty {
            let ids = values.compactMap(UUID.init(uuidString:))
            if let kind = values.first(where: { UUID(uuidString: $0) == nil }) { rows.append(CADInspectionRow("PlanOpsis class", kind)) }
            if !ids.isEmpty { rows.append(CADInspectionRow("PlanOpsis object", ids.count == 1 ? String(ids[0].uuidString.prefix(8)) : "\(ids.count) objects")) }
        }
        return rows
    }
}
