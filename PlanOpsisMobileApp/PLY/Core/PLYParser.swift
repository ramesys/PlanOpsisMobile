import Foundation

public enum PLYParserError: LocalizedError, Sendable {
    case invalidHeader
    case unsupportedFormat(String)
    case missingVertexElement
    case missingCoordinate(String)
    case unsupportedPropertyType(String)
    case malformedBody(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: return "The file does not contain a valid PLY header."
        case .unsupportedFormat(let f): return "Unsupported PLY format: \(f)."
        case .missingVertexElement: return "PLY has no vertex element."
        case .missingCoordinate(let c): return "PLY vertex data is missing coordinate \(c)."
        case .unsupportedPropertyType(let t): return "Unsupported PLY property type: \(t)."
        case .malformedBody(let s): return "Malformed PLY body: \(s)."
        }
    }
}

public struct PLYParser: Sendable {
    public init() {}

    public func parse(data: Data, sourceName: String, unit: PLYLengthUnit) throws -> PLYPointCloud {
        let (header, bodyOffset) = try Header.parse(data: data)
        guard let vertexElement = header.elements.first(where: { $0.name == "vertex" }) else {
            throw PLYParserError.missingVertexElement
        }
        let vertexPropertyNames = Set(vertexElement.properties.map(\.name))
        for coordinate in ["x", "y", "z"] where !vertexPropertyNames.contains(coordinate) {
            throw PLYParserError.missingCoordinate(coordinate)
        }

        let points: [PLYPoint3D]
        switch header.format {
        case .ascii:
            points = try parseASCII(data: data, bodyOffset: bodyOffset, header: header)
        case .binaryLittleEndian:
            points = try parseBinary(data: data, bodyOffset: bodyOffset, header: header, littleEndian: true)
        case .binaryBigEndian:
            points = try parseBinary(data: data, bodyOffset: bodyOffset, header: header, littleEndian: false)
        }
        return .init(sourceName: sourceName, sourceUnit: unit, points: points)
    }

    public func parse(url: URL, unit: PLYLengthUnit) throws -> PLYPointCloud {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try parse(data: data, sourceName: url.lastPathComponent, unit: unit)
    }
}

private extension PLYParser {
    enum Format: String {
        case ascii
        case binaryLittleEndian = "binary_little_endian"
        case binaryBigEndian = "binary_big_endian"
    }

    enum ScalarType: String {
        case int8 = "char", uint8 = "uchar"
        case int16 = "short", uint16 = "ushort"
        case int32 = "int", uint32 = "uint"
        case float32 = "float", float64 = "double"

        static func parse(_ raw: String) throws -> ScalarType {
            switch raw.lowercased() {
            case "char", "int8": return .int8
            case "uchar", "uint8": return .uint8
            case "short", "int16": return .int16
            case "ushort", "uint16": return .uint16
            case "int", "int32": return .int32
            case "uint", "uint32": return .uint32
            case "float", "float32": return .float32
            case "double", "float64": return .float64
            default: throw PLYParserError.unsupportedPropertyType(raw)
            }
        }

        var byteCount: Int {
            switch self {
            case .int8, .uint8: return 1
            case .int16, .uint16: return 2
            case .int32, .uint32, .float32: return 4
            case .float64: return 8
            }
        }

        var isInteger: Bool {
            switch self {
            case .int8, .uint8, .int16, .uint16, .int32, .uint32: return true
            case .float32, .float64: return false
            }
        }
    }

    enum Property {
        case scalar(type: ScalarType, name: String)
        case list(countType: ScalarType, itemType: ScalarType, name: String)

        var name: String {
            switch self {
            case .scalar(_, let name), .list(_, _, let name): return name
            }
        }
    }

    struct Element {
        var name: String
        var count: Int
        var properties: [Property]
    }

    struct Header {
        var format: Format
        var elements: [Element]

