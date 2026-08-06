// Memory.swift - native RAM usage (percent) via Mach host_statistics64.
// Works on any architecture, no helper process, no sudo.
import Foundation

enum Memory {
    static func usagePercent() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return .nan }

        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0, total > 0 else { return .nan }

        let used = (UInt64(stats.active_count)
                  + UInt64(stats.wire_count)
                  + UInt64(stats.compressor_page_count)) * UInt64(vm_page_size)
        let pct = Double(used) / Double(total) * 100.0
        guard pct >= 0, pct <= 100 else { return .nan }
        return pct
    }
}
