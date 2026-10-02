import Foundation

public enum DXFPrimitiveKind: String, Codable, Hashable, Sendable {
    case line
    case polyline
    case arc
    case text
}

public struct DXFPrimitive: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: DXFPrimitiveKind
    public var layer: String
    public var points: [Point2D]
    public var closed: Bool
    public var center: Point2D?
    public var radius: Double?
    public var startAngleDegrees: Double?
    public var endAngleDegrees: Double?
    public var text: String?
    public var textHeight: Double?
    /// Optional text rotation in DXF degrees. Zero/nil is horizontal.
    public var rotationDegrees: Double?
    public var lineWeightMM: Double
    /// Optional semantic metadata written as PLANOPSIS XDATA on exported entities.
    public var ifcClass: ArchitecturalDraftingConvention.IFCClass?
    /// Optional PlanOpsis semantic subtype, e.g. door.singleHinged or furniture.bed.
    public var semanticType: String?
    public var objectIDs: [UUID]
    public var roomIDs: [UUID]
    public var hostIDs: [UUID]

    public init(
        id: String,
        kind: DXFPrimitiveKind,
        layer: String,
        points: [Point2D] = [],
        closed: Bool = false,
        center: Point2D? = nil,
        radius: Double? = nil,
        startAngleDegrees: Double? = nil,
        endAngleDegrees: Double? = nil,
        text: String? = nil,
        textHeight: Double? = nil,
        rotationDegrees: Double? = nil,
        lineWeightMM: Double = 0.18,
        ifcClass: ArchitecturalDraftingConvention.IFCClass? = nil,
        semanticType: String? = nil,
        objectIDs: [UUID] = [],
        roomIDs: [UUID] = [],
        hostIDs: [UUID] = []
    ) {
        self.id = id
        self.kind = kind
        self.layer = layer
        self.points = points
        self.closed = closed
        self.center = center
        self.radius = radius
        self.startAngleDegrees = startAngleDegrees
        self.endAngleDegrees = endAngleDegrees
        self.text = text
        self.textHeight = textHeight
        self.rotationDegrees = rotationDegrees
        self.lineWeightMM = lineWeightMM
        self.ifcClass = ifcClass
        self.semanticType = semanticType
        self.objectIDs = objectIDs
        self.roomIDs = roomIDs
        self.hostIDs = hostIDs
    }
}

public struct DXFPreviewSnapshot: Codable, Hashable, Sendable {
    public var primitives: [DXFPrimitive]
    public init(primitives: [DXFPrimitive]) { self.primitives = primitives }
    public static let empty = DXFPreviewSnapshot(primitives: [])
}

public struct DXFImportDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public enum Code: String, Codable, Hashable, Sendable {
        case noParametricWalls
        case unsupportedEntityIgnored
        case openingWithoutHost
        case invalidMetadata
    }
    public var code: Code
    public var message: String
    public var id: String { "dxf:\(code.rawValue):\(message)" }
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

public struct DXFImportResult: Sendable {
    public var project: PlanOpsisProject?
    public var preview: DXFPreviewSnapshot
    public var diagnostics: [DXFImportDiagnostic]
    public init(project: PlanOpsisProject?, preview: DXFPreviewSnapshot, diagnostics: [DXFImportDiagnostic]) {
        self.project = project
        self.preview = preview
        self.diagnostics = diagnostics
    }
}

public struct DXFExportIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, Hashable, Sendable { case warning, error }
    public var severity: Severity
    public var message: String
    public var id: String { "dxf-export:\(severity.rawValue):\(message)" }
    public init(_ severity: Severity, _ message: String) { self.severity = severity; self.message = message }
}

public struct DXFExportResult: Sendable {
    public var text: String
    public var issues: [DXFExportIssue]
    public var canWrite: Bool { !issues.contains { $0.severity == .error } }
    public init(text: String, issues: [DXFExportIssue]) { self.text = text; self.issues = issues }
}

public struct DXFExchangeEngine {
    public static let applicationID = "PLANOPSIS"

    public var includeOpeningDimensions: Bool

    public var surveyDrawing:Bool
    public init(includeOpeningDimensions:Bool=false,surveyDrawing:Bool=false) { self.includeOpeningDimensions=includeOpeningDimensions;self.surveyDrawing=surveyDrawing }

    // MARK: - Export

    /// - Parameters: semanticGeometry/physicalGeometry: geometry already generated from exactly this
    ///   `project` (v12.1 `ProjectDerivation`); generated here when nil.
    public func preview(
        for project: PlanOpsisProject,
        representation: GeometryRepresentationMode = .reconciledPhysical,
        semanticGeometry precomputedSemantic: ArchitecturalGeometrySnapshot? = nil,
        physicalGeometry precomputedPhysical: DisplayGeometrySnapshot? = nil
    ) -> DXFPreviewSnapshot {
        let semanticGeometry = precomputedSemantic ?? ParametricGeometryEngine().generate(from: project)
        let physicalGeometry = precomputedPhysical ?? PhysicalDisplayGeometryEngine().generate(from: project, semanticGeometry: semanticGeometry)
        var primitives: [DXFPrimitive] = []

        // v9.5 drafting rule:
        // - for a single closed room (the primary LiDAR -> DXF workflow), draft directly from the
        //   ordered semantic room boundary so wall faces, openings and dimensions share one source;
        // - for multi-room reconciled output, retain the physical consolidation engine for shared
        //   partitions but use room-boundary drafting for dimensions/spaces.
        var draftedRoomIDs = Set<UUID>()
        var draftedWallIDs = Set<UUID>()
        for (index, room) in project.rooms.enumerated() {
            let centerline = ArchitecturalRoomEnvelope.polygon(for: room, topology: semanticGeometry.topology)
            guard let draft = roomDraft(room: room, centerline: centerline) else { continue }

            draftedRoomIDs.insert(room.id)
            draftedWallIDs.formUnion(draft.edges.map { $0.wall.id })

            if representation == .semanticObservations || project.rooms.count == 1 {
                primitives.append(contentsOf: wallPrimitives(for: draft))
                primitives.append(contentsOf: openingPrimitives(for: draft))
            }

            primitives.append(contentsOf: dimensionPrimitives(for: draft))
            primitives.append(contentsOf: spaceAndRoomAnnotationPrimitives(for: draft, roomIndex: index))
        }

        // v9.6 semantic component library: independent objects remain visible in both Observed
        // and Reconciled representation modes and export on deterministic IFC-mapped layers.
        for room in project.rooms {
            for component in room.components {
                primitives.append(contentsOf: componentPrimitives(component, roomID: room.id))
            }
        }

        // Fallback for open/incomplete rooms, and for reconciled multi-room physical partitions.
        if representation == .reconciledPhysical && project.rooms.count > 1 {
            primitives.append(contentsOf: wallFacePrimitives(for: physicalGeometry.planWallSegments))
            for opening in physicalGeometry.hostedOpenings where opening.cutsWall {
                primitives.append(contentsOf: architecturalPrimitives(for: opening, roomFloors: semanticGeometry.roomFloors, project: project))
            }
        } else {
            let semanticDisplay = semanticGeometry.semanticDisplaySnapshot()
            let fallbackSegments = semanticDisplay.planWallSegments.filter { segment in
                !segment.sourceWallIDs.allSatisfy { draftedWallIDs.contains($0) }
            }
            primitives.append(contentsOf: wallFacePrimitives(for: fallbackSegments))
            for opening in semanticDisplay.hostedOpenings where
                !project.rooms.flatMap(\.openings).contains(where: { opening.sourceOpeningIDs.contains($0.id) && draftedWallIDs.contains($0.parameters.hostWallID) }) {
                primitives.append(contentsOf: architecturalPrimitives(for: opening, roomFloors: semanticGeometry.roomFloors, project: project))
            }
        }

        // Open/incomplete rooms still receive conservative dimensions from semantic walls.
        for room in project.rooms {
            let fallbackCenter = roomBoundsCenter(room)
            for wall in room.walls where !draftedWallIDs.contains(wall.id) {
                primitives.append(contentsOf: dimensionPrimitives(for: wall, roomCentroid: fallbackCenter))
            }
        }

        if includeOpeningDimensions { primitives.append(contentsOf: openingDimensions(for: project, semanticGeometry: semanticGeometry)) }
        let wallSegments = representation == .reconciledPhysical && project.rooms.count > 1
            ? physicalGeometry.planWallSegments : semanticGeometry.semanticDisplaySnapshot().planWallSegments
        primitives = ArchitecturalWallDrawing.resolve(primitives, segments: wallSegments, project: project)
        if surveyDrawing {
            primitives.removeAll{$0.layer==ArchitecturalDraftingConvention.Layer.dimensions.rawValue}
            let builder=SurveyDimensionBuilder()
            primitives += builder.planPrimitives(snapshot:builder.build(project:project),settings:project.survey.settings)
            primitives=primitives.compactMap { primitive in
                var p=primitive
                if p.layer==ArchitecturalDraftingConvention.Layer.roomAnnotation.rawValue {
                    guard project.survey.settings.showRoomNames else { return nil }
                    p.textHeight=project.survey.settings.modelTextHeightMM
                    let extraGap=max(0,project.survey.settings.modelTextHeightMM*0.9-120)
                    if !p.points.isEmpty { p.points[0].y += p.id.hasPrefix("room-name:") ? extraGap : -extraGap }
                    if let room=project.rooms.first(where:{p.id=="room-name:"+$0.id.uuidString}),let name=project.survey.roomNames[room.id],!name.isEmpty { p.text=name }
                }
                return p
            }
        }
        return DXFPreviewSnapshot(primitives: primitives)
    }