        static func parse(data: Data) throws -> (Header, Int) {
            let marker = Data("end_header".utf8)
            guard data.count >= 4,
                  String(data: data.prefix(3), encoding: .ascii) == "ply" else {
                throw PLYParserError.invalidHeader
            }

            // PLY headers are small. Search only the first 1 MiB and avoid copying the
            // complete point-cloud payload just to locate `end_header` on iPhone.
            let searchEnd = min(data.endIndex, data.startIndex + 1_048_576)
            var markerRange: Range<Data.Index>?
            var searchStart = data.startIndex
            while searchStart < searchEnd,
                  let candidate = data.range(of: marker, in: searchStart..<searchEnd) {
                let beforeOK = candidate.lowerBound == data.startIndex ||
                    data[data.index(before: candidate.lowerBound)] == 10 ||
                    data[data.index(before: candidate.lowerBound)] == 13
                let afterOK = candidate.upperBound == data.endIndex ||
                    data[candidate.upperBound] == 10 || data[candidate.upperBound] == 13
                if beforeOK && afterOK {
                    markerRange = candidate
                    break
                }
                searchStart = candidate.upperBound
            }
            guard let markerRange else { throw PLYParserError.invalidHeader }
            var bodyOffset = markerRange.upperBound
            if bodyOffset < data.endIndex, data[bodyOffset] == 13 { bodyOffset += 1 }
            if bodyOffset < data.endIndex, data[bodyOffset] == 10 { bodyOffset += 1 }

            guard let text = String(data: data[data.startIndex..<bodyOffset], encoding: .ascii) else {
                throw PLYParserError.invalidHeader
            }

            var format: Format?
            var elements: [Element] = []
            var activeIndex: Int?
            for rawLine in text.components(separatedBy: .newlines) {
                let parts = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard !parts.isEmpty else { continue }
                switch parts[0] {
                case "format" where parts.count >= 2:
                    guard let parsedFormat = Format(rawValue: parts[1]) else {
                        throw PLYParserError.unsupportedFormat(parts[1])
                    }
                    format = parsedFormat
                case "element" where parts.count >= 3:
                    guard let count = Int(parts[2]), count >= 0 else { throw PLYParserError.invalidHeader }
                    elements.append(.init(name: parts[1], count: count, properties: []))
                    activeIndex = elements.count - 1
                case "property":
                    guard let index = activeIndex else { continue }
                    if parts.count >= 3, parts[1] != "list" {
                        let type = try ScalarType.parse(parts[1])
                        elements[index].properties.append(.scalar(type: type, name: parts[2]))
                    } else if parts.count >= 5, parts[1] == "list" {
                        let countType = try ScalarType.parse(parts[2])
                        guard countType.isInteger else {
                            throw PLYParserError.invalidHeader
                        }
                        let itemType = try ScalarType.parse(parts[3])
                        elements[index].properties.append(.list(countType: countType, itemType: itemType, name: parts[4]))
                    }
                default:
                    break
                }
            }
            guard let format else { throw PLYParserError.invalidHeader }
            return (.init(format: format, elements: elements), bodyOffset)
        }
    }

    func parseASCII(data: Data, bodyOffset: Int, header: Header) throws -> [PLYPoint3D] {
        guard let body = String(data: data[bodyOffset...], encoding: .utf8) else {
            throw PLYParserError.malformedBody("ASCII body is not UTF-8.")
        }
        // Keep Substring views into the one body String; materializing every row/token as a new
        // String multiplies memory on large ASCII point clouds.
        let lines = body.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        var lineIndex = 0
        var points: [PLYPoint3D] = []

        for element in header.elements {
            for _ in 0..<element.count {
                guard lineIndex < lines.count else { throw PLYParserError.malformedBody("Unexpected end of file.") }
                let tokens = lines[lineIndex].split(whereSeparator: { $0 == " " || $0 == "\t" })
                lineIndex += 1
                var tokenIndex = 0
                var x: Double?, y: Double?, z: Double?

                for property in element.properties {
                    switch property {
                    case .scalar(_, let name):
                        guard tokenIndex < tokens.count, let value = Double(tokens[tokenIndex]) else {
                            throw PLYParserError.malformedBody("Invalid scalar value.")
                        }
                        tokenIndex += 1
                        if element.name == "vertex" {
                            if name == "x" { x = value }
                            if name == "y" { y = value }
                            if name == "z" { z = value }
                        }
                    case .list(_, _, _):
                        guard tokenIndex < tokens.count,
                              let count = Int(tokens[tokenIndex]),
                              count >= 0 else {
                            throw PLYParserError.malformedBody("Invalid list count.")
                        }
                        let (afterCountToken, countTokenOverflow) = tokenIndex.addingReportingOverflow(1)
                        let (nextTokenIndex, listOverflow) = afterCountToken.addingReportingOverflow(count)
                        guard !countTokenOverflow, !listOverflow, nextTokenIndex <= tokens.count else {
                            throw PLYParserError.malformedBody("List exceeds row length.")
                        }
                        tokenIndex = nextTokenIndex
                    }
                }

                if element.name == "vertex" {
                    guard let x else { throw PLYParserError.missingCoordinate("x") }
                    guard let y else { throw PLYParserError.missingCoordinate("y") }
                    guard let z else { throw PLYParserError.missingCoordinate("z") }
                    points.append(.init(x: x, y: y, z: z))
                }
            }
        }
        return points
    }

