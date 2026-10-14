import Darwin
import Foundation

enum ProfileMemoryDiagnostics {
    #if DEBUG
    private static var source: DispatchSourceTimer?

    static func startIfRequested() {
        guard source == nil,
            let value = ProcessInfo.processInfo.environment["LOAF_PROFILE_MEMORY_FD"],
            let descriptor = Int32(value), descriptor > 2,
            fcntl(descriptor, F_GETFD) != -1
        else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let header = "seconds,pid,physical_mib,resident_mib,internal_mib,compressed_mib,device_mib,graphics_mib,graphics_compressed_mib,media_mib,media_compressed_mib,purgeable_nonvolatile_mib,purgeable_nonvolatile_compressed_mib,purgeable_volatile_mib,purgeable_volatile_compressed_mib,network_mib,network_compressed_mib\n"
        do { try handle.write(contentsOf: Data(header.utf8)) } catch { return }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "loaf.profile-memory-trace", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler {
            guard let row = Self.row(since: start) else { return }
            try? handle.write(contentsOf: row)
        }
        source = timer
        timer.resume()
    }

    nonisolated private static func row(since start: TimeInterval) -> Data? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        // Darwin's sizeof-based revision macros are not imported into Swift.
        let ledgerBytes = MemoryLayout<task_vm_info_data_t>.offset(of: \.limit_bytes_remaining)!
        guard status == KERN_SUCCESS, Int(count) * MemoryLayout<integer_t>.size >= ledgerBytes else { return nil }
        let values: [Double] = [
            Double(info.phys_footprint), Double(info.resident_size), Double(info.internal),
            Double(info.compressed), Double(info.device), Double(info.ledger_tag_graphics_footprint),
            Double(info.ledger_tag_graphics_footprint_compressed), Double(info.ledger_tag_media_footprint),
            Double(info.ledger_tag_media_footprint_compressed),
            Double(info.ledger_purgeable_nonvolatile), Double(info.ledger_purgeable_novolatile_compressed),
            Double(info.ledger_purgeable_volatile), Double(info.ledger_purgeable_volatile_compressed),
            Double(info.ledger_tag_network_nonvolatile), Double(info.ledger_tag_network_nonvolatile_compressed),
        ]
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start)
        let columns = values.map { String(format: "%.3f", $0 / 1_048_576) }.joined(separator: ",")
        return Data("\(elapsed),\(getpid()),\(columns)\n".utf8)
    }
    #else
    static func startIfRequested() {}
    #endif
}
