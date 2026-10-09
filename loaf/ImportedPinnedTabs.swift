import Compression
import Foundation

nonisolated enum ImportedPinnedTabs {
    private static let limit = 50_000_000
    static func firefox(_ input: Data) throws -> [SavedTab] {
        var data = input
        if input.starts(with: Data([0x6d, 0x6f, 0x7a, 0x4c, 0x7a, 0x34, 0x30, 0])) {
            guard input.count > 12 else { throw invalid() }
            let size = integer(input, at: 8)
            guard size > 0, size <= limit else { throw invalid() }
            var output = Data(count: size)
            let count = output.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, size,
                        source.bindMemory(to: UInt8.self).baseAddress! + 12, input.count - 12, nil, COMPRESSION_LZ4_RAW)
                }
            }
            guard count == size else { throw invalid() }
            data = output
        }
        guard data.count <= limit,
            let session = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let windows = session["windows"] as? [[String: Any]]
        else { throw invalid() }
        var tabs: [SavedTab] = []
        for window in windows.prefix(100) {
            for tab in (window["tabs"] as? [[String: Any]] ?? []).prefix(10_000) where tab["pinned"] as? Bool == true {
                guard let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
                let index = (tab["index"] as? Int ?? entries.count) - 1
                guard entries.indices.contains(index), let address = entries[index]["url"] as? String,
                    ChatGPTProtocol.safeSourceURL(address) != nil
                else { continue }
                tabs.append(
                    SavedTab(
                        title: entries[index]["title"] as? String ?? address, address: address,
                        pinned: true, pinnedAddress: address))
                if tabs.count == 500 { return tabs }
            }
        }
        return tabs
    }



    static func chromium(_ data: Data) throws -> [SavedTab] {
        guard data.count >= 8, data.count <= limit, data.starts(with: Data("SNSS".utf8)) else { throw invalid() }
        let version = integer(data, at: 4)
        guard version == 1 || version == 3 else {
            throw ProfileImport.Failure(
                message: "This browser’s session is encrypted or uses an unsupported format; pinned tabs weren’t read.")
        }
        struct Tab {
            var pinned = false
            var window = 0
            var position = 0
            var selected: Int?
            var navigations: [Int: (String, String)] = [:]
        }
        var tabs: [Int: Tab] = [:]
        var offset = 8
        while offset < data.count {
            guard offset + 2 <= data.count else { throw invalid() }
            let size = Int(data[offset]) | Int(data[offset + 1]) << 8
            offset += 2
            guard size >= 1, offset + size <= data.count else { throw invalid() }
            let command = data[offset]
            let payload = data.subdata(in: offset + 1..<offset + size)
            offset += size
            guard payload.count >= 4 else { continue }
            let id = integer(payload, at: 0)
            switch command {
            case 0 where payload.count >= 8:
                tabs[integer(payload, at: 4), default: Tab()].window = id
            case 2 where payload.count >= 8:
                tabs[id, default: Tab()].position = integer(payload, at: 4)
            case 7 where payload.count >= 8:
                tabs[id, default: Tab()].selected = integer(payload, at: 4)
            case 12 where payload.count >= 5:
                tabs[id, default: Tab()].pinned = payload[4] != 0
            case 3, 16:
                tabs.removeValue(forKey: id)
            case 4, 17:
                tabs = tabs.filter { $0.value.window != id }
            case 6 where payload.count >= 16:
                let tabID = integer(payload, at: 4)
                let navigation = integer(payload, at: 8)
                var cursor = 12
                guard let address = string(payload, cursor: &cursor, utf16: false),
                    let title = string(payload, cursor: &cursor, utf16: true),
                    ChatGPTProtocol.safeSourceURL(address) != nil
                else { continue }
                tabs[tabID, default: Tab()].navigations[navigation] = (address, title)
            default: break
            }
            guard tabs.count <= 10_000 else { throw invalid() }
        }
        return tabs.sorted {
            let left = ($0.value.window, $0.value.position, $0.key)
            let right = ($1.value.window, $1.value.position, $1.key)
            return left < right
        }.compactMap { _, tab in
            guard tab.pinned, let index = tab.selected ?? tab.navigations.keys.max(),
                let (address, title) = tab.navigations[index]
            else { return nil }
            return SavedTab(
                title: title.isEmpty ? address : title, address: address, pinned: true, pinnedAddress: address)
        }.prefix(500).map { $0 }
    }
    private static func string(_ data: Data, cursor: inout Int, utf16: Bool) -> String? {
        guard cursor + 4 <= data.count else { return nil }
        let length = integer(data, at: cursor)
        cursor += 4
        let bytes = length * (utf16 ? 2 : 1)
        guard length >= 0, bytes <= 32_768, cursor + bytes <= data.count else { return nil }
        let value = String(
            data: data.subdata(in: cursor..<cursor + bytes), encoding: utf16 ? .utf16LittleEndian : .utf8)
        cursor += (bytes + 3) & ~3
        return value
    }
    private static func integer(_ data: Data, at offset: Int) -> Int {
        let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
        return Int(Int32(bitPattern: value))
    }
    private static func invalid() -> ProfileImport.Failure {
        .init(message: "The saved session is incomplete or unsupported; pinned tabs weren’t read.")
    }
}
