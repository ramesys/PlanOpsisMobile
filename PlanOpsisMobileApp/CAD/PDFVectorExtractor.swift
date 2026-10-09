import Foundation

/// v12.7 a PDF page ready to sit under the plan: the rendered sheet and, for drawings exported from
/// CAD, its lines in paper millimetres for snapping and tracing.
public struct PDFUnderlayPage: Sendable {
    public var raster: RasterUnderlay
    /// Lines of the page in paper mm (y up, origin at the displayed page's bottom-left); nil for scans.
    public var vectors: CADDocument?
    public var pageIndex: Int
    public var pageCount: Int
    /// v12.10 a photo's plan read as walls, openings, stairs and scale.
    public var reading: PlanPhotoReading?

    public init(raster: RasterUnderlay, vectors: CADDocument?, pageIndex: Int, pageCount: Int, reading: PlanPhotoReading? = nil) {
        self.raster = raster
        self.vectors = vectors
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.reading = reading
    }
}

/// Finds the form XObjects a content stream draws with `Do`.
public protocol PDFFormResolver {
    /// The decoded content of form `name`, its form matrix, and the resolver for the form's own resources.
    func form(named name: String) -> (content: Data, matrix: CADAffine, resources: PDFFormResolver?)?
}

/// v12.7 reads the line work of a PDF page from its content stream: paths (lines, curves, rectangles)
/// that are stroked or filled, through nested graphics states, transforms and form XObjects. Text,
/// images and clipping are ignored.
public struct PDFVectorExtractor {
    public var maxSegments = 250_000
    public var maxFormDepth = 8
    /// Line pieces per Bézier curve.
    public var curveSteps = 8

    public init() {}

