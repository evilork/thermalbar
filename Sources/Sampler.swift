// Sampler.swift - hybrid sensor source:
//   CPU temp        - native, via IOKit HID (always available, no sudo).
//   GPU temp, power, RAM usage - from the macmon HTTP server
//                     (http://127.0.0.1:PORT/json), if running.
//                     If unreachable, those values = NaN and are hidden.
import Foundation

struct Sample {
    var cpuTemp: Double
    var gpuTemp: Double
    var power: Double
    var ramUsage: Double   // percent 0-100
}

enum Sampler {
    static let macmonPort = 9090
    private static var endpoint: URL { URL(string: "http://127.0.0.1:\(macmonPort)/json")! }

    static func read() -> Sample? {
        let cpu = readCPUNative()
        let (gpu, pwr, ram) = readHTTP()
        if cpu.isNaN && gpu.isNaN && pwr.isNaN && ram.isNaN { return nil }
        return Sample(cpuTemp: cpu, gpuTemp: gpu, power: pwr, ramUsage: ram)
    }

    // MARK: CPU - native IOKit

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

    // MARK: GPU + power + RAM - macmon HTTP (single synchronous request, short timeout)

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
}
