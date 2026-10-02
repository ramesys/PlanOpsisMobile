import Foundation

public enum CADReadError: Error, LocalizedError, Equatable {
    case empty
    case binaryDXF
    case notDXF

    public var errorDescription: String? {
        switch self {
        case .empty: return "The file is empty."
        case .binaryDXF: return "Binary DXF is not supported. Save the drawing as ASCII DXF and open it again."
        case .notDXF: return "The file is not a DXF drawing."
        }
    }
}

/// One DXF group: a group code and its value line.
public struct CADGroup: Hashable, Sendable {
    public var code: Int
    public var value: String

    public init(_ code: Int, _ value: String) {
        self.code = code
        self.value = value
    }

    var double: Double { Double(value) ?? 0 }
    var int: Int { Int(value) ?? Int(Double(value) ?? 0) }
}

/// v12.3 reader for ASCII DXF (R12 to R2018) into `CADDocument`.
///
/// The reader is tolerant: an entity it cannot interpret is counted in `diagnostics` and skipped, never
/// fatal. Only a file that is not ASCII DXF at all throws.
public struct CADDocumentReader: Sendable {
    public init() {}

    public func read(data: Data) throws -> CADDocument {
        guard !data.isEmpty else { throw CADReadError.empty }
        if data.starts(with: Array("AutoCAD Binary DXF".utf8)) { throw CADReadError.binaryDXF }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        return try read(text: text)
    }

    public func read(text: String) throws -> CADDocument {
        let groups = Self.groups(in: text)
        guard !groups.isEmpty else { throw CADReadError.empty }
        guard groups.contains(where: { $0.code == 0 && ($0.value == "SECTION" || $0.value == "EOF") }) else { throw CADReadError.notDXF }
        var state = ParseState()
        state.parse(groups)
        return state.document()
    }

    /// Splits the file into (code, value) pairs. Lines are trimmed; a non-numeric code line is skipped
    /// with its value so one damaged pair cannot shift the rest of the file.
    static func groups(in text: String) -> [CADGroup] {
        var result: [CADGroup] = []
        var pendingCode: Int?
        var expectCode = true
        result.reserveCapacity(1024)
        text.enumerateLines { line, _ in
            if expectCode {
                pendingCode = Int(line.trimmingCharacters(in: .whitespaces))
                expectCode = false
            } else {
                if let code = pendingCode {
                    // Values keep leading spaces in text but not the trailing CR some writers leave.
                    var value = line
                    while value.hasSuffix("\r") { value.removeLast() }
                    result.append(CADGroup(code, code == 1 || code == 3 || code == 1000 ? value : value.trimmingCharacters(in: .whitespaces)))
                }
                expectCode = true
            }
        }
        return result
    }
}

// MARK: - Parse state

private struct ParseState {
    var version: String?
    var units = CADUnits.unitless
    var layers: [CADLayer] = []
    var blocks: [String: CADBlock] = [:]
    var modelEntities: [CADEntity] = []
    var modelSpaceBlockEntities: [CADEntity] = []
    var diagnostics = CADReadDiagnostics()

    // Block being read in the BLOCKS section; nil outside a block. Paper-space blocks are read and dropped.
    var currentBlock: CADBlock?
    // POLYLINE/VERTEX/SEQEND and INSERT/ATTRIB/SEQEND sequences.
    var pendingPolyline: (record: Record, vertices: [CADVertex])?
    var pendingInsert: (entity: CADEntity, attributes: [CADText])?

    struct Record {
        var type: String
        var groups: ArraySlice<CADGroup>
    }

