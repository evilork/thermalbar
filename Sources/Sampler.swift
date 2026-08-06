// Sampler.swift - sensor source per architecture:
//
//   Apple Silicon (arm64):
//     CPU temp         - native, via IOKit HID (always available, no sudo).
//     GPU temp, power, RAM usage - from the macmon HTTP server
//                        (http://127.0.0.1:PORT/json), if running.
//
//   Intel (x86_64, incl. hackintosh with VirtualSMC + SMCProcessor/SMCRadeonGPU):
//     CPU/GPU temp     - SMC keys via AppleSMC user client (no sudo).
//     RAM usage        - native, via Mach host_statistics64.
//     Power            - CPU package watts via a root powermetrics LaunchDaemon
//                        (optional; installed by install.sh).
import Foundation

struct Sample {
    var cpuTemp: Double
    var gpuTemp: Double
    var power: Double
    var ramUsage: Double   // percent 0-100
}

enum Sampler {
    static func read() -> Sample? {
        #if arch(arm64)
        let cpu = readCPUNative()
        let (gpu, pwr, ram) = readHTTP()
        #else
        let cpu = readCPUSMC()
        let gpu = readGPUSMC()
        let pwr = readPowerFile()
        let ram = Memory.usagePercent()
        #endif
        if cpu.isNaN && gpu.isNaN && pwr.isNaN && ram.isNaN { return nil }
        return Sample(cpuTemp: cpu, gpuTemp: gpu, power: pwr, ramUsage: ram)
    }

    // MARK: Intel (x86_64) - SMC keys

    // First matching key wins. Real Intel Macs expose TCXC/TC0P/TC0D;
    // hackintosh SMCProcessor.kext publishes per-core TC0C, TC1C, ...
    private static let cpuSMCKeys = ["TCXC", "TC0D", "TC0E", "TC0F", "TC0P", "TC0H", "TC0c"]
    private static let gpuSMCKeys = ["TG0D", "TG0P", "TG0M", "TG0H", "TG0d"]

    private static func smcTemp(_ keys: [String]) -> Double {
        for key in keys {
            let v = readSMCTemperature(key)
            if v.isFinite, v > 0, v < 130 { return v }
        }
        return .nan
    }

    private static func readCPUSMC() -> Double {
        let primary = smcTemp(cpuSMCKeys)
        if primary.isFinite { return primary }
        // Fallback: average per-core keys TC0C..TC15C (SMCProcessor on hackintosh).
        var vals: [Double] = []
        for i in 0..<16 {
            let key = "TC" + String(i, radix: 16, uppercase: true) + "C"
            let v = readSMCTemperature(key)
            if v.isFinite, v > 0, v < 130 { vals.append(v) }
        }
        return vals.isEmpty ? .nan : vals.reduce(0, +) / Double(vals.count)
    }

    private static func readGPUSMC() -> Double {
        smcTemp(gpuSMCKeys)
    }

    // MARK: Intel (x86_64) - CPU package power via powermetrics helper daemon
    //
    // A root LaunchDaemon (com.evilork.thermalbar.power, set up by install.sh)
    // streams `powermetrics --samplers cpu_power` and atomically writes the
    // latest package power (watts) to /var/tmp/thermalbar-power.
    // If the daemon isn't installed or the file is stale, power stays hidden.

    private static let powerFile = "/var/tmp/thermalbar-power"

    private static func readPowerFile() -> Double {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: powerFile),
            let mtime = attrs[.modificationDate] as? Date,
            Date().timeIntervalSince(mtime) < 10,
            let text = try? String(contentsOfFile: powerFile, encoding: .utf8),
            let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            v >= 0, v < 2000
        else { return .nan }
        return v
    }

    #if arch(arm64)
    // MARK: Apple Silicon - CPU via IOKit HID

    private static let macmonPort = 9090
    private static var endpoint: URL { URL(string: "http://127.0.0.1:\(macmonPort)/json")! }

    private static func readCPUNative() -> Double {
        guard let dict = readTemperatureSensors(), !dict.isEmpty else { return .nan }
        var vals: [Double] = []
        for (rawName, num) in dict {
            let v = num.doubleValue
            guard v > 0, v < 130 else { continue }
            let n = rawName.lowercased()
            if n.contains("tdie") || n.contains("cpu") || n.contains("soc") { vals.append(v) }
        }
        // Fallback to package sensors if no die sensors matched.
        if vals.isEmpty {
            for (rawName, num) in dict {
                let v = num.doubleValue
                if v > 0, v < 130, rawName.lowercased().contains("tdev") { vals.append(v) }
            }
        }
        return vals.isEmpty ? .nan : vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: Apple Silicon - GPU + power + RAM via macmon HTTP

    private static func readHTTP() -> (gpu: Double, power: Double, ram: Double) {
        var gpu = Double.nan
        var pwr = Double.nan
        var ram = Double.nan

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 1.5
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        let task = URLSession.shared.dataTask(with: req) { d, _, _ in
            data = d
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2.0)

        guard
            let d = data,
            let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return (gpu, pwr, ram) }

        if let temp = obj["temp"] as? [String: Any],
           let g = temp["gpu_temp_avg"] as? Double, g > 0, g < 130 {
            gpu = g
        }
        if let p = obj["sys_power"] as? Double, p >= 0 {
            pwr = p
        }
        if let mem = obj["memory"] as? [String: Any],
           let used = (mem["ram_usage"] as? Double) ?? (mem["ram_usage"] as? NSNumber)?.doubleValue,
           let total = (mem["ram_total"] as? Double) ?? (mem["ram_total"] as? NSNumber)?.doubleValue,
           total > 0 {
            let pct = used / total * 100.0
            if pct >= 0, pct <= 100 { ram = pct }
        }
        return (gpu, pwr, ram)
    }
    #endif
}