    /// PDF user space (points) to paper millimetres of the page as displayed: rotation is clockwise,
    /// as in the page's /Rotate entry.
    public static func pageTransform(mediaBox: CADRect, rotation: Int) -> CADAffine {
        let k = 25.4 / 72
        let w = mediaBox.width, h = mediaBox.height
        let toOrigin = CADAffine.translation(Point2D(x: -mediaBox.minX, y: -mediaBox.minY))
        let turn: CADAffine
        switch ((rotation % 360) + 360) % 360 {
        case 90: turn = CADAffine(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: turn = CADAffine(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: turn = CADAffine(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: turn = .identity
        }
        return CADAffine.scale(k, k).concatenating(turn).concatenating(toOrigin)
    }

    /// Segments of the page in the coordinates `pageTransform` gives.
    public func segments(content: Data, resolver: PDFFormResolver?, pageTransform: CADAffine) -> [(Point2D, Point2D)] {
        var output: [(Point2D, Point2D)] = []
        run(content: Array(content), ctm: pageTransform, resolver: resolver, depth: 0, output: &output)
        return output
    }

    /// The page's lines as a drawing in paper millimetres, or nil when the page has none (a scan).
    public func document(content: Data, resolver: PDFFormResolver?, pageTransform: CADAffine, minimumLength: Double = 0.05) -> CADDocument? {
        let lines = segments(content: content, resolver: resolver, pageTransform: pageTransform)
            .filter { ($0.1 - $0.0).length >= minimumLength }
        guard !lines.isEmpty else { return nil }
        return CADDocument(units: .millimetres, layers: [CADLayer(name: "PDF")],
                           entities: lines.map { CADEntity(type: "LINE", layer: "PDF", geometry: .line($0.0, $0.1)) })
    }

    // MARK: Interpreter

    private func run(content: [UInt8], ctm initial: CADAffine, resolver: PDFFormResolver?, depth: Int, output: inout [(Point2D, Point2D)]) {
        var ctm = initial
        var stack: [CADAffine] = []
        var operands: [Double] = []
        var name: String?
        var path: [(Point2D, Point2D)] = []
        var current: Point2D?
        var subpathStart: Point2D?
        var tokenizer = PDFTokenizer(bytes: content)

        func point(_ x: Double, _ y: Double) -> Point2D { ctm.apply(Point2D(x: x, y: y)) }
        func lineTo(_ p: Point2D) {
            if let c = current { path.append((c, p)) }
            current = p
        }
        func curve(_ p1: Point2D, _ p2: Point2D, _ p3: Point2D) {
            guard let p0 = current else { current = p3; return }
            for i in 1...curveSteps {
                let t = Double(i) / Double(curveSteps), u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                lineTo(Point2D(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y))
            }
        }
        func n(_ i: Int) -> Double { operands.count > i ? operands[operands.count - 1 - i] : 0 }

        while let token = tokenizer.next() {
            guard output.count < maxSegments else { return }
            switch token {
            case let .number(value): operands.append(value)
            case let .name(value): name = value
            case .other: break
            case let .keyword(op):
                switch op {
                case "q": stack.append(ctm)
                case "Q": if let last = stack.popLast() { ctm = last }
                case "cm" where operands.count >= 6:
                    ctm = ctm.concatenating(CADAffine(a: n(5), b: n(4), c: n(3), d: n(2), tx: n(1), ty: n(0)))
                case "m" where operands.count >= 2:
                    let p = point(n(1), n(0))
                    current = p
                    subpathStart = p
                case "l" where operands.count >= 2:
                    lineTo(point(n(1), n(0)))
                case "c" where operands.count >= 6:
                    curve(point(n(5), n(4)), point(n(3), n(2)), point(n(1), n(0)))
                case "v" where operands.count >= 4:
                    curve(current ?? point(n(3), n(2)), point(n(3), n(2)), point(n(1), n(0)))
                case "y" where operands.count >= 4:
                    curve(point(n(3), n(2)), point(n(1), n(0)), point(n(1), n(0)))
                case "re" where operands.count >= 4:
                    let x = n(3), y = n(2), w = n(1), h = n(0)
                    let corners = [point(x, y), point(x + w, y), point(x + w, y + h), point(x, y + h)]
                    for i in 0..<4 { path.append((corners[i], corners[(i + 1) % 4])) }
                    current = corners[0]
                    subpathStart = corners[0]
                case "h":
                    if let start = subpathStart, let c = current, (c - start).length > 1e-9 { path.append((c, start)) }
                    current = subpathStart
                case "s", "b", "b*", "f", "F", "f*", "B", "B*":
                    // Closing strokes and fills close the last open subpath.
                    if let start = subpathStart, let c = current, (c - start).length > 1e-9 { path.append((c, start)) }
                    output += path.prefix(maxSegments - output.count)
                    path = []; current = nil; subpathStart = nil
                case "S":
                    output += path.prefix(maxSegments - output.count)
                    path = []; current = nil; subpathStart = nil
                case "n":
                    path = []; current = nil; subpathStart = nil
                case "Do":
                    if let name, depth < maxFormDepth, let form = resolver?.form(named: name) {
                        run(content: Array(form.content), ctm: ctm.concatenating(form.matrix), resolver: form.resources, depth: depth + 1, output: &output)
                    }
                case "BI":
                    tokenizer.skipInlineImage()
                default:
                    break
                }
                operands.removeAll(keepingCapacity: true)
                name = nil
            }
        }
    }
}

/// PDF content stream tokens: numbers, names and operators; strings, arrays and dictionaries are
/// skipped as single `.other` tokens.
struct PDFTokenizer {
    enum Token: Equatable { case number(Double), name(String), keyword(String), other }

    private let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    private static func isWhitespace(_ b: UInt8) -> Bool { b == 0x00 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D || b == 0x20 }
    private static func isDelimiter(_ b: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(b) }

    mutating func next() -> Token? {
        while index < bytes.count {
            let b = bytes[index]
            if Self.isWhitespace(b) { index += 1; continue }
            if b == UInt8(ascii: "%") {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
                continue
            }
            switch b {
            case UInt8(ascii: "("):
                skipLiteralString()
                return .other
            case UInt8(ascii: "<"):
                if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") {
                    skipDictionary()
                } else {
                    while index < bytes.count, bytes[index] != UInt8(ascii: ">") { index += 1 }
                    index += 1
                }
                return .other
            case UInt8(ascii: "["):
                skipArray()
                return .other
            case UInt8(ascii: "]"), UInt8(ascii: ">"), UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                index += 1
                return .other
            case UInt8(ascii: "/"):
                index += 1
                let start = index
                while index < bytes.count, !Self.isWhitespace(bytes[index]), !Self.isDelimiter(bytes[index]) { index += 1 }
                return .name(String(decoding: bytes[start..<index], as: UTF8.self))
            default:
                let start = index
                while index < bytes.count, !Self.isWhitespace(bytes[index]), !Self.isDelimiter(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self)
                if let first = word.utf8.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") || first == UInt8(ascii: ".") || (48...57).contains(first) {
                    if let value = Double(word) { return .number(value) }
                    // "1.5.2" and the like: not a number PDF writers produce; skip it.
                    return .other
                }
                return .keyword(word)
            }
        }
        return nil
    }

    private mutating func skipLiteralString() {
        var depth = 0
        while index < bytes.count {
            let b = bytes[index]
            index += 1
            if b == UInt8(ascii: "\\") { index += 1; continue }
            if b == UInt8(ascii: "(") { depth += 1 }
            if b == UInt8(ascii: ")") { depth -= 1; if depth == 0 { return } }
        }
    }

    private mutating func skipArray() {
        index += 1
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "]") { index += 1; return }
            if b == UInt8(ascii: "(") { skipLiteralString(); continue }
            if b == UInt8(ascii: "[") { skipArray(); continue }
            if b == UInt8(ascii: "<"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "<") { skipDictionary(); continue }
            index += 1
        }
    }

    private mutating func skipDictionary() {
        var depth = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "("), depth > 0 { skipLiteralString(); continue }
            if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "<"), bytes[index + 1] == UInt8(ascii: "<") { depth += 1; index += 2; continue }
            if index + 1 < bytes.count, bytes[index] == UInt8(ascii: ">"), bytes[index + 1] == UInt8(ascii: ">") {
                depth -= 1
                index += 2
                if depth == 0 { return }
                continue
            }
            index += 1
        }
    }

    /// After `BI`: skips the image dictionary and binary data up to the `EI` that ends it.
    mutating func skipInlineImage() {
        // Find "ID" followed by one whitespace byte; the data runs to whitespace + "EI" + delimiter.
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "I"), bytes[index + 1] == UInt8(ascii: "D"),
               index == 0 || Self.isWhitespace(bytes[index - 1]) {
                index += 3
                break
            }
            index += 1
        }
        while index + 2 < bytes.count {
            if Self.isWhitespace(bytes[index]), bytes[index + 1] == UInt8(ascii: "E"), bytes[index + 2] == UInt8(ascii: "I"),
               index + 3 >= bytes.count || Self.isWhitespace(bytes[index + 3]) || Self.isDelimiter(bytes[index + 3]) {
                index += 3
                return
            }
            index += 1
        }
        index = bytes.count
    }
}
