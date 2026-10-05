import Foundation

public struct IFC4ExportIssue: Codable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, Hashable, Sendable { case warning, error }
    public var severity: Severity
    public var message: String
    public var id: String { "ifc4:\(severity.rawValue):\(message)" }
    public init(_ severity: Severity, _ message: String) { self.severity = severity; self.message = message }
}

public struct IFC4ExportResult: Sendable {
    public var text: String
    public var issues: [IFC4ExportIssue]
    public var objectGlobalIDs: [UUID: String]
    public var canWrite: Bool { !issues.contains { $0.severity == .error } && !text.isEmpty }

    public init(text: String, issues: [IFC4ExportIssue], objectGlobalIDs: [UUID: String]) {
        self.text = text
        self.issues = issues
        self.objectGlobalIDs = objectGlobalIDs
    }
}

/// Native, dependency-free IFC4 STEP Physical File exporter.
///
/// Current native PlanOpsis IFC4 scope:
/// - semantic export only; IFC import remains intentionally out of scope;
/// - one IfcProject / IfcSite / IfcBuilding / IfcBuildingStorey hierarchy;
/// - PlanOpsisRoom -> IfcSpace;
/// - walls, openings, doors, windows, columns, furnishings, sanitary terminals;
/// - IfcRelVoidsElement and IfcRelFillsElement host relationships;
/// - stable IFC GlobalIds derived from PlanOpsis UUIDs;
/// - Pset_PlanOpsisIdentity retains explicit semantic UUID/type/host references.
///
/// The IFC serializer is a sibling of DXF. It never parses DXF and DXF never parses IFC.
public struct IFC4ExchangeEngine {
    public init() {}

    public func export(project: PlanOpsisProject) -> String {
        exportValidated(project: project).text
    }

