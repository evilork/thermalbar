// SystemProbe.swift - reads every sensor natively (no helper process, no sudo, no network):
//   CPU temperature  - IOKit HID die sensors (fallback: SMC Tp*/Te* keys)
//   GPU temperature  - SMC Tg* keys          whole-system power - SMC PSTR
//   fans             - SMC F<n>Ac / F<n>Mx    GPU clock/load, CPU/GPU power - IOReport
//   memory           - host_statistics64, vm.swapusage, kern.memorystatus_*
//   thermal pressure - com.apple.system.thermalpressurelevel
// Not thread-safe by design: create, read and close it on one serial queue.
import Darwin
import Foundation

final class SystemProbe {
    private struct SMCKey {
        let name: String
        let type: UInt32
        let size: UInt32
    }

    private struct FanKeys {
        let rpm: SMCKey
        let max: SMCKey
    }

    let chipName: String
    private(set) var gpuMaxMHz: Double = 0

    private let log: (String) -> Void
    private let host: mach_port_t = mach_host_self()
    private var pageSize: UInt64 = 16_384
    private var memTotal: UInt64?
    private var thermalToken: Int32 = 0
    private var hasThermalToken = false
    private var smcOK = false
    private var perfOK = false
    private var gpuTempKeys: [SMCKey] = []
    private var cpuTempKeys: [SMCKey] = []
    private var powerKey: SMCKey?
    private var fans: [FanKeys] = []
    private var closed = false

    init(log: @escaping (String) -> Void) {
        self.log = log
        chipName = SystemProbe.chipName()
        memTotal = SystemProbe.sysctlInteger("hw.memsize", as: UInt64.self)

        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 { pageSize = UInt64(size) }

        if notify_register_check("com.apple.system.thermalpressurelevel", &thermalToken) == UInt32(NOTIFY_STATUS_OK) {
            hasThermalToken = true
        } else {
            log("probe: thermal pressure notifications unavailable, using ProcessInfo.thermalState")
        }

        smcOK = tb_smc_open() == 1
        if smcOK {
            discoverSMCKeys()
        } else {
            log("probe: SMC unavailable (GPU temperature, power and fans hidden)")
        }

        perfOK = tb_perf_open() == 1
        if perfOK {
            gpuMaxMHz = tb_perf_gpu_max_mhz()
            _ = tb_perf_sample()  // primes the first interval
        } else {
            log("probe: IOReport unavailable (GPU clock and load hidden)")
        }
        log("probe: \(chipName), gpu keys \(gpuTempKeys.count), fans \(fans.count), power \(powerKey != nil), gpu max \(Int(gpuMaxMHz)) MHz")
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        if perfOK { tb_perf_close() }
        if smcOK { tb_smc_close() }
        if hasThermalToken { notify_cancel(thermalToken) }
        mach_port_deallocate(mach_task_self_, host)
    }

    func read(now: Date = Date()) -> Snapshot {
        var s = Snapshot.empty(at: now)
        guard !closed else { return s }

        s.cpuTemp = readCPUTemperature()
        if smcOK {
            s.gpuTemp = average(of: gpuTempKeys, in: 1...130)
            if let key = powerKey, let w = read(key), w >= 0, w < 1000 { s.power = w }
            s.fans = readFans()
        }
        if perfOK {
            let p = tb_perf_sample()
            if p.gpuValid == 1 {
                s.gpuActive = min(max(p.gpuActive, 0), 1)
                s.gpuFreqMHz = p.gpuFreqMHz > 0 ? p.gpuFreqMHz : nil
            }
            if p.cpuPowerW >= 0, p.cpuPowerW < 1000 { s.cpuPower = p.cpuPowerW }
            if p.gpuPowerW >= 0, p.gpuPowerW < 1000 { s.gpuPower = p.gpuPowerW }
        }

        s.memTotal = memTotal
        s.memUsed = readMemoryUsed()
        s.swapUsed = readSwapUsed()
        if let level = SystemProbe.sysctlInteger("kern.memorystatus_vm_pressure_level", as: Int32.self) {
            s.memPressure = MemoryPressure(kernelLevel: Int(level))
        }
        if let free = SystemProbe.sysctlInteger("kern.memorystatus_level", as: Int32.self), (0...100).contains(free) {
            s.memPressurePercent = Double(100 - free)
        }
        s.thermal = readThermal()
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        return s
    }

