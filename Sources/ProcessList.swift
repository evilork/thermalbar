// ProcessList.swift - "which apps load the Mac": ps output parsed and grouped by app bundle.
// The parser is pure; ProcessSampler runs /bin/ps (executable path only, never args or env).
import Foundation

struct ProcessSample: Equatable {
    var pid: Int32
    var cpuPercent: Double
    var rssBytes: UInt64
    var path: String
}

struct AppUsage: Identifiable, Equatable {
    /// Grouping key: the app bundle path, or the executable path for plain binaries.
    let id: String
    let name: String
    let appPath: String?
    let cpuPercent: Double
    let memoryBytes: UInt64
}

enum ProcessParser {
    /// Parses lines "pid pcpu rssKB path" (the path may hold spaces). Bad lines are skipped.
    static func parse(_ psOutput: String) -> [ProcessSample] {
        var out: [ProcessSample] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            guard let sample = parseLine(Substring(rawLine)) else { continue }
            out.append(sample)
        }
        return out
    }

    private static func parseLine(_ line: Substring) -> ProcessSample? {
        var rest = line[...]
        guard let pidText = nextField(&rest),
              let cpuText = nextField(&rest),
              let rssText = nextField(&rest) else { return nil }
        let path = rest.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty,
              let pid = Int32(pidText), pid > 0,
              let cpu = Double(cpuText.replacingOccurrences(of: ",", with: ".")), cpu.isFinite, cpu >= 0,
              let rssKB = UInt64(rssText) else { return nil }
        let (bytes, overflow) = rssKB.multipliedReportingOverflow(by: 1024)
        return ProcessSample(pid: pid, cpuPercent: cpu, rssBytes: overflow ? UInt64.max : bytes, path: path)
    }

    /// Takes the next whitespace-separated field off the front of `text`.
    private static func nextField(_ text: inout Substring) -> String? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let tail = text[start...]
        let end = tail.firstIndex(where: { $0.isWhitespace }) ?? tail.endIndex
        let field = String(tail[..<end])
        text = tail[end...]
        return field
    }

    /// Maps an executable to the app it belongs to. Helper apps nested in Frameworks/Helpers/LoginItems
    /// fold into the outer app ("Google Chrome Helper (Renderer)" -> "Google Chrome"); an app placed
    /// directly in another app's Contents or Applications folder is its own app (WarThunderLauncher's
    /// WarThunder.app, Xcode's Simulator.app).
    static func appIdentity(forExecutable path: String) -> (id: String, name: String, appPath: String?) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var chosen: Int?
        for (i, part) in parts.enumerated() where part.hasSuffix(".app") && part.count > 4 {
            guard let current = chosen else {
                chosen = i
                continue
            }
            let parent = parts[i - 1]
            if i - 1 > current, parent == "Contents" || parent == "Applications" {
                chosen = i
            } else {
                break
            }
        }
        if let i = chosen {
            let appPath = parts[0...i].joined(separator: "/")
            let name = String(parts[i].dropLast(4))
            return (appPath, name, appPath)
        }
        let name = parts.last(where: { !$0.isEmpty }) ?? path
        return (path, name, nil)
    }

    /// Sums CPU and memory per app. `footprint` gives phys_footprint for a pid when readable; RSS otherwise.
    static func group(_ samples: [ProcessSample], footprint: (Int32) -> UInt64?) -> [AppUsage] {
        struct Acc {
            var name: String
            var appPath: String?
            var cpu: Double
            var memory: UInt64
        }
        var byID: [String: Acc] = [:]
        for s in samples {
            let ident = appIdentity(forExecutable: s.path)
            let mem = footprint(s.pid) ?? s.rssBytes
            var acc = byID[ident.id] ?? Acc(name: ident.name, appPath: ident.appPath, cpu: 0, memory: 0)
            acc.cpu += s.cpuPercent
            let (sum, overflow) = acc.memory.addingReportingOverflow(mem)
            acc.memory = overflow ? UInt64.max : sum
            byID[ident.id] = acc
        }
        return byID.map { id, acc in
            AppUsage(id: id, name: acc.name, appPath: acc.appPath, cpuPercent: acc.cpu, memoryBytes: acc.memory)
        }
        .sorted { $0.id < $1.id }
    }

    /// The `count` heaviest apps by CPU or memory; apps with zero use are left out.
    static func top(_ apps: [AppUsage], byMemory: Bool, count: Int) -> [AppUsage] {
        guard count > 0 else { return [] }
        let used = apps.filter { byMemory ? $0.memoryBytes > 0 : $0.cpuPercent > 0 }
        let sorted = used.sorted { a, b in
            if byMemory {
                if a.memoryBytes != b.memoryBytes { return a.memoryBytes > b.memoryBytes }
            } else if a.cpuPercent != b.cpuPercent {
                return a.cpuPercent > b.cpuPercent
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return Array(sorted.prefix(count))
    }
}

/// Collects per-app CPU and memory use. Call from a background queue (it waits for ps).
final class ProcessSampler {
    private let psURL = URL(fileURLWithPath: "/bin/ps")
    private let timeout: TimeInterval = 2

    init() {}

    func sample() -> [AppUsage] {
        guard let output = runPS() else { return [] }
        let samples = ProcessParser.parse(output)
        return ProcessParser.group(samples) { pid in ProcessSampler.footprint(of: pid) }
    }

    /// Thread-safe holder for the bytes read from ps.
    private final class Output {
        private let lock = NSLock()
        private var data = Data()

        func set(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func get() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private func runPS() -> String? {
        let process = Process()
        process.executableURL = psURL
        // Executable path only: the args and env columns may hold secrets.
        process.arguments = ["-Ao", "pid=,pcpu=,rss=,comm="]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read concurrently: ps output is larger than the pipe buffer.
        let output = Output()
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            done.leave()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 0.5)
            return nil
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: output.get(), encoding: .utf8)
    }

    /// Memory as Activity Monitor counts it; nil for processes we may not inspect.
    private static func footprint(of pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, raw)
            }
        }
        guard result == 0, info.ri_phys_footprint > 0 else { return nil }
        return info.ri_phys_footprint
    }
}