    mutating func parse(_ groups: [CADGroup]) {
        var section = ""
        var index = 0
        while index < groups.count {
            guard groups[index].code == 0 else { index += 1; continue }
            let type = groups[index].value
            var end = index + 1
            while end < groups.count, groups[end].code != 0 { end += 1 }
            let record = Record(type: type, groups: groups[(index + 1)..<end])
            index = end
            switch type {
            case "SECTION":
                section = record.groups.first { $0.code == 2 }?.value ?? ""
                // HEADER variables have no 0 groups, so they arrive inside the SECTION record itself.
                if section == "HEADER" { readHeader(record) }
                continue
            case "ENDSEC":
                finishSequences()
                section = ""
                continue
            case "EOF":
                break
            default:
                break
            }
            switch section {
            case "TABLES": if type == "LAYER" { readLayer(record) }
            case "BLOCKS": readBlockRecord(record)
            case "ENTITIES": readEntityRecord(record)
            default: break
            }
        }
        finishSequences()
    }

    func document() -> CADDocument {
        var entities = modelEntities
        // Some writers put model space in the *Model_Space block and leave ENTITIES empty.
        if entities.isEmpty { entities = modelSpaceBlockEntities }
        var diagnostics = diagnostics
        diagnostics.missingBlocks = Self.missingBlocks(entities: entities, blocks: blocks)
        return CADDocument(version: version, units: units, layers: layers, blocks: blocks, entities: entities, diagnostics: diagnostics)
    }

    private static func missingBlocks(entities: [CADEntity], blocks: [String: CADBlock]) -> Set<String> {
        var missing = Set<String>()
        var visited = Set<String>()
        func visit(_ list: [CADEntity]) {
            for entity in list {
                guard case let .insert(insert) = entity.geometry else { continue }
                guard let block = blocks[insert.blockName] else { missing.insert(insert.blockName); continue }
                if visited.insert(insert.blockName).inserted { visit(block.entities) }
            }
        }
        visit(entities)
        return missing
    }

    // MARK: Header and tables

    mutating func readHeader(_ record: Record) {
        // The HEADER section is one record of `9 $NAME` groups each followed by its value groups.
        var name = ""
        for group in record.groups {
            if group.code == 9 { name = group.value; continue }
            switch (name, group.code) {
            case ("$ACADVER", 1): version = group.value
            case ("$INSUNITS", 70): units = CADUnits(insunits: group.int)
            default: break
            }
        }
    }

    mutating func readLayer(_ record: Record) {
        let g = GroupReader(record.groups)
        guard let name = g.string(2) else { return }
        let colorNumber = g.int(62) ?? 7
        let flags = g.int(70) ?? 0
        var color = CADColor.aci(abs(colorNumber) == 0 ? 7 : abs(colorNumber))
        if let rgb = g.int(420) { color = CADColor(trueColor: rgb) }
        let layer = CADLayer(
            name: name,
            color: color,
            colorIndex: abs(colorNumber),
            isOn: colorNumber >= 0,
            isFrozen: flags & 1 != 0,
            isLocked: flags & 4 != 0,
            isPlotted: (g.int(290) ?? 1) != 0,
            lineType: g.string(6) ?? "CONTINUOUS",
            lineWeight: g.int(370).map(CADLineWeight.init(code:)) ?? .default
        )
        if let existing = layers.firstIndex(where: { $0.name == name }) { layers[existing] = layer } else { layers.append(layer) }
    }

    // MARK: Blocks

    mutating func readBlockRecord(_ record: Record) {
        switch record.type {
        case "BLOCK":
            finishSequences()
            let g = GroupReader(record.groups)
            currentBlock = CADBlock(name: g.string(2) ?? g.string(3) ?? "", basePoint: g.point(10) ?? .zero)
        case "ENDBLK":
            finishSequences()
            if let block = currentBlock {
                let upper = block.name.uppercased()
                if upper == "*MODEL_SPACE" { modelSpaceBlockEntities = block.entities }
                else if !upper.hasPrefix("*PAPER_SPACE") { blocks[block.name] = block }
            }
            currentBlock = nil
        default:
            readEntityRecord(record)
        }
    }

    // MARK: Entities

    mutating func emit(_ entity: CADEntity) {
        if currentBlock != nil { currentBlock?.entities.append(entity) } else { modelEntities.append(entity) }
    }

