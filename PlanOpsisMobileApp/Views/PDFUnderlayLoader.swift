#if os(iOS)
import PDFKit
import UIKit

/// v12.6 renders a page of a PDF drawing into an underlay image at its paper size; v12.7 also reads
/// the page's line work so a PDF exported from CAD can be snapped to and traced.
enum PDFUnderlayLoader {
    enum LoadError: LocalizedError {
        case unreadable, empty, renderFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file is not a readable PDF."
            case .empty: return "The PDF has no pages."
            case .renderFailed: return "The page could not be rendered."
            }
        }
    }

    /// Long side of the rendered page in pixels: sharp enough to trace an A1 sheet at 1:100 and small
    /// enough to keep memory modest on older phones.
    static let longSidePixels = 3_600.0

    static func load(data: Data, name: String, page pageIndex: Int) throws -> PDFUnderlayPage {
        guard let document = PDFDocument(data: data) else { throw LoadError.unreadable }
        guard document.pageCount > 0 else { throw LoadError.empty }
        let index = min(max(0, pageIndex), document.pageCount - 1)
        guard let page = document.page(at: index) else { throw LoadError.empty }
        let box = page.bounds(for: .mediaBox)
        let quarterTurned = (page.rotation / 90) % 2 != 0
        let widthPoints = Double(quarterTurned ? box.height : box.width)
        let heightPoints = Double(quarterTurned ? box.width : box.height)
        guard widthPoints > 0, heightPoints > 0 else { throw LoadError.renderFailed }
        let k = longSidePixels / max(widthPoints, heightPoints)
        let size = CGSize(width: (widthPoints * k).rounded(), height: (heightPoints * k).rounded())
        // A white sheet: transparent pages would vanish in dark mode's inverted underlay.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            page.thumbnail(of: size, for: .mediaBox).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = image.pngData() else { throw LoadError.renderFailed }
        let millimetresPerPoint = 25.4 / 72
        let suffix = document.pageCount > 1 ? " (page \(index + 1) of \(document.pageCount))" : ""
        let raster = RasterUnderlay(name: name + suffix, pageWidthMM: widthPoints * millimetresPerPoint,
                                    pageHeightMM: heightPoints * millimetresPerPoint, imageData: png)

        var vectors: CADDocument?
        if let pageRef = page.pageRef, let pageDictionary = pageRef.dictionary {
            let mediaBox = CADRect(minX: Double(box.minX), minY: Double(box.minY), maxX: Double(box.maxX), maxY: Double(box.maxY))
            let transform = PDFVectorExtractor.pageTransform(mediaBox: mediaBox, rotation: page.rotation)
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources)
            vectors = PDFVectorExtractor().document(content: PDFStreams.pageContent(pageDictionary), resolver: CGPDFFormResolver(resources: resources),
                                                    pageTransform: transform)
        }
        return PDFUnderlayPage(raster: raster, vectors: vectors, pageIndex: index, pageCount: document.pageCount)
    }
}

/// Decoded content streams from Core Graphics' PDF objects.
enum PDFStreams {
    static func decoded(_ stream: CGPDFStreamRef) -> Data? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { return nil }
        return data as Data
    }

    /// A page's /Contents: one stream or an array of streams joined as one.
    static func pageContent(_ page: CGPDFDictionaryRef) -> Data {
        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(page, "Contents", &stream), let stream {
            return decoded(stream) ?? Data()
        }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(page, "Contents", &array), let array else { return Data() }
        var content = Data()
        for i in 0..<CGPDFArrayGetCount(array) {
            var part: CGPDFStreamRef?
            if CGPDFArrayGetStream(array, i, &part), let part, let data = decoded(part) {
                content.append(data)
                content.append(0x0A)
            }
        }
        return content
    }
}

/// Form XObjects looked up in a resource dictionary; forms with their own resources resolve in them.
final class CGPDFFormResolver: PDFFormResolver {
    private let resources: CGPDFDictionaryRef?

    init(resources: CGPDFDictionaryRef?) { self.resources = resources }

    func form(named name: String) -> (content: Data, matrix: CADAffine, resources: PDFFormResolver?)? {
        guard let resources else { return nil }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(objects, name, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form",
              let content = PDFStreams.decoded(stream) else { return nil }
        var matrix = CADAffine.identity
        var values: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &values), let values, CGPDFArrayGetCount(values) == 6 {
            var m = [CGPDFReal](repeating: 0, count: 6)
            for i in 0..<6 { _ = CGPDFArrayGetNumber(values, i, &m[i]) }
            matrix = CADAffine(a: Double(m[0]), b: Double(m[1]), c: Double(m[2]), d: Double(m[3]), tx: Double(m[4]), ty: Double(m[5]))
        }
        var own: CGPDFDictionaryRef?
        let nested: PDFFormResolver = CGPDFDictionaryGetDictionary(dictionary, "Resources", &own) ? CGPDFFormResolver(resources: own) : self
        return (content, matrix, nested)
    }
}
#endif
