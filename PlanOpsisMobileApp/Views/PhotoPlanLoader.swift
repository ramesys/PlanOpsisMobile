#if os(iOS)
import CoreImage
import SwiftUI
import UIKit
import Vision
import VisionKit

/// v12.9 turns a photo of a paper plan into an underlay: the sheet straightened when it was shot at an
/// angle, its walls and lines found by `PlanPhotoVectorizer`, its text read with Vision. The underlay's
/// "paper" is the photo's pixels, at an assumed 15 m across until the user calibrates it.
enum PhotoPlanLoader {
    enum LoadError: LocalizedError {
        case unreadable, renderFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file is not a readable image."
            case .renderFailed: return "The photo could not be prepared."
            }
        }
    }

    /// Long side of the analysed photo in pixels: a 200 mm wall on a 1:100 A3 print is still ~4 px.
    static let longSidePixels = 2_400.0
    /// What the photo's long side is taken to measure before calibration, in millimetres.
    static let assumedLongSideMM = 15_000.0

    /// `straighten` is off for a photo saved with the project, which was straightened when it was taken.
    static func load(data: Data, name: String, straighten: Bool = true) throws -> PDFUnderlayPage {
        guard let image = UIImage(data: data) else { throw LoadError.unreadable }
        // Upright (EXIF orientation applied) and no bigger than needed for the sheet detection.
        guard let upright = render(image, longSide: longSidePixels * 1.5) else { throw LoadError.renderFailed }
        let sheet = (straighten ? straightened(upright) : nil) ?? upright
        guard let photo = render(UIImage(cgImage: sheet), longSide: longSidePixels),
              let gray = grayImage(photo) else { throw LoadError.renderFailed }

        let result = PlanPhotoVectorizer().vectorize(gray)
        let vectors = PlanPhotoVectorizer.document(from: result, texts: texts(in: photo))
        guard let jpeg = UIImage(cgImage: photo).jpegData(compressionQuality: 0.8) else { throw LoadError.renderFailed }
        let width = Double(photo.width), height = Double(photo.height)
        let raster = RasterUnderlay(name: name, pageWidthMM: width, pageHeightMM: height, imageData: jpeg,
                                    paperScale: assumedLongSideMM / max(width, height), isPhoto: true)
        return PDFUnderlayPage(raster: raster, vectors: vectors, pageIndex: 0, pageCount: 1)
    }

    /// The image drawn upright on white at scale 1, its long side at most `longSide` pixels.
    static func render(_ image: UIImage, longSide: Double) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let k = min(1, longSide / Double(max(size.width, size.height)))
        let target = CGSize(width: (Double(size.width) * k).rounded(), height: (Double(size.height) * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }

    /// The sheet of paper cut out and squared up when the photo was taken at an angle; nil when no
    /// sheet is found or it already fills the photo (a document scan).
    static func straightened(_ image: CGImage) -> CGImage? {
        let request = VNDetectRectanglesRequest()
        request.minimumSize = 0.3
        request.maximumObservations = 1
        request.minimumConfidence = 0.6
        request.quadratureTolerance = 25
        request.minimumAspectRatio = 0.25
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let sheet = request.results?.first, sheet.boundingBox.width * sheet.boundingBox.height < 0.92,
              isPaper(sheet.boundingBox, in: image) else { return nil }
        // Vision's corners are normalised with the origin bottom-left, as Core Image's are.
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func vector(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(vector(sheet.topLeft), forKey: "inputTopLeft")
        filter.setValue(vector(sheet.topRight), forKey: "inputTopRight")
        filter.setValue(vector(sheet.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(vector(sheet.bottomRight), forKey: "inputBottomRight")
        guard let output = filter.outputImage, output.extent.width > 1, output.extent.height > 1 else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Whether a found rectangle is the sheet rather than a drawn outline on it: paper is clearly
    /// brighter than the table or wall around it, while a room outline has the same paper outside.
    static func isPaper(_ box: CGRect, in image: CGImage) -> Bool {
        let side = 96
        let thumbnail = image.width >= image.height
            ? (width: side, height: max(1, side * image.height / image.width))
            : (width: max(1, side * image.width / image.height), height: side)
        guard let small = grayImage(image, width: thumbnail.width, height: thumbnail.height) else { return false }
        var inside = (sum: 0.0, count: 0), outside = (sum: 0.0, count: 0)
        for row in 0..<small.height {
            for x in 0..<small.width {
                // Normalised, origin bottom-left as Vision's box is.
                let p = CGPoint(x: (Double(x) + 0.5) / Double(small.width), y: 1 - (Double(row) + 0.5) / Double(small.height))
                let value = Double(small[x, row])
                if box.contains(p) { inside.sum += value; inside.count += 1 } else { outside.sum += value; outside.count += 1 }
            }
        }
        guard inside.count > 0, outside.count > 0 else { return false }
        return outside.sum / Double(outside.count) < 0.85 * inside.sum / Double(inside.count)
    }

    /// The photo's grey levels, rows top first as `GrayImage` keeps them.
    static func grayImage(_ image: CGImage) -> GrayImage? { grayImage(image, width: image.width, height: image.height) }

    /// The photo's grey levels drawn at `width` × `height`.
    static func grayImage(_ image: CGImage, width: Int, height: Int) -> GrayImage? {
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? GrayImage(width: width, height: height, pixels: pixels) : nil
    }

    /// The plan's text (room names, dimensions) with its centre and height in y-up pixels.
    static func texts(in image: CGImage) -> [(position: Point2D, string: String, height: Double)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let w = Double(image.width), h = Double(image.height)
        return (request.results ?? []).compactMap { observation -> (position: Point2D, string: String, height: Double)? in
            guard let string = observation.topCandidates(1).first?.string, !string.isEmpty else { return nil }
            let box = observation.boundingBox
            return (Point2D(x: Double(box.midX) * w, y: Double(box.midY) * h), string, Double(box.height) * h)
        }
    }
}

/// v12.9 VisionKit's document camera: finds the sheet, squares it up and evens out the light.
struct DocumentCameraView: UIViewControllerRepresentable {
    let onScan: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (UIImage) -> Void
        let onCancel: () -> Void

        init(onScan: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { onCancel(); return }
            onScan(scan.imageOfPage(at: 0))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onCancel() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onCancel() }
    }
}
#endif
