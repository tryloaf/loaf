import CryptoKit
import Foundation
import Security
import ZIPFoundation

struct PackageError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
nonisolated enum CRXVerifier {
    struct Verified {
        let id: String
        let zip: Data
        let publicKey: Data
    }
    static let publisherHash = Data([
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe, 0x24, 0x97, 0xcc, 0x9b, 0x04, 0x25, 0x4c,
        0x65, 0x8f, 0x79, 0xf2, 0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf,
    ])
    static func identifier(_ bytes: Data) -> String {
        bytes.map { String(UnicodeScalar(97 + UInt32($0 >> 4))!) + String(UnicodeScalar(97 + UInt32($0 & 15))!) }
            .joined()
    }
    static func verify(_ package: Data, expectedID: String? = nil, requirePublisher: Bool = false) throws -> Verified {
        guard package.count >= 12, package.count <= 50_000_000, package.prefix(4) == Data("Cr24".utf8),
            uint32(package, 4) == 3
        else { throw PackageError(reason: "Only bounded CRX3 packages are supported.") }
        let length = Int(uint32(package, 8))
        guard length > 0, length <= 1_000_000, package.count > 12 + length else {
            throw PackageError(reason: "Invalid CRX3 header length.")
        }
        let header = package.subdata(in: 12..<(12 + length))
        let zip = package.subdata(in: (12 + length)..<package.count)

        for token in [
            Data([0x50, 0x4b, 0x05, 0x06]), Data([0x50, 0x4b, 0x06, 0x07]), Data([0x50, 0x4b, 0x06, 0x06]),
        ] {
            guard header.range(of: token) == nil else {
                throw PackageError(reason: "Ambiguous ZIP directory token in CRX header.")
            }
        }
        let fields = try protobuf(header)
        guard let signed = fields[10000]?.last, let idBytes = try protobuf(signed)[1]?.last, idBytes.count == 16 else {
            throw PackageError(reason: "Missing signed CRX identity.")
        }
        let id = identifier(idBytes)
        guard expectedID == nil || expectedID == id else {
            throw PackageError(reason: "The package identity does not match the requested extension.")
        }
        var message = Data("CRX3 SignedData\0".utf8)
        var size = UInt32(signed.count).littleEndian
        withUnsafeBytes(of: &size) { message.append(contentsOf: $0) }
        message.append(signed)
        message.append(zip)
        var developer: Data?
        var publisher = false
        var proofs = 0
        for field in [2, 3] {
            for proof in fields[field] ?? [] {
                proofs += 1
                guard proofs <= 32 else { throw PackageError(reason: "Too many CRX signatures.") }
                let parts = try protobuf(proof)
                guard let keyData = parts[1]?.last, let signature = parts[2]?.last, keyData.count < 16_384,
                    signature.count < 16_384
                else { throw PackageError(reason: "Incomplete CRX signature.") }
                let key = try publicKey(keyData, rsa: field == 2)
                let algorithm: SecKeyAlgorithm =
                    field == 2 ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
                var error: Unmanaged<CFError>?
                guard SecKeyIsAlgorithmSupported(key, .verify, algorithm),
                    SecKeyVerifySignature(key, algorithm, message as CFData, signature as CFData, &error)
                else { throw PackageError(reason: "CRX3 signature verification failed.") }
                let hash = Data(SHA256.hash(data: keyData))
                if hash.prefix(16) == idBytes { developer = keyData }
                if hash == publisherHash { publisher = true }
            }
        }
        guard let developer, !requirePublisher || publisher else {
            throw PackageError(reason: "Required developer or Chrome Web Store publisher proof is missing.")
        }
        return Verified(id: id, zip: zip, publicKey: developer)
    }
    static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[data.startIndex + offset + $1]) << ($1 * 8) }
    }
    static func protobuf(_ data: Data) throws -> [Int: [Data]] {
        let bytes = [UInt8](data)
        var offset = 0
        var fields: [Int: [Data]] = [:]
        var count = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw PackageError(reason: "Truncated protobuf.") }
                let byte = bytes[offset]
                offset += 1
                if shift == 63 && byte > 1 { throw PackageError(reason: "Overflowing protobuf integer.") }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw PackageError(reason: "Invalid protobuf integer.")
        }
        while offset < bytes.count {
            count += 1
            guard count <= 1024 else { throw PackageError(reason: "Oversized protobuf.") }
            let tag = try varint()
            guard tag >> 3 > 0 && tag >> 3 <= 536_870_911 else { throw PackageError(reason: "Invalid protobuf field.") }
            switch tag & 7 {
            case 0: _ = try varint()
            case 1:
                guard bytes.count - offset >= 8 else { throw PackageError(reason: "Truncated protobuf.") }
                offset += 8
            case 5:
                guard bytes.count - offset >= 4 else { throw PackageError(reason: "Truncated protobuf.") }
                offset += 4
            case 2:
                let size = try varint()
                guard size <= UInt64(bytes.count - offset) else {
                    throw PackageError(reason: "Invalid protobuf length.")
                }
                fields[Int(tag >> 3), default: []].append(Data(bytes[offset..<(offset + Int(size))]))
                offset += Int(size)
            default: throw PackageError(reason: "Unsupported protobuf wire type.")
            }
        }
        return fields
    }
    private static func publicKey(_ spki: Data, rsa: Bool) throws -> SecKey {
        var outer = DERReader(spki)
        let sequence = try outer.take(0x30)
        guard outer.atEnd else { throw PackageError(reason: "Trailing public-key bytes.") }
        var body = DERReader(sequence)
        var algorithm = DERReader(try body.take(0x30))
        let oid = try algorithm.take(0x06)
        let rsaOID = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
        let ecOID = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])
        guard oid == (rsa ? rsaOID : ecOID) else { throw PackageError(reason: "Wrong CRX key algorithm.") }
        if rsa {
            if !algorithm.atEnd {
                guard try algorithm.take(0x05).isEmpty else { throw PackageError(reason: "Invalid RSA parameters.") }
            }
        } else {
            guard try algorithm.take(0x06) == Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]) else {
                throw PackageError(reason: "CRX ECDSA requires P-256.")
            }
        }
        guard algorithm.atEnd else { throw PackageError(reason: "Unexpected key parameters.") }
        let bits = try body.take(0x03)
        guard body.atEnd, bits.first == 0 else { throw PackageError(reason: "Invalid public-key bits.") }
        let raw = Data(bits.dropFirst())
        let type = rsa ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom
        var error: Unmanaged<CFError>?
        guard
            let key = SecKeyCreateWithData(
                raw as CFData, [kSecAttrKeyType: type, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error
            )
        else { throw PackageError(reason: "Unable to decode CRX public key.") }
        return key
    }
    private struct DERReader {
        let data: [UInt8]
        var offset = 0
        init(_ data: Data) { self.data = [UInt8](data) }
        var atEnd: Bool { offset == data.count }
        mutating func take(_ tag: UInt8) throws -> Data {
            guard data.count - offset >= 2, data[offset] == tag else {
                throw PackageError(reason: "Malformed public-key DER.")
            }
            offset += 1
            var length = Int(data[offset])
            offset += 1
            if length & 0x80 != 0 {
                let bytes = length & 0x7f
                guard bytes > 0, bytes <= 4, data.count - offset >= bytes, data[offset] != 0 else {
                    throw PackageError(reason: "Invalid DER length.")
                }
                length = 0
                for _ in 0..<bytes {
                    length = length * 256 + Int(data[offset])
                    offset += 1
                }
                guard length >= 128 else { throw PackageError(reason: "Noncanonical DER length.") }
            }
            guard length <= data.count - offset else { throw PackageError(reason: "Truncated DER.") }
            let value = Data(data[offset..<(offset + length)])
            offset += length
            return value
        }
    }
}

