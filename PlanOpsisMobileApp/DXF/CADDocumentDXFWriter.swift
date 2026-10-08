import Foundation

/// v12.9 writes a drawing (lines, polylines, text on their layers) as an AutoCAD R12 ASCII DXF: the
/// plainest flavour, which every CAD program opens. Used for a photo's or PDF's line work, placed and
/// scaled into millimetres by `transform`. PlanOpsis semantic layers (in either naming) are written in
/// `layerNaming`, so the file reads like the app's own DXF; other layers keep their names.
public struct CADDocumentDXFWriter {
    public init() {}

    public func write(_ document: CADDocument, transform: CADAffine = .identity, layerNaming: DXFLayerNaming = .ifcClass) -> String {
        var out: [String] = []
        func pair(_ code: Int, _ value: String) { out.append(String(code)); out.append(value) }
        func number(_ value: Double) -> String {
            guard value.isFinite else { return "0.0" }
            return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        func point(_ base: Int, _ p: Point2D) {
            let q = transform.apply(p)
            pair(base, number(q.x)); pair(base + 10, number(q.y)); pair(base + 20, "0.0")
        }
        // DXF names: no spaces or reserved characters.
        func layerName(_ source: String) -> String {
            let name = ArchitecturalDraftingConvention.Layer(dxfName: source)?.dxfName(layerNaming) ?? source
            let cleaned = name.map { "<>/\\\":;?*|=`".contains($0) ? "_" : $0 }
            return cleaned.isEmpty ? "0" : String(cleaned)
        }

        var layers: [String] = []
        for name in document.layers.map(\.name) + document.entities.map(\.layer) where !layers.contains(layerName(name)) {
            layers.append(layerName(name))
        }

        pair(0, "SECTION"); pair(2, "HEADER")
        pair(9, "$ACADVER"); pair(1, "AC1009")
        pair(9, "$INSUNITS"); pair(70, "4")
        pair(0, "ENDSEC")

        pair(0, "SECTION"); pair(2, "TABLES")
        pair(0, "TABLE"); pair(2, "LAYER"); pair(70, String(layers.count))
        for (index, name) in layers.enumerated() {
            pair(0, "LAYER"); pair(2, name); pair(70, "0"); pair(62, String(index % 6 + 1)); pair(6, "CONTINUOUS")
        }
        pair(0, "ENDTAB")
        pair(0, "ENDSEC")

        pair(0, "SECTION"); pair(2, "ENTITIES")
        let scale = transform.uniformScale
        for entity in document.entities {
            let layer = layerName(entity.layer)
            switch entity.geometry {
            case let .line(a, b):
                pair(0, "LINE"); pair(8, layer); point(10, a); point(11, b)
            case let .polyline(polyline):
                pair(0, "POLYLINE"); pair(8, layer); pair(66, "1"); pair(10, "0.0"); pair(20, "0.0"); pair(30, "0.0")
                pair(70, polyline.closed ? "1" : "0")
                for vertex in polyline.vertices {
                    pair(0, "VERTEX"); pair(8, layer); point(10, vertex.point)
                }
                pair(0, "SEQEND"); pair(8, layer)
            case let .text(text):
                pair(0, "TEXT"); pair(8, layer); point(10, text.position)
                pair(40, number(max(1e-6, text.height * scale)))
                pair(1, text.string.replacingOccurrences(of: "\n", with: " "))
                let angle = text.rotation + transform.rotation
                if abs(angle) > 1e-9 { pair(50, number(angle * 180 / .pi)) }
                // Centred texts keep their anchor as the alignment point.
                if text.horizontal == .center { pair(72, "1"); point(11, text.position) }
            default:
                continue
            }
        }
        pair(0, "ENDSEC")
        pair(0, "EOF")
        return out.joined(separator: "\r\n") + "\r\n"
    }
}