    mutating func finishSequences() {
        if let pending = pendingPolyline {
            pendingPolyline = nil
            if let entity = makePolyline(pending.record, vertices: pending.vertices) { emit(entity) }
        }
        if let pending = pendingInsert {
            pendingInsert = nil
            var entity = pending.entity
            if case var .insert(insert) = entity.geometry {
                insert.attributes = pending.attributes
                entity.geometry = .insert(insert)
            }
            emit(entity)
        }
    }

    mutating func readEntityRecord(_ record: Record) {
        switch record.type {
        case "VERTEX":
            guard pendingPolyline != nil else { return }
            let g = GroupReader(record.groups)
            let flags = g.int(70) ?? 0
            // Spline frame control points (16) and polyface face records (128 without 64) are not outline vertices.
            if flags & 16 != 0 || (flags & 128 != 0 && flags & 64 == 0) { return }
            var point = g.point(10) ?? .zero
            var bulge = g.double(42) ?? 0
            if pendingPolyline.map({ Common($0.record.groups).mirrored }) == true { point.x = -point.x; bulge = -bulge }
            pendingPolyline?.vertices.append(CADVertex(point, bulge: bulge))
            return
        case "ATTRIB":
            guard pendingInsert != nil else { return }
            let g = GroupReader(record.groups)
            if (g.int(70) ?? 0) & 1 != 0 { return }
            if let text = makeText(g, common: Common(record.groups), verticalCode: 74), !text.string.isEmpty { pendingInsert?.attributes.append(text) }
            return
        case "SEQEND":
            finishSequences()
            return
        default:
            break
        }
        finishSequences()
        let common = Common(record.groups)
        if common.paperSpace && currentBlock == nil { diagnostics.paperSpaceEntities += 1; return }
        if common.invisible { return }
        let g = GroupReader(record.groups)
        let geometry: CADGeometry?
        switch record.type {
        case "LINE":
            geometry = .line(g.point(10) ?? .zero, g.point(11) ?? .zero)
        case "LWPOLYLINE":
            geometry = makeLightweightPolyline(record.groups, mirrored: common.mirrored)
        case "POLYLINE":
            let flags = g.int(70) ?? 0
            if flags & (16 | 64) != 0 { count("POLYLINE (mesh)"); return }
            pendingPolyline = (record, [])
            return
        case "CIRCLE":
            guard let r = g.double(40), r > 0 else { geometry = nil; break }
            geometry = .circle(center: common.ocs(g.point(10) ?? .zero), radius: r)
        case "ARC":
            guard let r = g.double(40), r > 0 else { geometry = nil; break }
            var start = (g.double(50) ?? 0) * .pi / 180, end = (g.double(51) ?? 0) * .pi / 180
            if common.mirrored { (start, end) = (.pi - end, .pi - start) }
            geometry = .arc(center: common.ocs(g.point(10) ?? .zero), radius: r, startAngle: start, endAngle: end)
        case "ELLIPSE":
            var start = g.double(41) ?? 0, end = g.double(42) ?? (2 * .pi)
            if common.extrusionZ < 0 { (start, end) = (-end, -start) }
            geometry = .ellipse(center: g.point(10) ?? .zero, majorAxis: g.point(11) ?? Point2D(x: 1, y: 0), ratio: g.double(40) ?? 1, startParameter: start, endParameter: end)
        case "SPLINE":
            geometry = makeSpline(record.groups)
        case "TEXT":
            geometry = makeText(g, common: common).map(CADGeometry.text)
        case "MTEXT":
            geometry = makeMText(record.groups, common: common).map(CADGeometry.text)
        case "INSERT":
            guard let name = g.string(2) else { geometry = nil; break }
            let insert = CADInsert(
                blockName: name,
                position: g.point(10) ?? .zero,
                scaleX: g.double(41) ?? 1,
                scaleY: g.double(42) ?? 1,
                rotation: (g.double(50) ?? 0) * .pi / 180,
                columns: g.int(70) ?? 1,
                rows: g.int(71) ?? 1,
                columnSpacing: g.double(44) ?? 0,
                rowSpacing: g.double(45) ?? 0,
                mirrored: common.mirrored
            )
            let entity = makeEntity(record, common: common, geometry: .insert(insert))
            if (g.int(66) ?? 0) == 1 { pendingInsert = (entity, []) } else { emit(entity) }
            return
        case "DIMENSION":
            geometry = makeDimension(g)
        case "HATCH":
            var reader = CADHatchReader(record.groups, mirrored: common.mirrored)
            geometry = reader.read().map(CADGeometry.hatch)
        case "SOLID", "TRACE":
            let p = [g.point(10), g.point(11), g.point(13), g.point(12)].compactMap { $0 }.map(common.ocs)
            geometry = p.count >= 3 ? .filledPolygon(Self.removeRepeated(p)) : nil
        case "3DFACE":
            let p = [g.point(10), g.point(11), g.point(12), g.point(13)].compactMap { $0 }
            geometry = p.count >= 3 ? .filledPolygon(Self.removeRepeated(p)) : nil
        case "POINT":
            geometry = .point(g.point(10) ?? .zero)
        case "LEADER":
            let points = g.points(10)
            geometry = points.count >= 2 ? .leader(points) : nil
        case "ATTDEF":
            // Attribute definitions are templates; their values arrive as ATTRIB on each insert.
            return
        case "VIEWPORT":
            return
        default:
            count(record.type)
            return
        }
        if let geometry { emit(makeEntity(record, common: common, geometry: geometry)) }
    }