    /// Uses the same room scope as the plan canvas, so hidden labels cannot affect Fit.
    public func annotations(for project: PlanOpsisProject, focusedRoomID: UUID? = nil,
                            representation: GeometryRepresentationMode = .reconciledPhysical) -> [DXFPrimitive] {
        var scoped = project
        if let focusedRoomID { scoped.rooms = project.rooms.filter { $0.id == focusedRoomID } }
        return preview(for: scoped, representation: representation).primitives.filter {
            $0.layer == ArchitecturalDraftingConvention.Layer.dimensions.rawValue ||
            $0.layer == ArchitecturalDraftingConvention.Layer.roomAnnotation.rawValue
        }
    }

    /// Optional outer dimension chain for actual semantic opening widths.
    public func openingDimensions(for project: PlanOpsisProject, semanticGeometry: ArchitecturalGeometrySnapshot? = nil) -> [DXFPrimitive] {
        let geometry = semanticGeometry ?? ParametricGeometryEngine().generate(from: project)
        return project.rooms.flatMap { room in
            let boundary = ArchitecturalRoomEnvelope.polygon(for: room, topology: geometry.topology)
            return room.openings.flatMap { opening -> [DXFPrimitive] in
                guard let wall = room.walls.first(where: { $0.id == opening.parameters.hostWallID }) else { return [] }
                let p = opening.parameters
                let center = wall.start + wall.direction * p.offsetAlongWall
                let normal = Point2D(x: -wall.direction.y, y: wall.direction.x)
                let inward = ArchitecturalSymbolLibrary.inwardSign(center: center, angle: wall.angleRadians, boundary: boundary)
                return dimensionPrimitives(id: "opening:\(opening.id)", start: center-wall.direction*(p.width/2), end: center+wall.direction*(p.width/2),
                    thickness: wall.thickness, explicitOutwardNormal: normal * -inward, measuredLength: p.width, offsetBeyondFace: 800)
            }
        }
    }

    public func export(
        project: PlanOpsisProject,
        representation: GeometryRepresentationMode = .reconciledPhysical
    ) -> String {
        exportValidated(project: project, representation: representation).text
    }