    // MARK: - Temperatures

    private func readCPUTemperature() -> Double? {
        if let sensors = readTemperatureSensors() {
            var die: [Double] = []
            var package: [Double] = []
            for (rawName, number) in sensors {
                let v = number.doubleValue
                guard v > 0, v < 130 else { continue }
                let name = rawName.lowercased()
                if name.contains("tdie") || name.contains("cpu") || name.contains("soc") {
                    die.append(v)
                } else if name.contains("tdev") {
                    package.append(v)
                }
            }
            if let avg = mean(die) ?? mean(package) { return avg }
        }
        return smcOK ? average(of: cpuTempKeys, in: 1...130) : nil
    }

    private func average(of keys: [SMCKey], in range: ClosedRange<Double>) -> Double? {
        mean(keys.compactMap { read($0) }.filter { range.contains($0) })
    }

    private func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    // MARK: - SMC

    private func discoverSMCKeys() {
        let flt = tb_smc_fourcc("flt ")
        let sp78 = tb_smc_fourcc("sp78")
        let count = Int(tb_smc_key_count())
        var buffer = [CChar](repeating: 0, count: 5)
        for index in 0..<count {
            guard tb_smc_key_at(Int32(index), &buffer) == 1 else { continue }
            let name = String(cString: buffer)
            let isGPU = name.hasPrefix("Tg")
            let isCPU = name.hasPrefix("Tp") || name.hasPrefix("Te")
            guard isGPU || isCPU, let key = info(name) else { continue }
            guard (key.type == flt && key.size == 4) || (key.type == sp78 && key.size == 2) else { continue }
            if isGPU { gpuTempKeys.append(key) } else { cpuTempKeys.append(key) }
        }
        powerKey = info("PSTR")

        let fanNumber = tb_smc_read("FNum")
        let fanCount = fanNumber.isFinite ? min(max(Int(fanNumber), 0), 8) : 0
        for i in 0..<fanCount {
            if let rpm = info("F\(i)Ac"), let max = info("F\(i)Mx") {
                fans.append(FanKeys(rpm: rpm, max: max))
            }
        }
    }

    private func info(_ name: String) -> SMCKey? {
        var type: UInt32 = 0
        var size: UInt32 = 0
        guard tb_smc_key_info(name, &type, &size) == 1 else { return nil }
        return SMCKey(name: name, type: type, size: size)
    }

    private func read(_ key: SMCKey) -> Double? {
        let v = tb_smc_read_known(key.name, key.type, key.size)
        return v.isFinite ? v : nil
    }

    private func readFans() -> [FanReading] {
        fans.compactMap { keys in
            guard let rpm = read(keys.rpm), let max = read(keys.max), max > 0, rpm >= 0, rpm < 20_000 else { return nil }
            return FanReading(rpm: rpm, maxRPM: max)
        }
    }

    // MARK: - Memory

    private func readMemoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // Same formula as Activity Monitor's "Memory Used": app memory + wired + compressed.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let pages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * pageSize
    }

    private func readSwapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    // MARK: - Thermal pressure

    private func readThermal() -> ThermalPressure {
        if hasThermalToken {
            var state: UInt64 = 0
            if notify_get_state(thermalToken, &state) == UInt32(NOTIFY_STATUS_OK) {
                return ThermalPressure(rawState: state)
            }
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .moderate
        case .serious: return .heavy
        case .critical: return .trapping
        @unknown default: return .nominal
        }
    }

    // MARK: - sysctl

    static func sysctlInteger<T: FixedWidthInteger>(_ name: String, as type: T.Type) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func chipName() -> String {
        sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
    }
}