    mutating func count(_ type: String) {
        diagnostics.unsupportedEntities[type, default: 0] += 1
    }

    func makeEntity(_ record: Record, common: Common, geometry: CADGeometry) -> CADEntity {
        CADEntity(
            type: record.type,
            handle: common.handle,
            layer: common.layer,
            color: common.color,
            lineWeight: common.lineWeight,
            lineType: common.lineType,
            geometry: geometry,
            xdata: common.xdata
        )
    }

    func makePolyline(_ record: Record, vertices: [CADVertex]) -> CADEntity? {
        guard vertices.count >= 2 else { return nil }
        let common = Common(record.groups)
        let flags = GroupReader(record.groups).int(70) ?? 0
        return makeEntity(record, common: common, geometry: .polyline(CADPolyline(vertices: vertices, closed: flags & 1 != 0)))
    }

    func makeLightweightPolyline(_ groups: ArraySlice<CADGroup>, mirrored: Bool) -> CADGeometry? {
        var vertices: [CADVertex] = []
        var x: Double?
        var flags = 0
        var sawFirstVertex = false
        for group in groups {
            switch group.code {
            case 70 where !sawFirstVertex: flags = group.int
            case 10:
                x = group.double
                sawFirstVertex = true
            case 20:
                if let px = x { vertices.append(CADVertex(Point2D(x: mirrored ? -px : px, y: group.double))); x = nil }
            case 42:
                if !vertices.isEmpty { vertices[vertices.count - 1].bulge = mirrored ? -group.double : group.double }
            default: break
            }
        }
        guard vertices.count >= 2 else { return nil }
        return .polyline(CADPolyline(vertices: vertices, closed: flags & 1 != 0))
    }

    func makeSpline(_ groups: ArraySlice<CADGroup>) -> CADGeometry? {
        let g = GroupReader(groups)
        let flags = g.int(70) ?? 0
        let degree = g.int(71) ?? 3
        let knots = groups.filter { $0.code == 40 }.map(\.double)
        let weights = groups.filter { $0.code == 41 }.map(\.double)
        let control = g.points(10)
        let fit = g.points(11)
        guard control.count >= 2 || fit.count >= 2 else { return nil }
        return .spline(CADSpline(degree: max(1, degree), knots: knots, controlPoints: control, weights: weights, fitPoints: fit, closed: flags & 1 != 0))
    }