    /// Writes a conservative AutoCAD 2000 ASCII DXF with complete core symbol tables,
    /// explicit handles/owners, CRLF line endings, and IFC-class metadata on architectural entities.
    /// The returned report blocks malformed/non-finite geometry before it reaches Files.app.
    public func exportValidated(
        project: PlanOpsisProject,
        representation: GeometryRepresentationMode = .reconciledPhysical
    ) -> DXFExportResult {
        let sourceErrors = ExchangeGeometryValidation.errors(in: project)
        guard sourceErrors.isEmpty else { return DXFExportResult(text: "", issues: sourceErrors.map { .init(.error, $0) }) }
        let cleaned = DXFDrawingValidator.clean(preview(for: project, representation: representation).primitives)
        let preview = DXFPreviewSnapshot(primitives: cleaned.primitives)
        var issues = cleaned.issues + exportIssues(project: project, preview: preview)
        guard !issues.contains(where: { $0.severity == .error }) else {
            return DXFExportResult(text: "", issues: issues)
        }

        var out: [String] = []
        func pair(_ code: Int, _ value: String) {
            out.append(String(code))
            out.append(sanitizeDXFValue(value))
        }
        func number(_ value: Double) -> String {
            // All non-finite values are rejected before serialization.
            if abs(value.rounded() - value) < 1e-9 { return String(Int(value.rounded())) }
            return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        }

        var nextHandleValue = 0x20
        func nextHandle() -> String {
            defer { nextHandleValue += 1 }
            return String(nextHandleValue, radix: 16).uppercased()
        }

        // Fixed ownership graph for a compact but well-formed R2000 DXF.
        let ltypeTableHandle = nextHandle()
        let layerTableHandle = nextHandle()
        let styleTableHandle = nextHandle()
        let appIDTableHandle = nextHandle()
        let blockRecordTableHandle = nextHandle()
        let modelSpaceRecordHandle = nextHandle()
        let paperSpaceRecordHandle = nextHandle()
        let modelSpaceBlockHandle = nextHandle()
        let modelSpaceEndBlockHandle = nextHandle()
        let paperSpaceBlockHandle = nextHandle()
        let paperSpaceEndBlockHandle = nextHandle()

        let bounds = dxfBounds(preview: preview, project: project)

        // MARK: HEADER
        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$ACADVER"); pair(1, "AC1015")
        pair(9, "$DWGCODEPAGE"); pair(3, "ANSI_1252")
        pair(9, "$HANDSEED"); pair(5, "FFFF")
        pair(9, "$INSUNITS"); pair(70, "4") // millimetres
        pair(9, "$MEASUREMENT"); pair(70, "1")
        pair(9, "$LUNITS"); pair(70, "2") // decimal
        pair(9, "$LUPREC"); pair(70, "0") // whole-mm display default
        pair(9, "$TEXTSTYLE"); pair(7, ArchitecturalDraftingConvention.TextStyle.name)
        pair(9, "$CLAYER"); pair(8, ArchitecturalDraftingConvention.Layer.wall.rawValue)
        pair(9, "$EXTMIN"); pair(10, number(bounds.min.x)); pair(20, number(bounds.min.y)); pair(30, "0")
        pair(9, "$EXTMAX"); pair(10, number(bounds.max.x)); pair(20, number(bounds.max.y)); pair(30, "0")
        pair(0, "ENDSEC")

        // MARK: TABLES
        pair(0, "SECTION"); pair(2, "TABLES")

        // Continuous linetype is explicitly declared because all exported layers reference it.
        pair(0, "TABLE"); pair(2, "LTYPE"); pair(5, ltypeTableHandle); pair(330, "0"); pair(100, "AcDbSymbolTable"); pair(70, "1")
        pair(0, "LTYPE"); pair(5, nextHandle()); pair(330, ltypeTableHandle); pair(100, "AcDbSymbolTableRecord"); pair(100, "AcDbLinetypeTableRecord")
        pair(2, "CONTINUOUS"); pair(70, "0"); pair(3, "Solid line"); pair(72, "65"); pair(73, "0"); pair(40, "0")
        pair(0, "ENDTAB")

        // Layer 0 plus PlanOpsis architectural/drawing layers.
        let allLayers = ArchitecturalDraftingConvention.Layer.allCases
        pair(0, "TABLE"); pair(2, "LAYER"); pair(5, layerTableHandle); pair(330, "0"); pair(100, "AcDbSymbolTable"); pair(70, String(allLayers.count + 1))
        appendLayerRecord(name: "0", color: 7, lineWeight: -3, plot: true, visible: true, owner: layerTableHandle, handle: nextHandle(), pair: pair)
        for layer in allLayers {
            appendLayerRecord(
                name: layer.rawValue,
                color: ArchitecturalDraftingConvention.dxfColorIndex(for: layer),
                lineWeight: ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(for: layer),
                plot: ArchitecturalDraftingConvention.isPlotLayer(layer),
                visible: ArchitecturalDraftingConvention.isInitiallyVisible(layer),
                owner: layerTableHandle,
                handle: nextHandle(),
                pair: pair
            )
        }
        pair(0, "ENDTAB")

        pair(0, "TABLE"); pair(2, "STYLE"); pair(5, styleTableHandle); pair(330, "0"); pair(100, "AcDbSymbolTable"); pair(70, "1")
        pair(0, "STYLE"); pair(5, nextHandle()); pair(330, styleTableHandle); pair(100, "AcDbSymbolTableRecord"); pair(100, "AcDbTextStyleTableRecord")
        pair(2, ArchitecturalDraftingConvention.TextStyle.name); pair(70, "0"); pair(40, "0"); pair(41, "1"); pair(50, "0"); pair(71, "0"); pair(42, "2.5"); pair(3, ArchitecturalDraftingConvention.TextStyle.font); pair(4, "")
        pair(0, "ENDTAB")

        pair(0, "TABLE"); pair(2, "APPID"); pair(5, appIDTableHandle); pair(330, "0"); pair(100, "AcDbSymbolTable"); pair(70, "2")
        for appID in ["ACAD", Self.applicationID] {
            pair(0, "APPID"); pair(5, nextHandle()); pair(330, appIDTableHandle); pair(100, "AcDbSymbolTableRecord"); pair(100, "AcDbRegAppTableRecord"); pair(2, appID); pair(70, "0")
        }
        pair(0, "ENDTAB")

        pair(0, "TABLE"); pair(2, "BLOCK_RECORD"); pair(5, blockRecordTableHandle); pair(330, "0"); pair(100, "AcDbSymbolTable"); pair(70, "2")
        pair(0, "BLOCK_RECORD"); pair(5, modelSpaceRecordHandle); pair(330, blockRecordTableHandle); pair(100, "AcDbSymbolTableRecord"); pair(100, "AcDbBlockTableRecord"); pair(2, "*Model_Space")
        pair(0, "BLOCK_RECORD"); pair(5, paperSpaceRecordHandle); pair(330, blockRecordTableHandle); pair(100, "AcDbSymbolTableRecord"); pair(100, "AcDbBlockTableRecord"); pair(2, "*Paper_Space")
        pair(0, "ENDTAB")
        pair(0, "ENDSEC")

        // MARK: BLOCKS
        pair(0, "SECTION"); pair(2, "BLOCKS")
        appendBlock(name: "*Model_Space", handle: modelSpaceBlockHandle, endHandle: modelSpaceEndBlockHandle, owner: modelSpaceRecordHandle, pair: pair)
        appendBlock(name: "*Paper_Space", handle: paperSpaceBlockHandle, endHandle: paperSpaceEndBlockHandle, owner: paperSpaceRecordHandle, pair: pair)
        pair(0, "ENDSEC")

        // MARK: ENTITIES
        pair(0, "SECTION"); pair(2, "ENTITIES")

        // Hidden semantic axes retain exact room-local identity for deterministic PlanOpsis round-trip.
        for room in project.rooms {
            for wall in room.walls {
                appendPolylineEntity(
                    points: [wall.start, wall.end],
                    closed: false,
                    constantWidth: wall.thickness,
                    layer: ArchitecturalDraftingConvention.Layer.wallCenter.rawValue,
                    lineWeight: ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(for: .wallCenter),
                    handle: nextHandle(),
                    owner: modelSpaceRecordHandle,
                    pair: pair,
                    number: number
                )
                pair(1001, Self.applicationID); pair(1000, "WALL"); pair(1000, room.id.uuidString); pair(1000, wall.id.uuidString)
                pair(1040, number(wall.height)); pair(1040, number(wall.thickness))
            }
        }

        for primitive in preview.primitives {
            append(primitive: primitive, handle: nextHandle(), owner: modelSpaceRecordHandle, pair: pair, number: number)
        }

        // Opening semantic records are stored on a non-plot technical layer for exact reconstruction.
        // Their visible geometry is already emitted on the correct architectural IFC-mapped layer.
        for room in project.rooms {
            for opening in room.openings {
                guard let wall = room.walls.first(where: { $0.id == opening.parameters.hostWallID }) else { continue }
                let p = opening.parameters
                let center = wall.start + wall.direction * p.offsetAlongWall
                let a = center - wall.direction * (p.width * 0.5)
                let b = center + wall.direction * (p.width * 0.5)
                appendLineEntity(
                    a: a,
                    b: b,
                    layer: ArchitecturalDraftingConvention.Layer.metadata.rawValue,
                    lineWeight: ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(for: .metadata),
                    handle: nextHandle(),
                    owner: modelSpaceRecordHandle,
                    pair: pair,
                    number: number
                )
                pair(1001, Self.applicationID); pair(1000, opening.kind.rawValue.uppercased()); pair(1000, room.id.uuidString); pair(1000, opening.id.uuidString); pair(1000, wall.id.uuidString)
                pair(1040, number(p.offsetAlongWall)); pair(1040, number(p.width)); pair(1040, number(p.height)); pair(1040, number(p.sillHeight))
                if opening.kind == .door {
                    pair(1070, String(swingCode(opening.doorSwing ?? .unspecified)))
                    pair(1000, "DOOROP:\((opening.doorOperation ?? .singleHinged).rawValue)")
                }
                if opening.kind == .window {
                    pair(1000, "WINDOWOP:\((opening.windowOperation ?? .fixed).rawValue)")
                }
            }

            // v9.6 semantic components: exact identity/parameters remain on the hidden metadata
            // layer while visible graphics live on IFC-mapped layers.
            for component in room.components {
                appendLineEntity(
                    a: component.position,
                    b: component.position + component.direction * max(1, component.width * 0.5),
                    layer: ArchitecturalDraftingConvention.Layer.metadata.rawValue,
                    lineWeight: ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(for: .metadata),
                    handle: nextHandle(),
                    owner: modelSpaceRecordHandle,
                    pair: pair,
                    number: number
                )
                pair(1001, Self.applicationID); pair(1000, "COMPONENT"); pair(1000, room.id.uuidString); pair(1000, component.id.uuidString); pair(1000, component.kind.rawValue)
                pair(1040, number(component.position.x)); pair(1040, number(component.position.y)); pair(1040, number(component.width)); pair(1040, number(component.depth)); pair(1040, number(component.height)); pair(1040, number(component.rotationRadians))
                if let elevation = component.elevationMM { pair(1040, number(elevation)) }
            }
        }

        pair(0, "ENDSEC")
        pair(0, "EOF")

        // CRLF maximizes compatibility with conservative/legacy ASCII DXF readers.
        let text = out.joined(separator: "\r\n") + "\r\n"
        issues.append(contentsOf: validateExportedDXF(text, declaredLayers: Set(allLayers.map(\.rawValue) + ["0"])))
        return DXFExportResult(text: issues.contains(where: { $0.severity == .error }) ? "" : text, issues: issues)
    }

    // MARK: - Import