    func parseBinary(data: Data, bodyOffset: Int, header: Header, littleEndian: Bool) throws -> [PLYPoint3D] {
        var cursor = BinaryCursor(data: data, offset: bodyOffset, littleEndian: littleEndian)
        var points: [PLYPoint3D] = []
        for element in header.elements {
            for _ in 0..<element.count {
                var x: Double?, y: Double?, z: Double?
                for property in element.properties {
                    switch property {
                    case .scalar(let type, let name):
                        let value = try cursor.read(type)
                        if element.name == "vertex" {
                            if name == "x" { x = value }
                            if name == "y" { y = value }
                            if name == "z" { z = value }
                        }
                    case .list(let countType, let itemType, _):
                        let rawCount = try cursor.read(countType)
                        guard rawCount.isFinite,
                              rawCount >= 0,
                              rawCount.rounded(.towardZero) == rawCount,
                              rawCount <= Double(Int.max) else {
                            throw PLYParserError.malformedBody("Invalid binary list count.")
                        }
                        let count = Int(rawCount)
                        let (bytesToSkip, overflow) = count.multipliedReportingOverflow(by: itemType.byteCount)
                        guard !overflow else {
                            throw PLYParserError.malformedBody("Binary list byte count overflow.")
                        }
                        try cursor.skip(bytesToSkip)
                    }
                }
                if element.name == "vertex" {
                    guard let x else { throw PLYParserError.missingCoordinate("x") }
                    guard let y else { throw PLYParserError.missingCoordinate("y") }
                    guard let z else { throw PLYParserError.missingCoordinate("z") }
                    points.append(.init(x: x, y: y, z: z))
                }
            }
        }
        return points
    }

    struct BinaryCursor {
        let data: Data
        var offset: Int
        let littleEndian: Bool

        mutating func skip(_ count: Int) throws {
            guard count >= 0 else {
                throw PLYParserError.malformedBody("Negative binary skip length.")
            }
            let (endOffset, overflow) = offset.addingReportingOverflow(count)
            guard !overflow, endOffset <= data.count else {
                throw PLYParserError.malformedBody("Unexpected end of binary body.")
            }
            offset = endOffset
        }

        mutating func read(_ type: ScalarType) throws -> Double {
            let (endOffset, overflow) = offset.addingReportingOverflow(type.byteCount)
            guard !overflow, endOffset <= data.count else {
                throw PLYParserError.malformedBody("Unexpected end of binary body.")
            }
            let bytes = data[offset..<endOffset]
            offset = endOffset
            let u = unsigned(bytes)
            switch type {
            case .uint8: return Double(UInt8(truncatingIfNeeded: u))
            case .int8: return Double(Int8(bitPattern: UInt8(truncatingIfNeeded: u)))
            case .uint16: return Double(UInt16(truncatingIfNeeded: u))
            case .int16: return Double(Int16(bitPattern: UInt16(truncatingIfNeeded: u)))
            case .uint32: return Double(UInt32(truncatingIfNeeded: u))
            case .int32: return Double(Int32(bitPattern: UInt32(truncatingIfNeeded: u)))
            case .float32: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: u)))
            case .float64: return Double(bitPattern: u)
            }
        }

        private func unsigned(_ bytes: Data.SubSequence) -> UInt64 {
            var result: UInt64 = 0
            if littleEndian {
                for (shift, byte) in bytes.enumerated() {
                    result |= UInt64(byte) << UInt64(shift * 8)
                }
            } else {
                for byte in bytes {
                    result = (result << 8) | UInt64(byte)
                }
            }
            return result
        }
    }
}
