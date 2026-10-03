#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var planOpsisDXF: UTType { UTType(filenameExtension: "dxf") ?? .plainText }
    static var planOpsisIFC: UTType { UTType(filenameExtension: "ifc") ?? .plainText }
}

enum ArchitecturalExchangeFormat {
    case dxf, ifc
    /// v12.4 drawing set and schedules.
    case pdf, csv

    var contentType: UTType {
        switch self {
        case .dxf: return .planOpsisDXF
        case .ifc: return .planOpsisIFC
        case .pdf: return .pdf
        case .csv: return .commaSeparatedText
        }
    }

    var filename: String {
        switch self {
        case .dxf: return "PlanOpsis-Architectural.dxf"
        case .ifc: return "PlanOpsis-Semantic-IFC4.ifc"
        case .pdf: return "PlanOpsis-Drawings.pdf"
        case .csv: return "PlanOpsis-Schedules.csv"
        }
    }

    var label: String {
        switch self {
        case .dxf: return "DXF"
        case .ifc: return "IFC4"
        case .pdf: return "PDF drawing set"
        case .csv: return "Schedules CSV"
        }
    }
}

struct ArchitecturalExchangeTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.planOpsisDXF, .planOpsisIFC, .plainText] }
    static var writableContentTypes: [UTType] { [.planOpsisDXF, .planOpsisIFC, .pdf, .commaSeparatedText, .plainText] }
    var text: String
    /// Binary content (PDF); written instead of `text` when set.
    var data: Data?

    init(text: String = "") { self.text = text }
    init(data: Data) { self.text = ""; self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = value
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let data { return FileWrapper(regularFileWithContents: data) }
        // PlanOpsis v9.5 emits an ASCII-safe R2000 DXF. Keeping bytes ASCII-compatible
        // avoids encoding ambiguity in conservative CAD readers.
        let data = text.data(using: .ascii, allowLossyConversion: false) ?? Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}

#endif
