#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var planOpsisDXF: UTType { UTType(filenameExtension: "dxf") ?? .plainText }
    static var planOpsisIFC: UTType { UTType(filenameExtension: "ifc") ?? .plainText }
}

enum ArchitecturalExchangeFormat {
    case dxf, ifc
    var contentType: UTType { self == .dxf ? .planOpsisDXF : .planOpsisIFC }
    var filename: String { self == .dxf ? "PlanOpsis-Architectural.dxf" : "PlanOpsis-Semantic-IFC4.ifc" }
    var label: String { self == .dxf ? "DXF" : "IFC4" }
}

struct ArchitecturalExchangeTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.planOpsisDXF, .planOpsisIFC, .plainText] }
    var text: String

    init(text: String = "") { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = value
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // PlanOpsis v9.5 emits an ASCII-safe R2000 DXF. Keeping bytes ASCII-compatible
        // avoids encoding ambiguity in conservative CAD readers.
        let data = text.data(using: .ascii, allowLossyConversion: false) ?? Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

#endif
