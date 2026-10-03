#if os(iOS)
import PDFKit
import UIKit

/// v12.6 renders the first page of a PDF drawing into an underlay image at its paper size.
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

    static func load(data: Data, name: String) throws -> RasterUnderlay {
        guard let document = PDFDocument(data: data) else { throw LoadError.unreadable }
        guard let page = document.page(at: 0) else { throw LoadError.empty }
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
        let suffix = document.pageCount > 1 ? " (page 1 of \(document.pageCount))" : ""
        return RasterUnderlay(name: name + suffix, pageWidthMM: widthPoints * millimetresPerPoint, pageHeightMM: heightPoints * millimetresPerPoint, imageData: png)
    }
}
#endif
