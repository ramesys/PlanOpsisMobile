import Foundation

/// Stable cross-format identity bridge for PlanOpsis exports.
///
/// The PlanOpsis semantic UUID is authoritative. IFC4 GlobalIds are deterministic
/// compressed representations of those UUIDs, while DXF keeps the same UUID and
/// GlobalId in PLANOPSIS XDATA. Export formats therefore remain siblings; neither
/// format is used as the source for another.
public enum PlanOpsisExchangeIdentity {
    private static let ifcAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_$")

    /// buildingSMART / IfcOpenShell compatible 22-character IFC GUID compression.
    public static func ifcGlobalID(for uuid: UUID) -> String {
        let bytes: [UInt8] = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        precondition(bytes.count == 16)

        func encode(_ value: UInt32, length: Int) -> String {
            var chars = Array(repeating: Character("0"), count: length)
            var v = value
            for index in stride(from: length - 1, through: 0, by: -1) {
                chars[index] = ifcAlphabet[Int(v % 64)]
                v /= 64
            }
            return String(chars)
        }

        var result = encode(UInt32(bytes[0]), length: 2)
        var index = 1
        while index < 16 {
            let value = (UInt32(bytes[index]) << 16)
                | (UInt32(bytes[index + 1]) << 8)
                | UInt32(bytes[index + 2])
            result += encode(value, length: 4)
            index += 3
        }
        return result
    }

    /// Stable UUID for export-only hierarchy/relationship objects that have no
    /// independent PlanOpsis semantic entity (site, building, storey, relations).
    public static func derivedUUID(namespace: UUID, role: String) -> UUID {
        let namespaceBytes: [UInt8] = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        let payload = namespaceBytes + Array(role.utf8)

        func fnv64(seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in payload {
                hash ^= UInt64(byte)
                hash &*= 0x100000001B3
                hash ^= hash >> 32
            }
            return hash
        }

        let a = fnv64(seed: 0xCBF29CE484222325)
        let b = fnv64(seed: 0x84222325CBF29CE4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((a >> UInt64((7 - i) * 8)) & 0xFF) }
        for i in 0..<8 { bytes[8 + i] = UInt8((b >> UInt64((7 - i) * 8)) & 0xFF) }
        // RFC 4122 variant + deterministic version-like marker.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func ifcGlobalID(namespace: UUID, role: String) -> String {
        ifcGlobalID(for: derivedUUID(namespace: namespace, role: role))
    }

    public static func semanticType(for opening: PlanOpsisOpening) -> String {
        switch opening {
        case .opening:
            return "opening.generic"
        case .door(let door):
            return "door.\(door.operation.rawValue)"
        case .window(let window):
            return "window.\(window.operation.rawValue)"
        }
    }

    public static func semanticType(for component: PlanOpsisComponent) -> String {
        switch component.kind {
        case .column: return "column"
        case .beam: return "beam"
        case .bed: return "furniture.bed"
        case .table: return "furniture.table"
        case .chair: return "furniture.chair"
        case .sofa: return "furniture.sofa"
        case .wc: return "sanitary.wc"
        case .sink: return "sanitary.sink"
        }
    }
}