    public func `import`(_ text: String) -> DXFImportResult {
        let records = parseRecords(text)
        let preview = DXFPreviewSnapshot(primitives: records.compactMap(primitive(from:)))
        var diagnostics: [DXFImportDiagnostic] = []

        struct WallRecord {
            var roomID: UUID
            var wall: PlanOpsisWall
        }
        struct OpeningRecord {
            var roomID: UUID
            var openingID: UUID
            var hostWallID: UUID
            var kind: PlanOpsisOpening.Kind
            var offset: Double
            var width: Double
            var height: Double
            var sill: Double
            var swing: PlanOpsisDoor.Swing
            var doorOperation: PlanOpsisDoor.Operation
            var windowOperation: PlanOpsisWindow.Operation
        }
        struct ComponentRecord {
            var roomID: UUID
            var component: PlanOpsisComponent
        }

        var wallRecords: [WallRecord] = []
        var openingRecords: [OpeningRecord] = []
        var componentRecords: [ComponentRecord] = []

        for record in records {
            guard record.appID == Self.applicationID else { continue }
            guard let type = record.strings.first else { continue }
            if type == "WALL" {
                guard record.points.count >= 2,
                      record.strings.count >= 3,
                      let roomID = UUID(uuidString: record.strings[1]),
                      let wallID = UUID(uuidString: record.strings[2]) else {
                    diagnostics.append(.init(.invalidMetadata, "Invalid PLANOPSIS wall metadata was ignored.")); continue
                }
                let a = record.points[0], b = record.points[1], v = b - a
                let height = record.doubles.first ?? ArchitecturalDraftingConvention.Defaults().wallHeight
                let thickness = record.doubles.dropFirst().first ?? record.constantWidth ?? ArchitecturalDraftingConvention.Defaults().wallThickness
                wallRecords.append(.init(roomID: roomID, wall: PlanOpsisWall(id: wallID, start: a, length: v.length, angleRadians: atan2(v.y, v.x), height: height, thickness: thickness, confidence: .unknown)))
            } else if ["DOOR", "WINDOW", "OPENING"].contains(type) {
                guard record.strings.count >= 4,
                      let roomID = UUID(uuidString: record.strings[1]),
                      let openingID = UUID(uuidString: record.strings[2]),
                      let hostWallID = UUID(uuidString: record.strings[3]) else {
                    diagnostics.append(.init(.invalidMetadata, "Invalid PLANOPSIS opening metadata was ignored.")); continue
                }
                let values = record.doubles
                guard values.count >= 4 else { diagnostics.append(.init(.invalidMetadata, "Incomplete opening dimensions were ignored.")); continue }
                let kind: PlanOpsisOpening.Kind = type == "DOOR" ? .door : (type == "WINDOW" ? .window : .opening)
                let doorOperation = record.strings.compactMap { value -> PlanOpsisDoor.Operation? in
                    guard value.hasPrefix("DOOROP:") else { return nil }
                    return PlanOpsisDoor.Operation(rawValue: String(value.dropFirst(7)))
                }.first ?? .singleHinged
                let windowOperation = record.strings.compactMap { value -> PlanOpsisWindow.Operation? in
                    guard value.hasPrefix("WINDOWOP:") else { return nil }
                    return PlanOpsisWindow.Operation(rawValue: String(value.dropFirst(9)))
                }.first ?? .fixed
                openingRecords.append(.init(roomID: roomID, openingID: openingID, hostWallID: hostWallID, kind: kind, offset: values[0], width: values[1], height: values[2], sill: values[3], swing: swing(from: record.integers.first ?? 0), doorOperation: doorOperation, windowOperation: windowOperation))
            } else if type == "COMPONENT" {
                guard record.strings.count >= 4,
                      let roomID = UUID(uuidString: record.strings[1]),
                      let componentID = UUID(uuidString: record.strings[2]),
                      let kind = PlanOpsisComponent.Kind(rawValue: record.strings[3]),
                      record.doubles.count >= 6 else {
                    diagnostics.append(.init(.invalidMetadata, "Invalid PLANOPSIS component metadata was ignored.")); continue
                }
                let values = record.doubles
                componentRecords.append(.init(roomID: roomID, component: PlanOpsisComponent(
                    id: componentID,
                    kind: kind,
                    position: Point2D(x: values[0], y: values[1]),
                    width: values[2],
                    depth: values[3],
                    height: values[4],
                    elevationMM: values.count >= 7 ? values[6] : nil,
                    rotationRadians: values[5]
                )))
            }
        }

        // Conservative generic import: accept explicit architectural wall-center layers only.
        if wallRecords.isEmpty {
            let generic = records.filter { $0.layer.uppercased() == ArchitecturalDraftingConvention.Layer.wallCenter.rawValue && $0.points.count >= 2 }
            if !generic.isEmpty {
                let roomID = UUID()
                for record in generic {
                    let a = record.points[0], b = record.points[1], v = b - a
                    wallRecords.append(.init(roomID: roomID, wall: PlanOpsisWall(start: a, length: v.length, angleRadians: atan2(v.y, v.x), height: ArchitecturalDraftingConvention.Defaults().wallHeight, thickness: record.constantWidth ?? ArchitecturalDraftingConvention.Defaults().wallThickness, confidence: .unknown)))
                }
            }
        }

        guard !wallRecords.isEmpty || !componentRecords.isEmpty else {
            diagnostics.append(.init(.noParametricWalls, "No PLANOPSIS metadata or A-WALL-CNTR parametric wall axes were found. DXF is viewable but was not converted into guessed architecture."))
            return DXFImportResult(project: nil, preview: preview, diagnostics: diagnostics)
        }

        var roomsByID: [UUID: PlanOpsisRoom] = [:]
        for record in wallRecords {
            var room = roomsByID[record.roomID] ?? PlanOpsisRoom(id: record.roomID)
            room.walls.append(record.wall)
            roomsByID[record.roomID] = room
        }
        for record in openingRecords {
            guard var room = roomsByID[record.roomID], room.walls.contains(where: { $0.id == record.hostWallID }) else {
                diagnostics.append(.init(.openingWithoutHost, "DXF opening \(record.openingID) had no imported host wall.")); continue
            }
            let p = HostedOpeningParameters(id: record.openingID, hostWallID: record.hostWallID, offsetAlongWall: record.offset, width: record.width, height: record.height, sillHeight: record.sill, confidence: .unknown)
            let opening: PlanOpsisOpening
            switch record.kind {
            case .door: opening = .door(PlanOpsisDoor(parameters: p, swing: record.swing, operation: record.doorOperation))
            case .window: opening = .window(PlanOpsisWindow(parameters: p, operation: record.windowOperation))
            case .opening: opening = .opening(p)
            }
            room.openings.append(opening)
            roomsByID[record.roomID] = room
        }

        for record in componentRecords {
            var room = roomsByID[record.roomID] ?? PlanOpsisRoom(id: record.roomID)
            room.components.append(record.component)
            roomsByID[record.roomID] = room
        }

        let rooms = roomsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return DXFImportResult(project: PlanOpsisProject(rooms: rooms), preview: preview, diagnostics: diagnostics)
    }

    // MARK: - Internal DXF representation

    private struct Record {
        var type: String
        var layer: String = "0"
        var points: [Point2D] = []
        var closed: Bool = false
        var constantWidth: Double?
        var center: Point2D?
        var radius: Double?
        var startAngle: Double?
        var endAngle: Double?
        var text: String?
        var textHeight: Double?
        var textRotation: Double?
        var appID: String?
        var strings: [String] = []
        var doubles: [Double] = []
        var integers: [Int] = []
    }