    /// TEXT keeps its vertical alignment in group 73; ATTRIB uses 74 (its 73 is the field length).
    func makeText(_ g: GroupReader, common: Common, verticalCode: Int = 73) -> CADText? {
        guard let raw = g.string(1) else { return nil }
        let horizontal = g.int(72) ?? 0
        let vertical = g.int(verticalCode) ?? 0
        let usesAlignmentPoint = (horizontal != 0 || vertical != 0) && horizontal != 3 && horizontal != 5 && g.point(11) != nil
        var position = usesAlignmentPoint ? (g.point(11) ?? .zero) : (g.point(10) ?? .zero)
        var rotation = (g.double(50) ?? 0) * .pi / 180
        if horizontal == 3 || horizontal == 5, let a = g.point(10), let b = g.point(11), (b - a).length > 1e-9 {
            // Aligned and fit text run from the first to the second point.
            position = a
            rotation = atan2(b.y - a.y, b.x - a.x)
        }
        position = common.ocs(position)
        let h: CADTextHorizontalAlignment
        var v: CADTextVerticalAlignment
        switch horizontal {
        case 1, 4: h = .center
        case 2: h = .right
        default: h = .left
        }
        switch vertical {
        case 1: v = .bottom
        case 2: v = .middle
        case 3: v = .top
        default: v = .baseline
        }
        if horizontal == 4 { v = .middle }
        return CADText(
            position: position,
            height: max(1e-6, g.double(40) ?? 1),
            rotation: rotation,
            string: CADTextFormatting.plainText(raw),
            horizontal: h,
            vertical: v,
            widthFactor: g.double(41) ?? 1
        )
    }

    func makeMText(_ groups: ArraySlice<CADGroup>, common: Common) -> CADText? {
        let g = GroupReader(groups)
        let raw = groups.filter { $0.code == 3 }.map(\.value).joined() + (g.string(1) ?? "")
        guard !raw.isEmpty else { return nil }
        let attachment = g.int(71) ?? 1
        var rotation = (g.double(50) ?? 0) * .pi / 180
        if let direction = g.point(11), direction.length > 1e-9 { rotation = atan2(direction.y, direction.x) }
        let h: CADTextHorizontalAlignment = [1, 4, 7].contains(attachment) ? .left : ([2, 5, 8].contains(attachment) ? .center : .right)
        let v: CADTextVerticalAlignment = attachment <= 3 ? .top : (attachment <= 6 ? .middle : .bottom)
        return CADText(
            position: g.point(10) ?? .zero,
            height: max(1e-6, g.double(40) ?? 1),
            rotation: rotation,
            string: CADTextFormatting.plainMText(raw),
            horizontal: h,
            vertical: v
        )
    }

    func makeDimension(_ g: GroupReader) -> CADGeometry? {
        let flags = g.int(70) ?? 0
        let kind = CADDimensionKind(rawValue: flags & 7) ?? .linear
        return .dimension(CADDimension(
            kind: kind,
            blockName: g.string(2),
            dimensionLinePoint: g.point(10) ?? .zero,
            textPoint: g.point(11) ?? (g.point(10) ?? .zero),
            firstPoint: g.point(13) ?? g.point(15),
            secondPoint: g.point(14) ?? g.point(10),
            rotation: (g.double(50) ?? 0) * .pi / 180,
            measurement: g.double(42),
            textOverride: g.string(1).map(CADTextFormatting.plainMText)
        ))
    }

    static func removeRepeated(_ points: [Point2D]) -> [Point2D] {
        var result: [Point2D] = []
        for p in points where result.last.map({ ($0 - p).length > 1e-9 }) ?? true { result.append(p) }
        if result.count > 2, let first = result.first, let last = result.last, (first - last).length <= 1e-9 { result.removeLast() }
        return result
    }
}

// MARK: - Group helpers

/// First-occurrence accessors over one record's groups. XDATA (codes ≥ 1000) never shadows entity data.
struct GroupReader {
    let groups: ArraySlice<CADGroup>

    init(_ groups: ArraySlice<CADGroup>) { self.groups = groups }

    func string(_ code: Int) -> String? { groups.first { $0.code == code }?.value }
    func double(_ code: Int) -> Double? { string(code).flatMap(Double.init) }
    func int(_ code: Int) -> Int? { string(code).flatMap { Int($0) ?? Double($0).map { Int($0) } } }

