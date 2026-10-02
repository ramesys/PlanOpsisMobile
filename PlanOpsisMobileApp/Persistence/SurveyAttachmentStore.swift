import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum SurveyHash {
    public static func data(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        #else
        return PortableSHA256.hash(data).map { String(format:"%02x",$0) }.joined()
        #endif
    }
    public static func value<T: Encodable>(_ value:T) throws -> String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return data(try encoder.encode(value))
    }
}
public struct SurveyAttachmentStore:Sendable {
    public let root: URL
    public init(root:URL) { self.root=root }
    private func safeURL(_ relative:String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator:"/").contains("..") else { throw SurveyError.invalid("Invalid attachment path.") }
        let base=root.resolvingSymlinksInPath().standardizedFileURL
        let url=base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path+"/") else { throw SurveyError.invalid("Attachment escapes project storage.") }
        return url
    }
    public func importAsset(data:Data,projectID:UUID,kind:SurveyEvidenceKind,sourceName:String) throws -> SurveyEvidenceReference {
        let hash=SurveyHash.data(data), relative="assets/\(projectID.uuidString)/\(hash).asset"
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=try safeURL(relative)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        _ = try safeURL(relative)
        if FileManager.default.fileExists(atPath:url.path) {
            guard try Data(contentsOf:url)==data else { throw SurveyError.invalid("Existing attachment hash mismatch.") }
        } else {
            let staging=url.deletingLastPathComponent().appendingPathComponent(".staging-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:staging) }
            try data.write(to:staging,options:.atomic)
            try FileManager.default.moveItem(at:staging,to:url)
        }
        return SurveyEvidenceReference(id:UUID(),projectID:projectID,relativePath:relative,sha256:hash,sourceName:sourceName,kind:kind)
    }
    public func readVerified(_ reference:SurveyEvidenceReference,projectID:UUID) throws -> Data {
        guard reference.projectID==projectID else { throw SurveyError.invalid("Evidence belongs to another project.") }
        let data=try Data(contentsOf:safeURL(reference.relativePath))
        guard SurveyHash.data(data)==reference.sha256 else { throw SurveyError.invalid("Evidence file failed its integrity check.") }
        return data
    }
}

/// FIPS 180-4 SHA-256 used where CryptoKit is unavailable (Linux CI and agent containers).
/// Apple platforms keep CryptoKit; both paths must produce identical evidence hashes.
enum PortableSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j+1]) << 16 | UInt32(message[j+2]) << 8 | UInt32(message[j+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let t1 = hh &+ s1 &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let t2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - $0 * 8)) } }
    }
}