    private func parseRecords(_ text: String) -> [Record] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var pairs: [(Int, String)] = []
        var index = 0
        while index + 1 < lines.count {
            if let code = Int(lines[index].trimmingCharacters(in: .whitespacesAndNewlines)) {
                pairs.append((code, lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            index += 2
        }

        var records: [Record] = []
        var current: Record?
        var currentX: Double?
        var inEntities = false
        var i = 0
        while i < pairs.count {
            let (code, value) = pairs[i]
            if code == 0 {
                if value == "SECTION", i + 1 < pairs.count, pairs[i + 1].0 == 2 {
                    inEntities = pairs[i + 1].1 == "ENTITIES"
                    i += 2; continue
                }
                if value == "ENDSEC" { if let c = current { records.append(c); current = nil }; inEntities = false; i += 1; continue }
                if inEntities {
                    if let c = current { records.append(c) }
                    if ["LINE", "LWPOLYLINE", "ARC", "TEXT"].contains(value) { current = Record(type: value) }
                    else { current = nil }
                    currentX = nil
                }
                i += 1; continue
            }
            guard inEntities, var c = current else { i += 1; continue }
            switch code {
            case 8: c.layer = value
            case 10:
                currentX = Double(value)
            case 20:
                if let x = currentX, let y = Double(value) { c.points.append(Point2D(x: x, y: y)); currentX = nil }
            case 11:
                if let x = Double(value), i + 1 < pairs.count, pairs[i + 1].0 == 21, let y = Double(pairs[i + 1].1) {
                    c.points.append(Point2D(x: x, y: y)); i += 1
                }
            case 70: c.closed = (Int(value) ?? 0) & 1 == 1
            case 43: c.constantWidth = Double(value)
            case 40:
                if c.type == "TEXT" { c.textHeight = Double(value) }
                else if c.type == "ARC" { c.radius = Double(value) }
            case 50:
                if c.type == "ARC" { c.startAngle = Double(value) }
                else if c.type == "TEXT" { c.textRotation = Double(value) }
            case 51: if c.type == "ARC" { c.endAngle = Double(value) }
            case 1: if c.type == "TEXT" { c.text = DXFTextCodec.decode(value) }
            case 1001: c.appID = value
            case 1000: c.strings.append(value)
            case 1040: if let d = Double(value) { c.doubles.append(d) }
            case 1070: if let n = Int(value) { c.integers.append(n) }
            default: break
            }
            // ARC center uses 10/20 too; map after collection.
            current = c
            i += 1
        }
        if let c = current { records.append(c) }

        // Normalize ARC/TEXT first point to center/insertion point.
        return records.map { r in
            var r = r
            if r.type == "ARC" {
                r.center = r.points.first
                r.points = []
            }
            return r
        }
    }

    private func primitive(from record: Record) -> DXFPrimitive? {
        if record.layer == ArchitecturalDraftingConvention.Layer.wallCenter.rawValue ||
            record.layer == ArchitecturalDraftingConvention.Layer.metadata.rawValue { return nil }
        let layerEnum = ArchitecturalDraftingConvention.Layer(rawValue: record.layer)
        let weight = layerEnum.map(ArchitecturalDraftingConvention.lineWeightMM) ?? 0.18
        switch record.type {
        case "LINE":
            guard record.points.count >= 2 else { return nil }
            return DXFPrimitive(id: UUID().uuidString, kind: .line, layer: record.layer, points: Array(record.points.prefix(2)), lineWeightMM: weight)
        case "LWPOLYLINE":
            return DXFPrimitive(id: UUID().uuidString, kind: .polyline, layer: record.layer, points: record.points, closed: record.closed, lineWeightMM: weight)
        case "ARC":
            guard let center = record.center, let radius = record.radius, let a = record.startAngle, let b = record.endAngle else { return nil }
            return DXFPrimitive(id: UUID().uuidString, kind: .arc, layer: record.layer, center: center, radius: radius, startAngleDegrees: a, endAngleDegrees: b, lineWeightMM: weight)
        case "TEXT":
            guard let point = record.points.first, let text = record.text else { return nil }
            return DXFPrimitive(id: UUID().uuidString, kind: .text, layer: record.layer, points: [point], text: text, textHeight: record.textHeight ?? 180, rotationDegrees: record.textRotation ?? 0, lineWeightMM: weight)
        default: return nil
        }
    }

    private func appendLayerRecord(
        name: String,
        color: Int,
        lineWeight: Int,
        plot: Bool,
        visible: Bool,
        owner: String,
        handle: String,
        pair: (Int, String) -> Void
    ) {
        pair(0, "LAYER"); pair(5, handle); pair(330, owner)
        pair(100, "AcDbSymbolTableRecord"); pair(100, "AcDbLayerTableRecord")
        pair(2, name); pair(70, "0")
        pair(62, String(visible ? abs(color) : -abs(color)))
        pair(6, "CONTINUOUS")
        pair(290, plot ? "1" : "0")
        pair(370, String(lineWeight))
    }

    private func appendBlock(
        name: String,
        handle: String,
        endHandle: String,
        owner: String,
        pair: (Int, String) -> Void
    ) {
        pair(0, "BLOCK"); pair(5, handle); pair(330, owner); pair(100, "AcDbEntity"); pair(8, "0"); pair(100, "AcDbBlockBegin")
        pair(2, name); pair(70, "0"); pair(10, "0"); pair(20, "0"); pair(30, "0"); pair(3, name); pair(1, "")
        pair(0, "ENDBLK"); pair(5, endHandle); pair(330, owner); pair(100, "AcDbEntity"); pair(8, "0"); pair(100, "AcDbBlockEnd")
    }

    private func appendLineEntity(
        a: Point2D,
        b: Point2D,
        layer: String,
        lineWeight: Int,
        handle: String,
        owner: String,
        pair: (Int, String) -> Void,
        number: (Double) -> String
    ) {
        pair(0, "LINE"); pair(5, handle); pair(330, owner); pair(100, "AcDbEntity"); pair(8, layer); pair(370, String(lineWeight)); pair(100, "AcDbLine")
        pair(10, number(a.x)); pair(20, number(a.y)); pair(30, "0")
        pair(11, number(b.x)); pair(21, number(b.y)); pair(31, "0")
    }

    private func appendPolylineEntity(
        points: [Point2D],
        closed: Bool,
        constantWidth: Double? = nil,
        layer: String,
        lineWeight: Int,
        handle: String,
        owner: String,
        pair: (Int, String) -> Void,
        number: (Double) -> String
    ) {
        guard !points.isEmpty else { return }
        pair(0, "LWPOLYLINE"); pair(5, handle); pair(330, owner); pair(100, "AcDbEntity"); pair(8, layer); pair(370, String(lineWeight)); pair(100, "AcDbPolyline")
        pair(90, String(points.count)); pair(70, closed ? "1" : "0")
        if let constantWidth { pair(43, number(constantWidth)) }
        for point in points { pair(10, number(point.x)); pair(20, number(point.y)) }
    }

    private func appendArcEntity(
        center: Point2D,
        radius: Double,
        startAngle: Double,
        endAngle: Double,
        layer: String,
        lineWeight: Int,
        handle: String,
        owner: String,
        pair: (Int, String) -> Void,
        number: (Double) -> String
    ) {
        pair(0, "ARC"); pair(5, handle); pair(330, owner); pair(100, "AcDbEntity"); pair(8, layer); pair(370, String(lineWeight)); pair(100, "AcDbCircle")
        pair(10, number(center.x)); pair(20, number(center.y)); pair(30, "0"); pair(40, number(radius)); pair(100, "AcDbArc"); pair(50, number(startAngle)); pair(51, number(endAngle))
    }

    private func appendTextEntity(
        point: Point2D,
        text: String,
        height: Double,
        rotationDegrees: Double,
        layer: String,
        lineWeight: Int,
        handle: String,
        owner: String,
        pair: (Int, String) -> Void,
        number: (Double) -> String
    ) {
        // AutoCAD R2000 TEXT alignment has two AcDbText subclass records. The alignment point
        // (11/21/31) belongs to the first subclass, while vertical justification (73) belongs to
        // the second. v9.4 placed 11/21 after the second subclass marker; some CAD readers then
        // ignored the alignment point and stacked centered labels at an unintended insertion point.
        pair(0, "TEXT"); pair(5, handle); pair(330, owner); pair(100, "AcDbEntity"); pair(8, layer); pair(370, String(lineWeight)); pair(100, "AcDbText")
        pair(10, number(point.x)); pair(20, number(point.y)); pair(30, "0")
        pair(40, number(height)); pair(1, text); pair(50, number(rotationDegrees)); pair(7, ArchitecturalDraftingConvention.TextStyle.name); pair(72, "1")
        pair(11, number(point.x)); pair(21, number(point.y)); pair(31, "0")
        pair(100, "AcDbText"); pair(73, "2")
    }

    private func appendPrimitiveMetadata(_ primitive: DXFPrimitive, pair: (Int, String) -> Void) {
        guard let ifcClass = primitive.ifcClass else { return }
        pair(1001, Self.applicationID)
        pair(1000, "IFC")
        pair(1000, ifcClass.rawValue)
        if let semanticType = primitive.semanticType { pair(1000, "TYPE:\(semanticType)") }
        for id in primitive.objectIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            pair(1000, "OBJECT:\(id.uuidString)")
            pair(1000, "IFC_GUID:\(PlanOpsisExchangeIdentity.ifcGlobalID(for: id))")
        }
        for id in primitive.roomIDs.sorted(by: { $0.uuidString < $1.uuidString }) { pair(1000, "ROOM:\(id.uuidString)") }
        for id in primitive.hostIDs.sorted(by: { $0.uuidString < $1.uuidString }) { pair(1000, "HOST:\(id.uuidString)") }
    }

    private func append(
        primitive: DXFPrimitive,
        handle: String,
        owner: String,
        pair: (Int, String) -> Void,
        number: (Double) -> String
    ) {
        let lineWeight = ArchitecturalDraftingConvention.dxfLineWeightHundredthsMM(primitive.lineWeightMM)
        switch primitive.kind {
        case .line:
            guard primitive.points.count >= 2 else { return }
            appendLineEntity(a: primitive.points[0], b: primitive.points[1], layer: primitive.layer, lineWeight: lineWeight, handle: handle, owner: owner, pair: pair, number: number)
        case .polyline:
            guard !primitive.points.isEmpty else { return }
            appendPolylineEntity(points: primitive.points, closed: primitive.closed, layer: primitive.layer, lineWeight: lineWeight, handle: handle, owner: owner, pair: pair, number: number)
        case .arc:
            guard let c = primitive.center, let r = primitive.radius, let a = primitive.startAngleDegrees, let b = primitive.endAngleDegrees else { return }
            appendArcEntity(center: c, radius: r, startAngle: a, endAngle: b, layer: primitive.layer, lineWeight: lineWeight, handle: handle, owner: owner, pair: pair, number: number)
        case .text:
            guard let p = primitive.points.first, let text = primitive.text else { return }
            appendTextEntity(point: p, text: text, height: primitive.textHeight ?? 180, rotationDegrees: primitive.rotationDegrees ?? 0, layer: primitive.layer, lineWeight: lineWeight, handle: handle, owner: owner, pair: pair, number: number)
        }
        appendPrimitiveMetadata(primitive, pair: pair)
    }

    private func exportIssues(project: PlanOpsisProject, preview: DXFPreviewSnapshot) -> [DXFExportIssue] {
        var issues: [DXFExportIssue] = []
        func finite(_ value: Double) -> Bool { value.isFinite }
        func finite(_ point: Point2D) -> Bool { point.x.isFinite && point.y.isFinite }

        for room in project.rooms {
            for wall in room.walls {
                if !finite(wall.start) || !finite(wall.end) || !finite(wall.length) || !finite(wall.height) || !finite(wall.thickness) {
                    issues.append(.init(.error, "Wall \(wall.id) contains non-finite geometry."))
                }
                if wall.length <= 0 || wall.height <= 0 || wall.thickness <= 0 {
                    issues.append(.init(.error, "Wall \(wall.id) has non-positive architectural dimensions."))
                }
            }
            for opening in room.openings {
                let p = opening.parameters
                if !finite(p.offsetAlongWall) || !finite(p.width) || !finite(p.height) || !finite(p.sillHeight) {
                    issues.append(.init(.error, "Opening \(opening.id) contains non-finite geometry."))
                }
                if p.width <= 0 || p.height <= 0 || p.sillHeight < 0 {
                    issues.append(.init(.error, "Opening \(opening.id) has invalid architectural dimensions."))
                }
            }
        }

        let declared = Set(ArchitecturalDraftingConvention.Layer.allCases.map(\.rawValue))
        for primitive in preview.primitives {
            if !declared.contains(primitive.layer) {
                issues.append(.init(.error, "Primitive \(primitive.id) references undeclared layer \(primitive.layer)."))
            }
            if primitive.points.contains(where: { !finite($0) }) || (primitive.center.map { !finite($0) } ?? false) {
                issues.append(.init(.error, "Primitive \(primitive.id) contains non-finite coordinates."))
            }
            let numeric = [primitive.radius, primitive.startAngleDegrees, primitive.endAngleDegrees, primitive.textHeight, primitive.rotationDegrees, primitive.lineWeightMM]
            if numeric.compactMap({ $0 }).contains(where: { !finite($0) }) {
                issues.append(.init(.error, "Primitive \(primitive.id) contains a non-finite numeric value."))
            }
            switch primitive.kind {
            case .line where primitive.points.count < 2:
                issues.append(.init(.error, "LINE primitive \(primitive.id) has fewer than two points."))
            case .polyline where primitive.points.count < 2:
                issues.append(.init(.error, "LWPOLYLINE primitive \(primitive.id) has fewer than two vertices."))
            case .arc where primitive.center == nil || primitive.radius == nil || primitive.startAngleDegrees == nil || primitive.endAngleDegrees == nil:
                issues.append(.init(.error, "ARC primitive \(primitive.id) is incomplete."))
            case .text where primitive.points.isEmpty || primitive.text == nil:
                issues.append(.init(.error, "TEXT primitive \(primitive.id) is incomplete."))
            default: break
            }
        }
        return issues
    }

    private func validateExportedDXF(_ text: String, declaredLayers: Set<String>) -> [DXFExportIssue] {
        var issues: [DXFExportIssue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count.isMultiple(of: 2) else {
            return [.init(.error, "DXF serialization produced an incomplete group-code pair.")]
        }
        var pairs: [(Int, String)] = []
        var i = 0
        while i + 1 < lines.count {
            guard let code = Int(lines[i].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                issues.append(.init(.error, "DXF contains an invalid group code at line \(i + 1)."))
                i += 2
                continue
            }
            pairs.append((code, lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)))
            i += 2
        }
        let values = pairs.filter { $0.0 == 0 }.map(\.1)
        for required in ["SECTION", "ENDSEC", "EOF"] where !values.contains(required) {
            issues.append(.init(.error, "DXF is missing required \(required) record."))
        }
        guard pairs.last?.0 == 0, pairs.last?.1 == "EOF" else {
            issues.append(.init(.error, "DXF does not terminate with EOF."))
            return issues
        }
        let sections = pairs.enumerated().compactMap { index, pair -> String? in
            guard pair.0 == 0, pair.1 == "SECTION", index + 1 < pairs.count, pairs[index + 1].0 == 2 else { return nil }
            return pairs[index + 1].1
        }
        for required in ["HEADER", "TABLES", "BLOCKS", "ENTITIES"] where !sections.contains(required) {
            issues.append(.init(.error, "DXF is missing required \(required) section."))
        }
        let parsed = parseRecords(text)
        for record in parsed where !declaredLayers.contains(record.layer) {
            issues.append(.init(.error, "Entity \(record.type) references undeclared layer \(record.layer)."))
        }
        if !text.contains("\r\n") {
            issues.append(.init(.warning, "DXF does not use CRLF line endings."))
        }
        return issues
    }

    private func dxfBounds(preview: DXFPreviewSnapshot, project: PlanOpsisProject) -> FloorGeometry {
        var points = preview.primitives.flatMap(\.boundsPoints)
        points.append(contentsOf: project.rooms.flatMap { $0.walls.flatMap { [$0.start, $0.end] } })
        guard let first = points.first else {
            return FloorGeometry(min: .zero, max: Point2D(x: 1_000, y: 1_000))
        }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        let pad = 500.0
        return FloorGeometry(min: Point2D(x: minX - pad, y: minY - pad), max: Point2D(x: maxX + pad, y: maxY + pad))
    }

    private func sanitizeDXFValue(_ value: String) -> String {
        DXFTextCodec.encode(value)
    }

    private func ifcClass(for kind: PlanOpsisOpening.Kind) -> ArchitecturalDraftingConvention.IFCClass {
        switch kind {
        case .door: return .door
        case .window: return .window
        case .opening: return .opening
        }
    }

    private func ifcClass(for kind: PlanOpsisComponent.Kind) -> ArchitecturalDraftingConvention.IFCClass {
        switch kind {
        case .column: return .column
        case .beam: return .beam
        case .bed, .table, .chair, .sofa: return .furnishing
        case .wc, .sink: return .sanitaryTerminal
        }
    }

    private func ifcClass(for kind: DisplayOpeningKind) -> ArchitecturalDraftingConvention.IFCClass {
        switch kind {
        case .door: return .door
        case .window: return .window
        case .opening, .mixedPassage: return .opening
        }
    }

    private struct DraftOpening: Sendable {
        var opening: PlanOpsisOpening
        var centerOffset: Double
        var startOffset: Double
        var endOffset: Double
    }

    private struct DraftEdge: Sendable {
        var index: Int
        var wall: PlanOpsisWall
        var centerStart: Point2D
        var centerEnd: Point2D
        var direction: Point2D
        var inwardNormal: Point2D
        var innerStart: Point2D
        var innerEnd: Point2D
        var outerStart: Point2D
        var outerEnd: Point2D
        var openings: [DraftOpening]

        var length: Double { (centerEnd - centerStart).length }
    }

    private struct RoomDraft: Sendable {
        var room: PlanOpsisRoom
        var centerline: [Point2D]
        var innerBoundary: [Point2D]
        var outerBoundary: [Point2D]
        var edges: [DraftEdge]
    }

    /// Builds one coherent architectural drafting model for a closed room. The topology loop,
    /// wall faces, hosted opening stations and dimensions all share the same ordered edges.
    /// This avoids the v9.4 failure mode where segmented display geometry and annotations used
    /// independent coordinate constructions.
    private func roomDraft(room: PlanOpsisRoom, centerline: [Point2D]) -> RoomDraft? {
        // v12.1: the face construction is shared with IFC (Geometry/RoomFaceBoundary).
        guard let boundary = RoomFaceBoundary(room: room, centerline: centerline) else { return nil }
        let base = boundary.edges
        let innerVertices = boundary.inner
        let outerVertices = boundary.outer

        var edges: [DraftEdge] = []
        edges.reserveCapacity(base.count)
        for index in base.indices {
            let edge = base[index]
            let length = (edge.b - edge.a).length
            let hosted = room.openings
                .filter { $0.parameters.hostWallID == edge.wall.id }
                .compactMap { opening -> DraftOpening? in
                    let semanticCenter = edge.wall.start + edge.wall.direction * opening.parameters.offsetAlongWall
                    let projectedCenter = max(0, min(length, (semanticCenter - edge.a).dot(edge.direction)))
                    let half = opening.parameters.width * 0.5
                    let start = max(0, min(length, projectedCenter - half))
                    let end = max(0, min(length, projectedCenter + half))
                    guard end > start + 1e-6 else { return nil }
                    return DraftOpening(opening: opening, centerOffset: projectedCenter, startOffset: start, endOffset: end)
                }
                .sorted {
                    if $0.startOffset == $1.startOffset { return $0.opening.id.uuidString < $1.opening.id.uuidString }
                    return $0.startOffset < $1.startOffset
                }

            edges.append(DraftEdge(
                index: index,
                wall: edge.wall,
                centerStart: edge.a,
                centerEnd: edge.b,
                direction: edge.direction,
                inwardNormal: edge.inward,
                innerStart: innerVertices[index],
                innerEnd: innerVertices[(index + 1) % innerVertices.count],
                outerStart: outerVertices[index],
                outerEnd: outerVertices[(index + 1) % outerVertices.count],
                openings: hosted
            ))
        }

        return RoomDraft(room: room, centerline: centerline, innerBoundary: innerVertices, outerBoundary: outerVertices, edges: edges)
    }

    private func pointInPolygon(_ point: Point2D, polygon: [Point2D]) -> Bool {
        PlanPolygon.contains(point, in: polygon)
    }

    private func mergedOpeningIntervals(_ openings: [DraftOpening], length: Double) -> [(Double, Double)] {
        var intervals: [(Double, Double)] = []
        intervals.reserveCapacity(openings.count)
        for opening in openings {
            let a = max(0.0, min(length, opening.startOffset))
            let b = max(0.0, min(length, opening.endOffset))
            if b > a + 1e-6 { intervals.append((a, b)) }
        }
        intervals.sort {
            if $0.0 == $1.0 { return $0.1 < $1.1 }
            return $0.0 < $1.0
        }
        guard var current = intervals.first else { return [] }
        var result: [(Double, Double)] = []
        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 + 1e-6 {
                current.1 = max(current.1, interval.1)
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    private func pointOnFace(edge: DraftEdge, offset: Double, inwardFace: Bool) -> Point2D {
        let half = edge.wall.thickness * 0.5
        return edge.centerStart + edge.direction * offset + edge.inwardNormal * (inwardFace ? half : -half)
    }

    private func wallPrimitives(for draft: RoomDraft) -> [DXFPrimitive] {
        let layer = ArchitecturalDraftingConvention.Layer.wall
        let lw = ArchitecturalDraftingConvention.lineWeightMM(for: layer)
        var output: [DXFPrimitive] = []

        for edge in draft.edges {
            let length = edge.length
            guard length > 1e-6 else { continue }
            let voids = mergedOpeningIntervals(edge.openings, length: length)

            for inwardFace in [true, false] {
                var cursor = 0.0
                var segmentIndex = 0
                for interval in voids {
                    if interval.0 > cursor + 1e-6 {
                        let a = cursor <= 1e-6 ? (inwardFace ? edge.innerStart : edge.outerStart) : pointOnFace(edge: edge, offset: cursor, inwardFace: inwardFace)
                        let b = pointOnFace(edge: edge, offset: interval.0, inwardFace: inwardFace)
                        if (b - a).length > 1e-6 {
                            output.append(DXFPrimitive(
                                id: "wall:\(edge.wall.id):\(inwardFace ? "inner" : "outer"):\(segmentIndex)",
                                kind: .line,
                                layer: layer.rawValue,
                                points: [a, b],
                                lineWeightMM: lw,
                                ifcClass: .wall,
                                objectIDs: [edge.wall.id],
                                roomIDs: [draft.room.id]
                            ))
                        }
                        segmentIndex += 1
                    }
                    cursor = max(cursor, interval.1)
                }
                if cursor < length - 1e-6 {
                    let a = cursor <= 1e-6 ? (inwardFace ? edge.innerStart : edge.outerStart) : pointOnFace(edge: edge, offset: cursor, inwardFace: inwardFace)
                    let b = inwardFace ? edge.innerEnd : edge.outerEnd
                    if (b - a).length > 1e-6 {
                        output.append(DXFPrimitive(
                            id: "wall:\(edge.wall.id):\(inwardFace ? "inner" : "outer"):\(segmentIndex)",
                            kind: .line,
                            layer: layer.rawValue,
                            points: [a, b],
                            lineWeightMM: lw,
                            ifcClass: .wall,
                            objectIDs: [edge.wall.id],
                            roomIDs: [draft.room.id]
                        ))
                    }
                }
            }
        }
        return output
    }

    private func openingPrimitives(for draft: RoomDraft) -> [DXFPrimitive] {
        draft.edges.flatMap { edge in
            edge.openings.flatMap { item in
                let opening = item.opening
                let center = edge.centerStart + edge.direction * item.centerOffset
                let symbol = ArchitecturalSymbolLibrary.opening(
                    id: opening.id.uuidString,
                    kind: DisplayOpeningKind(rawValue: opening.kind.rawValue)!,
                    center: center, width: item.endOffset - item.startOffset,
                    thickness: edge.wall.thickness, angle: edge.wall.angleRadians,
                    swing: opening.doorSwing ?? .unspecified,
                    doorOperation: opening.doorOperation ?? .singleHinged,
                    windowOperation: opening.windowOperation ?? .fixed,
                    inwardSign: ArchitecturalSymbolLibrary.inwardSign(center: center, angle: edge.wall.angleRadians, boundary: draft.centerline)
                )
                return symbolPrimitives(symbol, ifc: ifcClass(for: opening.kind),
                    type: PlanOpsisExchangeIdentity.semanticType(for: opening),
                    objectIDs: [opening.id], roomIDs: [draft.room.id], hostIDs: [edge.wall.id])
            }
        }
    }

    private func dimensionPrimitives(for draft: RoomDraft) -> [DXFPrimitive] {
        draft.edges.flatMap { edge in
            dimensionPrimitives(
                id: edge.wall.id.uuidString,
                start: edge.centerStart,
                end: edge.centerEnd,
                thickness: edge.wall.thickness,
                explicitOutwardNormal: edge.inwardNormal * -1,
                measuredLength: edge.length
            )
        }
    }

    private func spaceAndRoomAnnotationPrimitives(for draft: RoomDraft, roomIndex: Int) -> [DXFPrimitive] {
        guard let centroid = polygonCentroid(draft.innerBoundary) else { return [] }
        let spaceLayer = ArchitecturalDraftingConvention.Layer.space
        let annotationLayer = ArchitecturalDraftingConvention.Layer.roomAnnotation
        let areaM2 = polygonArea(draft.innerBoundary) / 1_000_000
        let labelGap = 120.0
        return [
            DXFPrimitive(
                id: "space:\(draft.room.id.uuidString)",
                kind: .polyline,
                layer: spaceLayer.rawValue,
                points: draft.innerBoundary,
                closed: true,
                lineWeightMM: ArchitecturalDraftingConvention.lineWeightMM(for: spaceLayer),
                ifcClass: .space,
                objectIDs: [draft.room.id],
                roomIDs: [draft.room.id]
            ),
            DXFPrimitive(
                id: "room-name:\(draft.room.id.uuidString)",
                kind: .text,
                layer: annotationLayer.rawValue,
                points: [centroid + Point2D(x: 0, y: labelGap)],
                text: "ROOM \(roomIndex + 1)",
                textHeight: ArchitecturalDraftingConvention.TextStyle.roomNameHeightMM,
                rotationDegrees: 0,
                lineWeightMM: ArchitecturalDraftingConvention.lineWeightMM(for: annotationLayer)
            ),
            DXFPrimitive(
                id: "room-area:\(draft.room.id.uuidString)",
                kind: .text,
                layer: annotationLayer.rawValue,
                points: [centroid - Point2D(x: 0, y: labelGap)],
                text: String(format: "%.2f m2", areaM2),
                textHeight: ArchitecturalDraftingConvention.TextStyle.dimensionHeightMM,
                rotationDegrees: 0,
                lineWeightMM: ArchitecturalDraftingConvention.lineWeightMM(for: annotationLayer)
            )
        ]
    }

    private func componentPrimitives(_ component: PlanOpsisComponent, roomID: UUID) -> [DXFPrimitive] {
        symbolPrimitives(ArchitecturalSymbolLibrary.component(component), ifc: ifcClass(for: component.kind),
                         type: PlanOpsisExchangeIdentity.semanticType(for: component), objectIDs: [component.id], roomIDs: [roomID])
    }

    /// Serialization adapter only. Architectural construction belongs to ArchitecturalSymbolLibrary.
    private func symbolPrimitives(_ symbol: ArchitecturalSymbol, ifc: ArchitecturalDraftingConvention.IFCClass,
                                  type: String, objectIDs: [UUID], roomIDs: [UUID], hostIDs: [UUID] = []) -> [DXFPrimitive] {
        symbol.primitives.map { item in
            let layer = item.role == .swing ? ArchitecturalDraftingConvention.Layer.doorSwing : ArchitecturalDraftingConvention.layer(for: ifc)
            let weight = item.role == .detail ? 0.13 : ArchitecturalDraftingConvention.lineWeightMM(for: layer)
            var primitive = DXFPrimitive(id: item.id, kind: .line, layer: layer.rawValue, lineWeightMM: weight,
                                         ifcClass: ifc, semanticType: type, objectIDs: objectIDs, roomIDs: roomIDs, hostIDs: hostIDs)
            switch item.geometry {
            case .line(let a, let b): primitive.points = [a,b]
            case .polyline(let points, let closed):
                primitive.kind = .polyline; primitive.points = points; primitive.closed = closed
            case .arc(let center, let radius, let start, let end):
                primitive.kind = .arc; primitive.center = center; primitive.radius = radius
                primitive.startAngleDegrees = start * 180 / .pi; primitive.endAngleDegrees = end * 180 / .pi
            }
            return primitive
        }
    }

    private func roomBoundsCenter(_ room: PlanOpsisRoom) -> Point2D? {
        let points = room.walls.flatMap { [$0.start, $0.end] }
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return Point2D(x: (minX + maxX) * 0.5, y: (minY + maxY) * 0.5)
    }

    private func wallFacePrimitives(for segments: [DisplayWallPlanSegment]) -> [DXFPrimitive] {
        var output: [DXFPrimitive] = []
        let layer = ArchitecturalDraftingConvention.Layer.wall
        let lw = ArchitecturalDraftingConvention.lineWeightMM(for: layer)

        for segment in segments {
            guard segment.footprint.count >= 4 else { continue }
            // Footprints are ordered [start+N, end+N, end-N, start-N]. Export the
            // two longitudinal faces here; ArchitecturalWallDrawing supplies exposed
            // terminal edges from these same footprints and clips junction interiors.
            let faces = [
                (segment.footprint[0], segment.footprint[1], "face-a"),
                (segment.footprint[3], segment.footprint[2], "face-b")
            ]
            for (a, b, suffix) in faces where (b - a).length > 1e-6 {
                output.append(DXFPrimitive(
                    id: "wall-\(suffix):\(segment.id)",
                    kind: .line,
                    layer: layer.rawValue,
                    points: [a, b],
                    lineWeightMM: lw,
                    ifcClass: .wall,
                    objectIDs: segment.sourceWallIDs,
                    roomIDs: segment.sourceRoomIDs
                ))
            }
        }
        return output
    }

    private func architecturalPrimitives(for opening: DisplayOpeningGeometry, roomFloors: [RoomFloorGeometry], project: PlanOpsisProject) -> [DXFPrimitive] {
        let type: String
        switch opening.kind {
        case .door: type = "door.\((opening.doorOperation ?? .singleHinged).rawValue)"
        case .window: type = "window.\((opening.windowOperation ?? .fixed).rawValue)"
        case .opening, .mixedPassage: type = "opening.generic"
        }
        let hosts = project.rooms.flatMap(\.openings).filter { opening.sourceOpeningIDs.contains($0.id) }.map { $0.parameters.hostWallID }
        return symbolPrimitives(ArchitecturalSymbolLibrary.opening(opening, roomFloors: roomFloors), ifc: ifcClass(for: opening.kind),
                                type: type, objectIDs: opening.sourceOpeningIDs, roomIDs: opening.sourceRoomIDs, hostIDs: Set(hosts).sorted { $0.uuidString < $1.uuidString })
    }

    private func dimensionPrimitives(for wall: PlanOpsisWall, roomCentroid: Point2D?) -> [DXFPrimitive] {
        let vector = wall.end - wall.start
        let length = vector.length
        guard length > 1e-6 else { return [] }
        let direction = vector * (1 / length)
        let normal = Point2D(x: -direction.y, y: direction.x)
        let center = (wall.start + wall.end) * 0.5
        let outward: Point2D
        if let roomCentroid {
            let plus = center + normal * 100
            let minus = center - normal * 100
            outward = (plus - roomCentroid).length >= (minus - roomCentroid).length ? normal : normal * -1
        } else {
            outward = normal
        }
        return dimensionPrimitives(
            id: wall.id.uuidString,
            start: wall.start,
            end: wall.end,
            thickness: wall.thickness,
            explicitOutwardNormal: outward,
            measuredLength: wall.length
        )
    }

    private func dimensionPrimitives(
        id: String,
        start: Point2D,
        end: Point2D,
        thickness: Double,
        explicitOutwardNormal: Point2D,
        measuredLength: Double,
        offsetBeyondFace: Double = 350
    ) -> [DXFPrimitive] {
        let vector = end - start
        let geometryLength = vector.length
        guard geometryLength > 1e-6 else { return [] }
        let direction = vector * (1 / geometryLength)
        let outwardNormal = explicitOutwardNormal.normalized
        let faceOffset = max(0, thickness) * 0.5
        let dimensionOffset = faceOffset + offsetBeyondFace
        let extensionGap = faceOffset + 30
        let extensionOvershoot = 80.0
        let a = start + outwardNormal * dimensionOffset
        let b = end + outwardNormal * dimensionOffset
        let extensionA = start + outwardNormal * extensionGap
        let extensionB = end + outwardNormal * extensionGap
        let mid = (a + b) * 0.5
        let tickDirection = (direction + outwardNormal).normalized * 80
        let layer = ArchitecturalDraftingConvention.Layer.dimensions.rawValue
        let lw = ArchitecturalDraftingConvention.lineWeightMM(for: .dimensions)
        let label = "\(Int(measuredLength.rounded()))"
        var rotation = normalizeDegrees(atan2(direction.y, direction.x) * 180 / .pi)
        if rotation > 90 && rotation < 270 { rotation = normalizeDegrees(rotation + 180) }

        // Keep text close to its own dimension line. The previous center-alignment serializer bug
        // could cause third-party readers to ignore the alignment point and stack labels centrally;
        // v9.5 also fixes that DXF group ordering in appendTextEntity().
        let textPoint = mid + outwardNormal * 95
        return [
            DXFPrimitive(id: "dim-ext-a:\(id)", kind: .line, layer: layer, points: [extensionA, a + outwardNormal * extensionOvershoot], lineWeightMM: lw),
            DXFPrimitive(id: "dim-ext-b:\(id)", kind: .line, layer: layer, points: [extensionB, b + outwardNormal * extensionOvershoot], lineWeightMM: lw),
            DXFPrimitive(id: "dim-line:\(id)", kind: .line, layer: layer, points: [a, b], lineWeightMM: lw),
            DXFPrimitive(id: "dim-tick-a:\(id)", kind: .line, layer: layer, points: [a - tickDirection * 0.5, a + tickDirection * 0.5], lineWeightMM: lw),
            DXFPrimitive(id: "dim-tick-b:\(id)", kind: .line, layer: layer, points: [b - tickDirection * 0.5, b + tickDirection * 0.5], lineWeightMM: lw),
            DXFPrimitive(id: "dim-text:\(id)", kind: .text, layer: layer, points: [textPoint], text: label, textHeight: ArchitecturalDraftingConvention.TextStyle.dimensionHeightMM, rotationDegrees: rotation, lineWeightMM: lw)
        ]
    }

    private func polygonArea(_ polygon: [Point2D]) -> Double { PlanPolygon.area(polygon) }

    private func polygonCentroid(_ polygon: [Point2D]) -> Point2D? { PlanPolygon.centroid(polygon) }

    private func normalizeDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    private func swingCode(_ swing: PlanOpsisDoor.Swing) -> Int {
        switch swing {
        case .unspecified: return 0
        case .leftIn: return 1
        case .leftOut: return 2
        case .rightIn: return 3
        case .rightOut: return 4
        }
    }

    private func swing(from code: Int) -> PlanOpsisDoor.Swing {
        switch code {
        case 1: return .leftIn
        case 2: return .leftOut
        case 3: return .rightIn
        case 4: return .rightOut
        default: return .unspecified
        }
    }
}