    /// The point whose X is group `code` and Y is `code + 10`, taken from adjacent groups.
    func point(_ code: Int) -> Point2D? {
        guard let i = groups.firstIndex(where: { $0.code == code }), let x = Double(groups[i].value) else { return nil }
        var j = i + 1
        while j < groups.endIndex, j <= i + 2 {
            if groups[j].code == code + 10, let y = Double(groups[j].value) { return Point2D(x: x, y: y) }
            j += 1
        }
        return Point2D(x: x, y: 0)
    }

    /// Every X/Y pair of group `code`, in order.
    func points(_ code: Int) -> [Point2D] {
        var result: [Point2D] = []
        var x: Double?
        for group in groups {
            if group.code == code { x = Double(group.value) }
            else if group.code == code + 10, let px = x { result.append(Point2D(x: px, y: Double(group.value) ?? 0)); x = nil }
        }
        return result
    }
}

/// Groups common to every entity.
struct Common {
    var handle: String?
    var layer = "0"
    var color = CADColorReference.byLayer
    var lineWeight = CADLineWeight.byLayer
    var lineType: String?
    var paperSpace = false
    var invisible = false
    var extrusionZ = 1.0
    var xdata: [String: [String]] = [:]

    init(_ groups: ArraySlice<CADGroup>) {
        var app: String?
        var trueColor: Int?
        var colorIndex: Int?
        for group in groups {
            if group.code >= 1000 {
                if group.code == 1001 { app = group.value; xdata[group.value, default: []] = [] }
                else if let app { xdata[app, default: []].append(group.value) }
                continue
            }
            switch group.code {
            case 5: if handle == nil { handle = group.value }
            case 8: layer = group.value
            case 6: lineType = group.value
            case 62: colorIndex = group.int
            case 420: trueColor = group.int
            case 370: lineWeight = CADLineWeight(code: group.int)
            case 67: paperSpace = group.int == 1
            case 60: invisible = group.int == 1
            case 230: extrusionZ = group.double
            default: break
            }
        }
        if let trueColor { color = .rgb(CADColor(trueColor: trueColor)) }
        else if let colorIndex {
            switch colorIndex {
            case 0: color = .byBlock
            case 256: color = .byLayer
            default: color = .index(abs(colorIndex))
            }
        }
    }

    /// Extrusion (0, 0, -1): object coordinates are mirrored in X relative to the drawing.
    var mirrored: Bool { extrusionZ < 0 }

    func ocs(_ p: Point2D) -> Point2D { mirrored ? Point2D(x: -p.x, y: p.y) : p }
}

// MARK: - HATCH

/// Sequential reader for HATCH boundary paths and pattern lines, whose meaning depends on group order.
private struct CADHatchReader {
    let groups: [CADGroup]
    let mirrored: Bool
    var index = 0

    init(_ groups: ArraySlice<CADGroup>, mirrored: Bool) {
        self.groups = Array(groups.prefix { $0.code < 1000 })
        self.mirrored = mirrored
    }

    mutating func read() -> CADHatch? {
        var name = ""
        var solid = false
        var loops: [CADPolyline] = []
        var pattern: [CADHatchPatternLine] = []
        while index < groups.count {
            let group = groups[index]
            index += 1
            switch group.code {
            case 2: name = group.value
            case 70: solid = group.int == 1
            case 91:
                for _ in 0..<max(0, group.int) {
                    guard let loop = readPath() else { break }
                    if loop.vertices.count >= 2 { loops.append(loop) }
                }
            case 78:
                for _ in 0..<max(0, group.int) {
                    guard let line = readPatternLine() else { break }
                    pattern.append(line)
                }
            case 98:
                // Seed points end the useful data.
                index = groups.count
            default: break
            }
        }
        guard !loops.isEmpty else { return nil }
        if mirrored {
            loops = loops.map { CADPolyline(vertices: $0.vertices.map { CADVertex(Point2D(x: -$0.point.x, y: $0.point.y), bulge: -$0.bulge) }, closed: $0.closed) }
            pattern = pattern.map {
                CADHatchPatternLine(angle: .pi - $0.angle, basePoint: Point2D(x: -$0.basePoint.x, y: $0.basePoint.y), offset: Point2D(x: -$0.offset.x, y: $0.offset.y), dashes: $0.dashes)
            }
        }
        return CADHatch(patternName: name, isSolid: solid, loops: loops, patternLines: pattern)
    }