    public func exportValidated(project: PlanOpsisProject) -> IFC4ExportResult {
        var issues = validate(project: project)
        guard !issues.contains(where: { $0.severity == .error }) else {
            return IFC4ExportResult(text: "", issues: issues, objectGlobalIDs: [:])
        }

        var writer = STEPWriter()
        var objectGlobalIDs: [UUID: String] = [:]
        let owner = makeOwnerHistory(&writer)
        let modelContext = makeModelContext(&writer)
        let units = makeUnits(&writer)

        let projectPlacementID = project.id
        let projectGUID = PlanOpsisExchangeIdentity.ifcGlobalID(for: project.id)
        objectGlobalIDs[project.id] = projectGUID
        let projectRef = writer.add("IFCPROJECT('\(projectGUID)',#\(owner),'PlanOpsis Project',$,'PlanOpsis semantic model',$,$,(#\(modelContext)),#\(units))")

        let siteUUID = PlanOpsisExchangeIdentity.derivedUUID(namespace: projectPlacementID, role: "ifc.site")
        let buildingUUID = PlanOpsisExchangeIdentity.derivedUUID(namespace: projectPlacementID, role: "ifc.building")
        let storeyUUID = PlanOpsisExchangeIdentity.derivedUUID(namespace: projectPlacementID, role: "ifc.storey.0")

        let sitePlacement = makeLocalPlacement(&writer, relativeTo: nil, x: 0, y: 0, z: 0, angleRadians: 0)
        let siteRef = writer.add("IFCSITE('\(PlanOpsisExchangeIdentity.ifcGlobalID(for: siteUUID))',#\(owner),'Site',$,$,#\(sitePlacement),$,$,.ELEMENT.,$,$,$,$,$)")
        let buildingPlacement = makeLocalPlacement(&writer, relativeTo: sitePlacement, x: 0, y: 0, z: 0, angleRadians: 0)
        let buildingRef = writer.add("IFCBUILDING('\(PlanOpsisExchangeIdentity.ifcGlobalID(for: buildingUUID))',#\(owner),'Building',$,$,#\(buildingPlacement),$,$,.ELEMENT.,0.,$,$)")
        let storeyPlacement = makeLocalPlacement(&writer, relativeTo: buildingPlacement, x: 0, y: 0, z: 0, angleRadians: 0)
        let storeyRef = writer.add("IFCBUILDINGSTOREY('\(PlanOpsisExchangeIdentity.ifcGlobalID(for: storeyUUID))',#\(owner),'Storey 0',$,$,#\(storeyPlacement),$,$,.ELEMENT.,0.)")

        _ = writer.add("IFCRELAGGREGATES('\(relGUID(project.id, "rel.project.site"))',#\(owner),$,$,#\(projectRef),(#\(siteRef)))")
        _ = writer.add("IFCRELAGGREGATES('\(relGUID(project.id, "rel.site.building"))',#\(owner),$,$,#\(siteRef),(#\(buildingRef)))")
        _ = writer.add("IFCRELAGGREGATES('\(relGUID(project.id, "rel.building.storey"))',#\(owner),$,$,#\(buildingRef),(#\(storeyRef)))")

        let semanticGeometry = ParametricGeometryEngine().generate(from: project)
        var spaceRefs: [UUID: Int] = [:]
        var roomContainedRefs: [UUID: [Int]] = [:]
        var storeyContainedRefs: [Int] = []
        var wallRefs: [UUID: Int] = [:]
        var openingRefs: [UUID: Int] = [:]
        // v12.5 base quantities (Qto_*) for spaces, walls, doors and windows, from the same takeoff as the
        // drawing set. Lengths are in millimetres, areas in m², volumes in m³ (the file's units).
        let schedules = ProjectSchedules(project: project, semanticGeometry: semanticGeometry)
        let takeoff = ProjectQuantities(project: project, schedules: schedules)
        func addQuantities(_ writer: inout STEPWriter, for id: UUID, entity: Int, set name: String, _ items: [(String, String, Double)]) {
            let refs = items.map { item -> String in
                let (kind, label, value) = item
                switch kind {
                case "length": return "#\(writer.add("IFCQUANTITYLENGTH('\(label)',$,$,\(number(value)),$)"))"
                case "volume": return "#\(writer.add("IFCQUANTITYVOLUME('\(label)',$,$,\(number(value / 1_000_000_000)),$)"))"
                default: return "#\(writer.add("IFCQUANTITYAREA('\(label)',$,$,\(number(value / 1_000_000)),$)"))"
                }
            }
            let quantities = writer.add("IFCELEMENTQUANTITY('\(relGUID(id, "qto.\(name)"))',#\(owner),'\(name)',$,$,(\(refs.joined(separator: ","))))")
            _ = writer.add("IFCRELDEFINESBYPROPERTIES('\(relGUID(id, "rel.qto.\(name)"))',#\(owner),$,$,(#\(entity)),#\(quantities))")
        }

        // v12.6: entities are written and numbered in plan order (rooms north-west first, walls and
        // openings clockwise), never in capture order, so names read in sequence in any IFC viewer.
        let ordering = PlanOrdering(project: project)
        func openingKey(_ opening: PlanOpsisOpening, _ room: PlanOpsisRoom) -> (Int, Int, Double, String) {
            let key = ordering.openingKey(opening, in: room) ?? (Int.max, Int.max, 0)
            return (key.0, key.1, key.2, opening.id.uuidString)
        }

        for room in ordering.rooms {
            let roomNumber = ordering.roomNumbers[room.id] ?? 0
            let centerline = ArchitecturalRoomEnvelope.polygon(for: room, topology: semanticGeometry.topology)
            // v12.1: the space body is the clear interior between wall faces, the same construction as
            // the DXF A-SPACE boundary, so drawn and modelled floor areas agree.
            let faces = RoomFaceBoundary(room: room, centerline: centerline)
            let roomHeight = max(1, room.walls.map(\.height).max() ?? 2_800)
            let roomPlacement = makeLocalPlacement(&writer, relativeTo: storeyPlacement, x: 0, y: 0, z: 0, angleRadians: 0)
            let roomRepresentation: String
            if let faces {
                roomRepresentation = "#\(makeSpaceRepresentation(&writer, context: modelContext, boundary: faces.inner, height: roomHeight))"
            } else {
                roomRepresentation = "$"
                issues.append(.init(.warning, "Room \(room.id) has no proven closed boundary; IfcSpace has no invented body."))
            }
            let roomGUID = PlanOpsisExchangeIdentity.ifcGlobalID(for: room.id)
            objectGlobalIDs[room.id] = roomGUID
            // Name is the stable room number; the surveyed room name is the IFC LongName.
            let surveyName = project.survey.roomNames[room.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let longName = surveyName.isEmpty ? "$" : "'\(stepString(surveyName))'"
            let roomRef = writer.add("IFCSPACE('\(roomGUID)',#\(owner),'Room \(roomNumber)',$,$,#\(roomPlacement),\(roomRepresentation),\(longName),.ELEMENT.,.SPACE.,0.)")
            if let faces {
                var items: [(String, String, Double)] = [("area", "NetFloorArea", faces.netArea)]
                if let q = takeoff.rooms.first(where: { $0.roomID == room.id }) {
                    items += [("length", "Height", q.height), ("length", "NetPerimeter", q.perimeter), ("area", "NetCeilingArea", q.ceilingArea),
                              ("area", "GrossWallArea", q.grossWallArea), ("area", "NetWallArea", q.netWallArea), ("volume", "NetVolume", q.volume)]
                }
                addQuantities(&writer, for: room.id, entity: roomRef, set: "Qto_SpaceBaseQuantities", items)
            }
            spaceRefs[room.id] = roomRef
            roomContainedRefs[room.id] = []
            addIdentityProperties(&writer, owner: owner, semanticID: room.id, entityRef: roomRef, ifcClass: "IfcSpace", semanticType: "space", roomID: room.id, hostID: nil)

            _ = writer.add("IFCRELAGGREGATES('\(relGUID(room.id, "rel.storey.space"))',#\(owner),$,$,#\(storeyRef),(#\(roomRef)))")

            for wall in ordering.orderedWalls(of: room) {
                let placement = makeLocalPlacement(
                    &writer,
                    relativeTo: storeyPlacement,
                    x: wall.start.x,
                    y: wall.start.y,
                    z: 0,
                    angleRadians: wall.angleRadians
                )
                let representation = makeBoxRepresentation(
                    &writer,
                    context: modelContext,
                    width: wall.length,
                    depth: max(1, wall.thickness),
                    height: max(1, wall.height),
                    originMode: .startCenteredDepth
                )
                let guid = PlanOpsisExchangeIdentity.ifcGlobalID(for: wall.id)
                objectGlobalIDs[wall.id] = guid
                let wallRef = writer.add("IFCWALL('\(guid)',#\(owner),'\(ordering.wallName(wall.id) ?? "Wall")',$,$,#\(placement),#\(representation),$,.NOTDEFINED.)")
                wallRefs[wall.id] = wallRef
                storeyContainedRefs.append(wallRef)
                if let q = takeoff.walls.first(where: { $0.wallID == wall.id }) {
                    addQuantities(&writer, for: wall.id, entity: wallRef, set: "Qto_WallBaseQuantities", [
                        ("length", "Length", q.length), ("length", "Width", q.thickness), ("length", "Height", q.height),
                        ("area", "GrossSideArea", q.grossSideArea), ("area", "NetSideArea", q.netSideArea),
                        ("volume", "GrossVolume", q.grossVolume), ("volume", "NetVolume", q.netVolume),
                    ])
                }
                addIdentityProperties(&writer, owner: owner, semanticID: wall.id, entityRef: wallRef, ifcClass: "IfcWall", semanticType: "wall", roomID: room.id, hostID: nil)
            }

            for component in room.components {
                let placement = makeLocalPlacement(
                    &writer,
                    relativeTo: storeyPlacement,
                    x: component.position.x,
                    y: component.position.y,
                    z: component.baseElevationMM,
                    angleRadians: component.rotationRadians
                )
                let representation = makeBoxRepresentation(
                    &writer,
                    context: modelContext,
                    width: max(1, component.width),
                    depth: max(1, component.depth),
                    height: max(1, component.height),
                    originMode: .centered
                )
                let guid = PlanOpsisExchangeIdentity.ifcGlobalID(for: component.id)
                objectGlobalIDs[component.id] = guid
                let semanticType = PlanOpsisExchangeIdentity.semanticType(for: component)
                let entityRef: Int
                let ifcClass: String
                switch component.kind {
                case .column:
                    entityRef = writer.add("IFCCOLUMN('\(guid)',#\(owner),'Column',$,$,#\(placement),#\(representation),$,.COLUMN.)")
                    ifcClass = "IfcColumn"
                    storeyContainedRefs.append(entityRef)
                case .beam:
                    entityRef = writer.add("IFCBEAM('\(guid)',#\(owner),'Beam',$,$,#\(placement),#\(representation),$,.BEAM.)")
                    ifcClass = "IfcBeam"
                    storeyContainedRefs.append(entityRef)
                case .bed, .table, .chair, .sofa:
                    entityRef = writer.add("IFCFURNISHINGELEMENT('\(guid)',#\(owner),'\(stepString(component.kind.displayName))',$,'\(stepString(semanticType))',#\(placement),#\(representation),$)")
                    ifcClass = "IfcFurnishingElement"
                    roomContainedRefs[room.id, default: []].append(entityRef)
                case .wc, .sink, .bathtub:
                    let predefined = component.kind == .wc ? ".TOILETPAN." : (component.kind == .sink ? ".SINK." : ".BATH.")
                    entityRef = writer.add("IFCSANITARYTERMINAL('\(guid)',#\(owner),'\(stepString(component.kind.displayName))',$,'\(stepString(semanticType))',#\(placement),#\(representation),$,\(predefined))")
                    ifcClass = "IfcSanitaryTerminal"
                    roomContainedRefs[room.id, default: []].append(entityRef)
                // v12.8 objects from the scan library.
                case .storage, .fireplace:
                    entityRef = writer.add("IFCFURNISHINGELEMENT('\(guid)',#\(owner),'\(stepString(component.kind.displayName))',$,'\(stepString(semanticType))',#\(placement),#\(representation),$)")
                    ifcClass = "IfcFurnishingElement"
                    roomContainedRefs[room.id, default: []].append(entityRef)
                case .refrigerator, .stove, .oven, .dishwasher, .washerDryer:
                    let predefined: String
                    switch component.kind {
                    case .refrigerator: predefined = ".FRIDGE_FREEZER."
                    case .dishwasher: predefined = ".DISHWASHER."
                    case .washerDryer: predefined = ".WASHINGMACHINE."
                    default: predefined = ".ELECTRICCOOKER."
                    }
                    entityRef = writer.add("IFCELECTRICAPPLIANCE('\(guid)',#\(owner),'\(stepString(component.kind.displayName))',$,'\(stepString(semanticType))',#\(placement),#\(representation),$,\(predefined))")
                    ifcClass = "IfcElectricAppliance"
                    roomContainedRefs[room.id, default: []].append(entityRef)
                case .television:
                    entityRef = writer.add("IFCAUDIOVISUALAPPLIANCE('\(guid)',#\(owner),'\(stepString(component.kind.displayName))',$,'\(stepString(semanticType))',#\(placement),#\(representation),$,.TV.)")
                    ifcClass = "IfcAudioVisualAppliance"
                    roomContainedRefs[room.id, default: []].append(entityRef)
                case .stairs:
                    entityRef = writer.add("IFCSTAIR('\(guid)',#\(owner),'Stairs',$,'\(stepString(semanticType))',#\(placement),#\(representation),$,.NOTDEFINED.)")
                    ifcClass = "IfcStair"
                    storeyContainedRefs.append(entityRef)
                }
                addIdentityProperties(&writer, owner: owner, semanticID: component.id, entityRef: entityRef, ifcClass: ifcClass, semanticType: semanticType, roomID: room.id, hostID: nil,
                                      sourceDimensions: ["Width": component.width,"Depth": component.depth,"Height": component.height])
            }
        }

        // Openings are emitted after all walls exist so host relationships are explicit.
        for room in ordering.rooms {
            // v12.7 door swings are written by the IFC convention: the door opens towards its local +y.
            let roomBoundary = ArchitecturalRoomEnvelope.polygon(for: room, topology: semanticGeometry.topology)
            for opening in room.openings.sorted(by: { openingKey($0, room) < openingKey($1, room) }) {
                guard let wall = room.walls.first(where: { $0.id == opening.parameters.hostWallID }),
                      let wallRef = wallRefs[wall.id] else { continue }
                let p = opening.parameters
                let openingPlacement = makeLocalPlacement(
                    &writer,
                    relativeTo: placementRefForEntity(writer: writer, entityRef: wallRef) ?? storeyPlacement,
                    x: p.offsetAlongWall,
                    y: 0,
                    z: p.sillHeight,
                    angleRadians: 0
                )
                let openingRepresentation = makeBoxRepresentation(
                    &writer,
                    context: modelContext,
                    width: max(1, p.width),
                    depth: max(1, wall.thickness + 20),
                    height: max(1, p.height),
                    originMode: .centered
                )
                let semanticType = PlanOpsisExchangeIdentity.semanticType(for: opening)
                let isGenericOpening: Bool
                if case .opening = opening { isGenericOpening = true } else { isGenericOpening = false }
                let voidUUID = isGenericOpening
                    ? opening.id
                    : PlanOpsisExchangeIdentity.derivedUUID(namespace: opening.id, role: "ifc.void")
                let voidGUID = PlanOpsisExchangeIdentity.ifcGlobalID(for: voidUUID)
                // Doors, windows and openings carry their schedule mark (D01, W01, O01) as Name and Tag.
                let mark = schedules.marks[opening.id].map { stepString($0) }
                let tag = mark.map { "'\($0)'" } ?? "$"
                let voidName = isGenericOpening ? (mark ?? "Opening") : mark.map { "\($0) opening" } ?? "Opening"
                let openingRef = writer.add("IFCOPENINGELEMENT('\(voidGUID)',#\(owner),'\(voidName)',$,$,#\(openingPlacement),#\(openingRepresentation),\(isGenericOpening ? tag : "$"),.OPENING.)")
                openingRefs[opening.id] = openingRef
                if isGenericOpening {
                    addIdentityProperties(&writer, owner: owner, semanticID: opening.id, entityRef: openingRef, ifcClass: "IfcOpeningElement", semanticType: semanticType, roomID: room.id, hostID: wall.id)
                } else {
                    addDerivedIdentityProperties(
                        &writer,
                        owner: owner,
                        derivedID: voidUUID,
                        sourceSemanticID: opening.id,
                        entityRef: openingRef,
                        ifcClass: "IfcOpeningElement",
                        semanticType: "void.for.\(semanticType)",
                        roomID: room.id,
                        hostID: wall.id
                    )
                }
                _ = writer.add("IFCRELVOIDSELEMENT('\(relGUID(opening.id, "rel.voids"))',#\(owner),$,$,#\(wallRef),#\(openingRef))")

                switch opening {
                case .opening:
                    objectGlobalIDs[opening.id] = voidGUID
                case .door(let door):
                    let semanticGUID = PlanOpsisExchangeIdentity.ifcGlobalID(for: opening.id)
                    objectGlobalIDs[opening.id] = semanticGUID
                    let inward = ArchitecturalSymbolLibrary.inwardSign(center: wall.start + wall.direction * p.offsetAlongWall, angle: wall.angleRadians, boundary: roomBoundary)
                    let opensIn = door.swing == .leftIn || door.swing == .rightIn
                    // Turned half a turn when the door opens to the wall's right, so +y points the way it opens.
                    let turned = door.swing != .unspecified && (opensIn ? inward : -inward) < 0
                    let fillPlacement = makeLocalPlacement(&writer, relativeTo: openingPlacement, x: 0, y: 0, z: 0, angleRadians: turned ? .pi : 0)
                    let fillRepresentation = makeBoxRepresentation(&writer, context: modelContext, width: max(1, p.width), depth: min(max(30, wall.thickness * 0.25), 60), height: max(1, p.height), originMode: .centered)
                    let operation = ifcDoorOperation(door, turned: turned)
                    let doorRef = writer.add("IFCDOOR('\(semanticGUID)',#\(owner),'\(mark ?? "Door")',$,'\(stepString(PlanOpsisExchangeIdentity.semanticType(for: opening)))',#\(fillPlacement),#\(fillRepresentation),\(tag),\(number(p.height)),\(number(p.width)),.DOOR.,\(operation.type),\(operation.userDefined.map { "'\($0)'" } ?? "$"))")
                    roomContainedRefs[room.id, default: []].append(doorRef)
                    addIdentityProperties(&writer, owner: owner, semanticID: opening.id, entityRef: doorRef, ifcClass: "IfcDoor", semanticType: PlanOpsisExchangeIdentity.semanticType(for: opening), roomID: room.id, hostID: wall.id,
                                          sourceDimensions: ["SillHeight": p.sillHeight], sourceLabels: ["Swing": door.swing.rawValue,"Operation": door.operation.rawValue])
                    _ = writer.add("IFCRELFILLSELEMENT('\(relGUID(opening.id, "rel.fills.door"))',#\(owner),$,$,#\(openingRef),#\(doorRef))")
                    addQuantities(&writer, for: opening.id, entity: doorRef, set: "Qto_DoorBaseQuantities",
                                  [("length", "Width", p.width), ("length", "Height", p.height), ("area", "Area", p.width * p.height)])
                case .window:
                    let semanticGUID = PlanOpsisExchangeIdentity.ifcGlobalID(for: opening.id)
                    objectGlobalIDs[opening.id] = semanticGUID
                    let fillPlacement = makeLocalPlacement(&writer, relativeTo: openingPlacement, x: 0, y: 0, z: 0, angleRadians: 0)
                    let fillRepresentation = makeBoxRepresentation(&writer, context: modelContext, width: max(1, p.width), depth: min(max(30, wall.thickness * 0.25), 60), height: max(1, p.height), originMode: .centered)
                    let windowRef = writer.add("IFCWINDOW('\(semanticGUID)',#\(owner),'\(mark ?? "Window")',$,'\(stepString(PlanOpsisExchangeIdentity.semanticType(for: opening)))',#\(fillPlacement),#\(fillRepresentation),\(tag),\(number(p.height)),\(number(p.width)),.WINDOW.,.NOTDEFINED.,$)")
                    roomContainedRefs[room.id, default: []].append(windowRef)
                    addIdentityProperties(&writer, owner: owner, semanticID: opening.id, entityRef: windowRef, ifcClass: "IfcWindow", semanticType: PlanOpsisExchangeIdentity.semanticType(for: opening), roomID: room.id, hostID: wall.id,
                                          sourceDimensions: ["SillHeight": p.sillHeight], sourceLabels: ["Operation": (opening.windowOperation ?? .fixed).rawValue])
                    _ = writer.add("IFCRELFILLSELEMENT('\(relGUID(opening.id, "rel.fills.window"))',#\(owner),$,$,#\(openingRef),#\(windowRef))")
                    addQuantities(&writer, for: opening.id, entity: windowRef, set: "Qto_WindowBaseQuantities",
                                  [("length", "Width", p.width), ("length", "Height", p.height), ("area", "Area", p.width * p.height)])
                }
            }
        }

        if !storeyContainedRefs.isEmpty {
            let refs = storeyContainedRefs.map { "#\($0)" }.joined(separator: ",")
            _ = writer.add("IFCRELCONTAINEDINSPATIALSTRUCTURE('\(relGUID(project.id, "rel.storey.contains"))',#\(owner),$,$,(\(refs)),#\(storeyRef))")
        }
        for room in ordering.rooms {
            guard let spaceRef = spaceRefs[room.id], let refsForRoom = roomContainedRefs[room.id], !refsForRoom.isEmpty else { continue }
            let refs = refsForRoom.map { "#\($0)" }.joined(separator: ",")
            _ = writer.add("IFCRELCONTAINEDINSPATIALSTRUCTURE('\(relGUID(room.id, "rel.space.contains"))',#\(owner),$,$,(\(refs)),#\(spaceRef))")
        }

        return IFC4ExportResult(text: writer.render(), issues: issues, objectGlobalIDs: objectGlobalIDs)
    }

    private func validate(project: PlanOpsisProject) -> [IFC4ExportIssue] {
        var issues: [IFC4ExportIssue] = ExchangeGeometryValidation.errors(in: project).map { .init(.error, $0) }
        if project.rooms.isEmpty { issues.append(.init(.error, "Project has no rooms to export.")) }

        var seen = Set<UUID>()
        func checkID(_ id: UUID, label: String) {
            if !seen.insert(id).inserted { issues.append(.init(.error, "Duplicate semantic UUID detected for \(label): \(id.uuidString).")) }
        }
        checkID(project.id, label: "project")
        for room in project.rooms {
            checkID(room.id, label: "room")
            for wall in room.walls {
                checkID(wall.id, label: "wall")
                if !wall.start.x.isFinite || !wall.start.y.isFinite || !wall.length.isFinite || !wall.angleRadians.isFinite || !wall.height.isFinite || !wall.thickness.isFinite {
                    issues.append(.init(.error, "Wall \(wall.id.uuidString) contains non-finite geometry."))
                }
                if wall.length <= 0 || wall.height <= 0 || wall.thickness <= 0 {
                    issues.append(.init(.error, "Wall \(wall.id.uuidString) has zero/negative length, height, or thickness."))
                }
            }
            let wallIDs = Set(room.walls.map(\.id))
            for opening in room.openings {
                checkID(opening.id, label: "opening")
                let p = opening.parameters
                if !wallIDs.contains(p.hostWallID) { issues.append(.init(.error, "Opening \(opening.id.uuidString) references a missing host wall.")) }
                if p.width <= 0 || p.height <= 0 { issues.append(.init(.error, "Opening \(opening.id.uuidString) has zero/negative dimensions.")) }
                if !p.offsetAlongWall.isFinite || !p.width.isFinite || !p.height.isFinite || !p.sillHeight.isFinite {
                    issues.append(.init(.error, "Opening \(opening.id.uuidString) contains non-finite geometry."))
                }
            }
            for component in room.components {
                checkID(component.id, label: "component")
                if !component.position.x.isFinite || !component.position.y.isFinite || !component.width.isFinite || !component.depth.isFinite || !component.height.isFinite || !component.rotationRadians.isFinite || !component.baseElevationMM.isFinite {
                    issues.append(.init(.error, "Component \(component.id.uuidString) contains non-finite geometry."))
                }
            }
        }
        return issues
    }

    // MARK: STEP / IFC helpers

    private enum BoxOriginMode { case centered, startCenteredDepth }

    private func makeOwnerHistory(_ writer: inout STEPWriter) -> Int {
        let person = writer.add("IFCPERSON($,$,'PlanOpsis',$,$,$,$,$)")
        let org = writer.add("IFCORGANIZATION($,'PlanOpsis',$,$,$)")
        let personOrg = writer.add("IFCPERSONANDORGANIZATION(#\(person),#\(org),$)")
        let app = writer.add("IFCAPPLICATION(#\(org),'12.2.0','PlanOpsis','PLANOPSIS')")
        return writer.add("IFCOWNERHISTORY(#\(personOrg),#\(app),$,.ADDED.,0,$,$,0)")
    }

    private func makeModelContext(_ writer: inout STEPWriter) -> Int {
        let origin = writer.add("IFCCARTESIANPOINT((0.,0.,0.))")
        let wcs = writer.add("IFCAXIS2PLACEMENT3D(#\(origin),$,$)")
        let north = writer.add("IFCDIRECTION((0.,1.))")
        return writer.add("IFCGEOMETRICREPRESENTATIONCONTEXT($,'Model',3,1.E-5,#\(wcs),#\(north))")
    }

    private func makeUnits(_ writer: inout STEPWriter) -> Int {
        let length = writer.add("IFCSIUNIT(*,.LENGTHUNIT.,.MILLI.,.METRE.)")
        let area = writer.add("IFCSIUNIT(*,.AREAUNIT.,$,.SQUARE_METRE.)")
        let volume = writer.add("IFCSIUNIT(*,.VOLUMEUNIT.,$,.CUBIC_METRE.)")
        let angle = writer.add("IFCSIUNIT(*,.PLANEANGLEUNIT.,$,.RADIAN.)")
        return writer.add("IFCUNITASSIGNMENT((#\(length),#\(area),#\(volume),#\(angle)))")
    }

    private func makeLocalPlacement(
        _ writer: inout STEPWriter,
        relativeTo: Int?,
        x: Double,
        y: Double,
        z: Double,
        angleRadians: Double
    ) -> Int {
        let point = writer.add("IFCCARTESIANPOINT((\(number(x)),\(number(y)),\(number(z))))")
        let zAxis = writer.add("IFCDIRECTION((0.,0.,1.))")
        let refDirection = writer.add("IFCDIRECTION((\(number(cos(angleRadians))),\(number(sin(angleRadians))),0.))")
        let axis = writer.add("IFCAXIS2PLACEMENT3D(#\(point),#\(zAxis),#\(refDirection))")
        let parent = relativeTo.map { "#\($0)" } ?? "$"
        return writer.add("IFCLOCALPLACEMENT(\(parent),#\(axis))")
    }

    private func makeBoxRepresentation(
        _ writer: inout STEPWriter,
        context: Int,
        width: Double,
        depth: Double,
        height: Double,
        originMode: BoxOriginMode
    ) -> Int {
        let profileOriginX = originMode == .startCenteredDepth ? width * 0.5 : 0
        let p2d = writer.add("IFCCARTESIANPOINT((\(number(profileOriginX)),0.))")
        let a2d = writer.add("IFCAXIS2PLACEMENT2D(#\(p2d),$)")
        let profile = writer.add("IFCRECTANGLEPROFILEDEF(.AREA.,$,#\(a2d),\(number(width)),\(number(depth)))")
        let origin = writer.add("IFCCARTESIANPOINT((0.,0.,0.))")
        let position = writer.add("IFCAXIS2PLACEMENT3D(#\(origin),$,$)")
        let direction = writer.add("IFCDIRECTION((0.,0.,1.))")
        let solid = writer.add("IFCEXTRUDEDAREASOLID(#\(profile),#\(position),#\(direction),\(number(height)))")
        let shape = writer.add("IFCSHAPEREPRESENTATION(#\(context),'Body','SweptSolid',(#\(solid)))")
        return writer.add("IFCPRODUCTDEFINITIONSHAPE($,$,(#\(shape)))")
    }

    private func makeSpaceRepresentation(_ writer: inout STEPWriter, context: Int, boundary: [Point2D], height: Double) -> Int {
        guard boundary.count >= 3 else {
            return makeBoxRepresentation(&writer, context: context, width: 1, depth: 1, height: height, originMode: .centered)
        }
        var pointRefs: [Int] = boundary.map { point in
            writer.add("IFCCARTESIANPOINT((\(number(point.x)),\(number(point.y))))")
        }
        if let first = pointRefs.first { pointRefs.append(first) }
        let polyline = writer.add("IFCPOLYLINE((\(pointRefs.map { "#\($0)" }.joined(separator: ","))))")
        let profile = writer.add("IFCARBITRARYCLOSEDPROFILEDEF(.AREA.,$,#\(polyline))")
        let origin = writer.add("IFCCARTESIANPOINT((0.,0.,0.))")
        let position = writer.add("IFCAXIS2PLACEMENT3D(#\(origin),$,$)")
        let direction = writer.add("IFCDIRECTION((0.,0.,1.))")
        let solid = writer.add("IFCEXTRUDEDAREASOLID(#\(profile),#\(position),#\(direction),\(number(height)))")
        let shape = writer.add("IFCSHAPEREPRESENTATION(#\(context),'Body','SweptSolid',(#\(solid)))")
        return writer.add("IFCPRODUCTDEFINITIONSHAPE($,$,(#\(shape)))")
    }

    private func addIdentityProperties(
        _ writer: inout STEPWriter,
        owner: Int,
        semanticID: UUID,
        entityRef: Int,
        ifcClass: String,
        semanticType: String,
        roomID: UUID?,
        hostID: UUID?,
        sourceDimensions: [String: Double] = [:],
        sourceLabels: [String: String] = [:]
    ) {
        let uuidProp = writer.add("IFCPROPERTYSINGLEVALUE('PlanOpsisUUID',$,IFCLABEL('\(stepString(semanticID.uuidString))'),$)")
        let classProp = writer.add("IFCPROPERTYSINGLEVALUE('IFCClass',$,IFCLABEL('\(stepString(ifcClass))'),$)")
        let typeProp = writer.add("IFCPROPERTYSINGLEVALUE('SemanticType',$,IFCLABEL('\(stepString(semanticType))'),$)")
        var props = [uuidProp, classProp, typeProp]
        if let roomID {
            props.append(writer.add("IFCPROPERTYSINGLEVALUE('PlanOpsisRoomUUID',$,IFCLABEL('\(stepString(roomID.uuidString))'),$)"))
        }
        if let hostID {
            props.append(writer.add("IFCPROPERTYSINGLEVALUE('HostWallUUID',$,IFCLABEL('\(stepString(hostID.uuidString))'),$)"))
        }
        for name in sourceDimensions.keys.sorted() {
            props.append(writer.add("IFCPROPERTYSINGLEVALUE('\(stepString(name))',$,IFCLENGTHMEASURE(\(number(sourceDimensions[name]!))),$)"))
        }
        for name in sourceLabels.keys.sorted() {
            props.append(writer.add("IFCPROPERTYSINGLEVALUE('\(stepString(name))',$,IFCLABEL('\(stepString(sourceLabels[name]!))'),$)"))
        }
        let psetGUID = PlanOpsisExchangeIdentity.ifcGlobalID(namespace: semanticID, role: "pset.identity.\(ifcClass)")
        let pset = writer.add("IFCPROPERTYSET('\(psetGUID)',#\(owner),'Pset_PlanOpsisIdentity',$,(\(props.map { "#\($0)" }.joined(separator: ","))))")
        let relationGUID = PlanOpsisExchangeIdentity.ifcGlobalID(namespace: semanticID, role: "rel.identity.\(ifcClass)")
        _ = writer.add("IFCRELDEFINESBYPROPERTIES('\(relationGUID)',#\(owner),$,$,(#\(entityRef)),#\(pset))")
    }

    /// IFC child placement for openings must reference the wall's IfcLocalPlacement rather than
    /// the IfcWall entity itself. The STEP writer remembers object placement handles by entity.
    private func addDerivedIdentityProperties(
        _ writer: inout STEPWriter,
        owner: Int,
        derivedID: UUID,
        sourceSemanticID: UUID,
        entityRef: Int,
        ifcClass: String,
        semanticType: String,
        roomID: UUID?,
        hostID: UUID?
    ) {
        let derivedProp = writer.add("IFCPROPERTYSINGLEVALUE('PlanOpsisDerivedUUID',$,IFCLABEL('\(stepString(derivedID.uuidString))'),$)")
        let sourceProp = writer.add("IFCPROPERTYSINGLEVALUE('DerivedFromPlanOpsisUUID',$,IFCLABEL('\(stepString(sourceSemanticID.uuidString))'),$)")
        let classProp = writer.add("IFCPROPERTYSINGLEVALUE('IFCClass',$,IFCLABEL('\(stepString(ifcClass))'),$)")
        let typeProp = writer.add("IFCPROPERTYSINGLEVALUE('SemanticType',$,IFCLABEL('\(stepString(semanticType))'),$)")
        var props = [derivedProp, sourceProp, classProp, typeProp]
        if let roomID {
            props.append(writer.add("IFCPROPERTYSINGLEVALUE('PlanOpsisRoomUUID',$,IFCLABEL('\(stepString(roomID.uuidString))'),$)"))
        }
        if let hostID {
            props.append(writer.add("IFCPROPERTYSINGLEVALUE('HostWallUUID',$,IFCLABEL('\(stepString(hostID.uuidString))'),$)"))
        }
        let psetGUID = PlanOpsisExchangeIdentity.ifcGlobalID(namespace: derivedID, role: "pset.derived.identity.\(ifcClass)")
        let pset = writer.add("IFCPROPERTYSET('\(psetGUID)',#\(owner),'Pset_PlanOpsisDerivedIdentity',$,(\(props.map { "#\($0)" }.joined(separator: ","))))")
        let relationGUID = PlanOpsisExchangeIdentity.ifcGlobalID(namespace: derivedID, role: "rel.derived.identity.\(ifcClass)")
        _ = writer.add("IFCRELDEFINESBYPROPERTIES('\(relationGUID)',#\(owner),$,$,(#\(entityRef)),#\(pset))")
    }

    private func placementRefForEntity(writer: STEPWriter, entityRef: Int) -> Int? {
        writer.entityPlacement[entityRef]
    }

    /// IFC door operation: the hinge (or slide) side as seen looking along the door's +y, which
    /// `turned` reverses against the wall's direction. PlanOpsis "left" is the wall's start side.
    private func ifcDoorOperation(_ door: PlanOpsisDoor, turned: Bool) -> (type: String, userDefined: String?) {
        let startSide = door.swing == .leftIn || door.swing == .leftOut
        let left = startSide != turned
        switch door.operation {
        case .singleHinged:
            if door.swing == .unspecified { return (".NOTDEFINED.", nil) }
            return (left ? ".SINGLE_SWING_LEFT." : ".SINGLE_SWING_RIGHT.", nil)
        case .doubleHinged:
            return (".DOUBLE_DOOR_SINGLE_SWING.", nil)
        case .sliding:
            if door.swing == .unspecified { return (".SLIDING_TO_LEFT.", nil) }
            return (left ? ".SLIDING_TO_LEFT." : ".SLIDING_TO_RIGHT.", nil)
        case .pocket:
            return (".USERDEFINED.", "POCKET")
        }
    }

    private func relGUID(_ namespace: UUID, _ role: String) -> String {
        PlanOpsisExchangeIdentity.ifcGlobalID(namespace: namespace, role: role)
    }

    private func number(_ value: Double) -> String {
        if !value.isFinite { return "0." }
        if abs(value.rounded() - value) < 1e-9 { return "\(Int(value.rounded()))." }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// STEP string payload (without surrounding quotes), including ISO-10303-21 Unicode escaping.
    private func stepString(_ value: String) -> String {
        var result = ""
        var unicodeBuffer = ""
        func flushUnicode() {
            guard !unicodeBuffer.isEmpty else { return }
            result += "\\X2\\\(unicodeBuffer)\\X0\\"
            unicodeBuffer = ""
        }
        for unit in value.utf16 {
            if unit >= 32 && unit <= 126 {
                flushUnicode()
                let scalar = UnicodeScalar(Int(unit))!
                if unit == 39 { result += "''" }
                else if unit == 92 { result += "\\\\" }
                else { result.append(Character(scalar)) }
            } else {
                unicodeBuffer += String(format: "%04X", unit)
            }
        }
        flushUnicode()
        return result
    }
}

private struct STEPWriter {
    private(set) var records: [String] = []
    private(set) var entityPlacement: [Int: Int] = [:]

    mutating func add(_ body: String) -> Int {
        let id = records.count + 1
        records.append("#\(id)=\(body);")
        if let placement = parseObjectPlacement(body) { entityPlacement[id] = placement }
        return id
    }

    func render() -> String {
        let header = [
            "ISO-10303-21;",
            "HEADER;",
            "FILE_DESCRIPTION(('PlanOpsis semantic IFC4 export'),'2;1');",
            "FILE_NAME('PlanOpsis-IFC4.ifc','1970-01-01T00:00:00',('PlanOpsis'),('PlanOpsis'),'PlanOpsis','PlanOpsis','');",
            "FILE_SCHEMA(('IFC4'));",
            "ENDSEC;",
            "DATA;"
        ]
        let footer = ["ENDSEC;", "END-ISO-10303-21;"]
        return (header + records + footer).joined(separator: "\r\n") + "\r\n"
    }

    private func parseObjectPlacement(_ body: String) -> Int? {
        let productPrefixes = ["IFCWALL(", "IFCOPENINGELEMENT(", "IFCDOOR(", "IFCWINDOW(", "IFCCOLUMN(", "IFCBEAM(", "IFCFURNISHINGELEMENT(", "IFCSANITARYTERMINAL(", "IFCSPACE(",
                               "IFCELECTRICAPPLIANCE(", "IFCAUDIOVISUALAPPLIANCE(", "IFCSTAIR("]
        guard productPrefixes.contains(where: { body.hasPrefix($0) }) else { return nil }
        // Root4 + ObjectType = five fields; field 6 is ObjectPlacement.
        let fields = splitTopLevelArguments(body)
        guard fields.count >= 6 else { return nil }
        let token = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("#"), let value = Int(token.dropFirst()) else { return nil }
        return value
    }

    private func splitTopLevelArguments(_ body: String) -> [String] {
        guard let open = body.firstIndex(of: "("), let close = body.lastIndex(of: ")"), open < close else { return [] }
        let content = body[body.index(after: open)..<close]
        var result: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        var previous: Character? = nil
        for character in content {
            if character == "'", previous != "'" { quoted.toggle() }
            if !quoted {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if character == ",", depth == 0 {
                    result.append(current)
                    current = ""
                    previous = character
                    continue
                }
            }
            current.append(character)
            previous = character
        }
        result.append(current)
        return result
    }
}