nonisolated enum ExtensionArchive {
    static func extract(_ zip: Data, to destination: URL) throws {
        guard zip.count <= 50_000_000, !FileManager.default.fileExists(atPath: destination.path) else {
            throw PackageError(reason: "Invalid extraction destination or package size.")
        }
        let archive = try Archive(data: zip, accessMode: .read)
        var total: UInt64 = 0
        var count = 0
        var paths = Set<String>()
        for entry in archive {
            count += 1
            guard entry.uncompressedSize <= 200_000_000 - total else {
                throw PackageError(reason: "ZIP extraction size limit.")
            }
            total += entry.uncompressedSize
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard count <= 20_000, total <= 200_000_000, entry.uncompressedSize <= 50_000_000, entry.type != .symlink,
                !entry.path.hasPrefix("/"), !entry.path.contains("\\"), !entry.path.contains("\0"),
                !components.contains(".."), !components.contains("."),
                paths.insert(
                    entry.path.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(
                        in: CharacterSet(charactersIn: "/"))
                ).inserted
            else { throw PackageError(reason: "Unsafe ZIP path, link, duplicate, or extraction limit.") }
        }
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for entry in archive {
                let url = destination.appendingPathComponent(entry.path).standardizedFileURL
                guard url.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                    throw PackageError(reason: "ZIP path escapes the extension folder.")
                }
                if entry.type == .directory {
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    continue
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                guard
                    FileManager.default.createFile(
                        atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                var written: UInt64 = 0
                let checksum = try archive.extract(entry, skipCRC32: false) { chunk in
                    guard UInt64(chunk.count) <= entry.uncompressedSize - written else {
                        throw PackageError(reason: "ZIP data exceeds its declared size.")
                    }
                    written += UInt64(chunk.count)
                    try handle.write(contentsOf: chunk)
                }
                guard checksum == entry.checksum, written == entry.uncompressedSize else {
                    throw PackageError(reason: "ZIP checksum or size mismatch.")
                }
            }
            guard FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path)
            else { throw PackageError(reason: "No manifest at the extension root.") }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

nonisolated enum ChromeStore {
    static func identifier(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "^[a-p]{32}$", options: .regularExpression) != nil { return text }
        guard let url = URL(string: text), url.scheme == "https",
            ["chromewebstore.google.com", "chrome.google.com"].contains(url.host)
        else { return nil }
        return url.pathComponents.last.flatMap {
            $0.range(of: "^[a-p]{32}$", options: .regularExpression) == nil ? nil : $0
        }
    }
    static func packageURL(id: String, version: String) -> URL {
        var url = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        url.queryItems = [
            .init(name: "response", value: "redirect"), .init(name: "prod", value: "chromiumcrx"),
            .init(name: "prodchannel", value: "stable"), .init(name: "os", value: "mac"),
            .init(name: "prodversion", value: version), .init(name: "acceptformat", value: "crx3"),
            .init(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        return url.url!
    }
}