    mutating func take(_ code: Int) -> CADGroup? {
        guard index < groups.count, groups[index].code == code else { return nil }
        index += 1
        return groups[index - 1]
    }

    mutating func takePoint(_ code: Int) -> Point2D? {
        guard let x = take(code) else { return nil }
        let y = take(code + 10)
        return Point2D(x: x.double, y: y?.double ?? 0)
    }

    mutating func readPath() -> CADPolyline? {
        guard let flags = take(92)?.int else { return nil }
        var vertices: [CADVertex] = []
        if flags & 2 != 0 {
            _ = take(72) // has-bulge flag; a 42 group after a vertex is read either way
            _ = take(73)
            let count = take(93)?.int ?? 0
            for _ in 0..<max(0, count) {
                guard let p = takePoint(10) else { break }
                vertices.append(CADVertex(p, bulge: take(42)?.double ?? 0))
            }
        } else {
            let edges = take(93)?.int ?? 0
            for _ in 0..<max(0, edges) {
                guard let type = take(72)?.int else { break }
                switch type {
                case 1:
                    guard let a = takePoint(10) else { return nil }
                    _ = takePoint(11)
                    vertices.append(CADVertex(a))
                case 2:
                    guard let c = takePoint(10) else { return nil }
                    let r = take(40)?.double ?? 0
                    let s = take(50)?.double ?? 0, e = take(51)?.double ?? 360
                    let ccw = (take(73)?.int ?? 1) != 0
                    vertices.append(contentsOf: Self.arcVertices(center: c, radius: r, startDegrees: s, endDegrees: e, ccw: ccw))
                case 3:
                    guard let c = takePoint(10), let major = takePoint(11) else { return nil }
                    let ratio = take(40)?.double ?? 1
                    var s = (take(50)?.double ?? 0) * .pi / 180, e = (take(51)?.double ?? 360) * .pi / 180
                    let ccw = (take(73)?.int ?? 1) != 0
                    if !ccw { (s, e) = (-s, -e) }
                    let points = CADTessellation.ellipse(center: c, majorAxis: major, ratio: ratio, start: s, end: e, clockwise: !ccw)
                    vertices.append(contentsOf: points.dropLast().map { CADVertex($0) })
                case 4:
                    let degree = take(94)?.int ?? 3
                    let rational = (take(73)?.int ?? 0) != 0
                    _ = take(74)
                    let knotCount = take(95)?.int ?? 0
                    let controlCount = take(96)?.int ?? 0
                    var knots: [Double] = []
                    for _ in 0..<max(0, knotCount) { if let k = take(40) { knots.append(k.double) } }
                    var control: [Point2D] = [], weights: [Double] = []
                    for _ in 0..<max(0, controlCount) {
                        guard let p = takePoint(10) else { break }
                        control.append(p)
                        if rational, let w = take(42) { weights.append(w.double) }
                    }
                    var fit: [Point2D] = []
                    let mark = index
                    if let fitCount = take(97)?.int {
                        for _ in 0..<max(0, fitCount) { if let p = takePoint(11) { fit.append(p) } }
                        if fitCount > 0 && fit.isEmpty { index = mark } // it was the source-object count
                        else { _ = takePoint(12); _ = takePoint(13) }
                    }
                    let spline = CADSpline(degree: degree, knots: knots, controlPoints: control, weights: weights, fitPoints: fit)
                    vertices.append(contentsOf: CADTessellation.spline(spline).dropLast().map { CADVertex($0) })
                default:
                    return nil
                }
            }
        }
        if let sources = take(97)?.int {
            for _ in 0..<max(0, sources) { _ = take(330) }
        }
        return CADPolyline(vertices: vertices, closed: true)
    }

    mutating func readPatternLine() -> CADHatchPatternLine? {
        guard let angle = take(53)?.double else { return nil }
        let base = Point2D(x: take(43)?.double ?? 0, y: take(44)?.double ?? 0)
        let offset = Point2D(x: take(45)?.double ?? 0, y: take(46)?.double ?? 0)
        let count = take(79)?.int ?? 0
        var dashes: [Double] = []
        for _ in 0..<max(0, count) { if let d = take(49) { dashes.append(d.double) } }
        return CADHatchPatternLine(angle: angle * .pi / 180, basePoint: base, offset: offset, dashes: dashes)
    }

    /// A hatch arc edge as bulge vertices. Clockwise edges store their angles negated (360 − angle).
    static func arcVertices(center: Point2D, radius: Double, startDegrees: Double, endDegrees: Double, ccw: Bool) -> [CADVertex] {
        guard radius > 0 else { return [] }
        var sweep = (endDegrees - startDegrees).truncatingRemainder(dividingBy: 360)
        if sweep <= 1e-9 { sweep += 360 }
        let start = (ccw ? startDegrees : -startDegrees) * .pi / 180
        let direction: Double = ccw ? 1 : -1
        // Split into pieces of at most 180° so every bulge stays finite.
        let pieces = Int((sweep / 180).rounded(.up))
        let step = sweep / Double(pieces) * .pi / 180
        return (0..<pieces).map { i in
            let a = start + direction * step * Double(i)
            return CADVertex(Point2D(x: center.x + radius * cos(a), y: center.y + radius * sin(a)), bulge: direction * tan(step / 4))
        }
    }
}

// MARK: - Text formatting

public enum CADTextFormatting {
    /// TEXT control codes: %%c (diameter), %%d (degree), %%p (plus/minus), %%nnn, underline/overline toggles.
    public static func plainText(_ raw: String) -> String {
        var source = DXFTextCodec.decode(raw)
        guard source.contains("%%") else { return source }
        var result = ""
        while let range = source.range(of: "%%") {
            result += source[..<range.lowerBound]
            var rest = source[range.upperBound...]
            guard let code = rest.first else { source = ""; break }
            switch code.lowercased() {
            case "c": result += "⌀"; rest.removeFirst()
            case "d": result += "°"; rest.removeFirst()
            case "p": result += "±"; rest.removeFirst()
            case "%": result += "%"; rest.removeFirst()
            case "u", "o", "k": rest.removeFirst()
            default:
                let digits = rest.prefix(3)
                if digits.count == 3, let value = UInt32(digits), let scalar = UnicodeScalar(value) {
                    result.append(Character(scalar)); rest.removeFirst(3)
                } else {
                    result += "%%"
                }
            }
            source = String(rest)
        }
        return result + source
    }

    /// Removes MTEXT inline formatting: fonts, heights, colours and toggles go, \P becomes a newline,
    /// stacked fractions become "a/b", and escaped braces/backslashes are kept literally.
    public static func plainMText(_ raw: String) -> String {
        let chars = Array(DXFTextCodec.decode(raw))
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" || c == "}" { i += 1; continue }
            guard c == "\\", i + 1 < chars.count else { out.append(c); i += 1; continue }
            let code = chars[i + 1]
            i += 2
            switch code {
            case "P", "N", "X": out.append("\n")
            case "~": out.append(" ")
            case "\\", "{", "}": out.append(code)
            case "L", "l", "O", "o", "K", "k": break
            case "S":
                var stacked = ""
                while i < chars.count, chars[i] != ";" { stacked.append(chars[i]); i += 1 }
                i += 1
                out += stacked.replacingOccurrences(of: "^", with: "/").replacingOccurrences(of: "#", with: "/").replacingOccurrences(of: " ", with: "")
            case "f", "F", "H", "h", "W", "w", "Q", "q", "T", "t", "A", "a", "C", "c", "p":
                while i < chars.count, chars[i] != ";" { i += 1 }
                i += 1
            default:
                out.append(code)
            }
        }
        return plainText(out)
    }
}
