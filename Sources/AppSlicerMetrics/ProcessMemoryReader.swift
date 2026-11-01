import Darwin

/// A process's memory footprint, the value shown in Activity Monitor's Memory column.
public struct ProcessMemory: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let footprintBytes: UInt64

    public init(pid: Int32, name: String, footprintBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.footprintBytes = footprintBytes
    }
}

public struct ProcessMemoryReport: Equatable, Sendable {
    /// Sorted by footprint, largest first.
    public let processes: [ProcessMemory]
    /// Processes the current user lacks permission to read, such as system services.
    public let unreadableCount: Int

    public init(processes: [ProcessMemory], unreadableCount: Int) {
        self.processes = processes
        self.unreadableCount = unreadableCount
    }
}

/// The combined footprint of an app and its helper processes.
public struct AppMemory: Equatable, Sendable {
    public let name: String
    public let footprintBytes: UInt64
    public let processCount: Int

    public init(name: String, footprintBytes: UInt64, processCount: Int) {
        self.name = name
        self.footprintBytes = footprintBytes
        self.processCount = processCount
    }
}

public struct AppMemoryReport: Equatable, Sendable {
    /// Sorted by footprint, largest first.
    public let apps: [AppMemory]
    /// Readable background services and tools that do not belong to a listed app.
    public let otherFootprintBytes: UInt64
    public let otherProcessCount: Int
    /// Processes the current user lacks permission to read, such as system services.
    public let unreadableCount: Int

    public init(
        apps: [AppMemory],
        otherFootprintBytes: UInt64,
        otherProcessCount: Int,
        unreadableCount: Int
    ) {
        self.apps = apps
        self.otherFootprintBytes = otherFootprintBytes
        self.otherProcessCount = otherProcessCount
        self.unreadableCount = unreadableCount
    }
}

/// Reads per-process memory usage. Without root, other users' processes are not readable.
public struct ProcessMemoryReader: Sendable {
    public init() {}

    public func readTopProcesses(limit: Int) throws -> ProcessMemoryReport {
        let result = try readProcesses(includingPaths: false)
        return ProcessMemoryReport(
            processes: Self.largest(result.processes.map(\.process), limit: limit),
            unreadableCount: result.unreadableCount
        )
    }

    public func readApps(limit: Int) throws -> AppMemoryReport {
        let result = try readProcesses(includingPaths: true)
        var appProcesses: [(name: String, footprintBytes: UInt64)] = []
        var otherFootprintBytes: UInt64 = 0
        var otherProcessCount = 0
        for entry in result.processes {
            if let name = Self.appName(forExecutablePath: entry.path) {
                appProcesses.append((name, entry.process.footprintBytes))
            } else {
                otherFootprintBytes += entry.process.footprintBytes
                otherProcessCount += 1
            }
        }
        return AppMemoryReport(
            apps: Self.grouped(appProcesses, limit: limit),
            otherFootprintBytes: otherFootprintBytes,
            otherProcessCount: otherProcessCount,
            unreadableCount: result.unreadableCount
        )
    }

    /// Returns the app that owns an executable, or `nil` for services and tools. Only the
    /// standard app folders count, because macOS also keeps background services in bundles
    /// elsewhere, such as `/System/Library/CoreServices`. The outermost bundle is used, so
    /// a helper nested inside an app counts toward that app.
    static func appName(forExecutablePath path: String?) -> String? {
        guard let path else { return nil }
        let components = path.split(separator: "/")
        guard let bundleIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }

        let folders = components[..<bundleIndex]
        let isInSystemApps = folders.starts(with: ["System", "Applications"])
        let isInApps = folders.first == "Applications"
        let isInUserApps = folders.count >= 3 && folders.first == "Users"
            && folders[folders.startIndex + 2] == "Applications"
        guard isInSystemApps || isInApps || isInUserApps else { return nil }
        return String(components[bundleIndex].dropLast(4))
    }

    static func grouped(
        _ processes: [(name: String, footprintBytes: UInt64)],
        limit: Int
    ) -> [AppMemory] {
        var totals: [String: (bytes: UInt64, count: Int)] = [:]
        for process in processes {
            let current = totals[process.name] ?? (0, 0)
            totals[process.name] = (current.bytes + process.footprintBytes, current.count + 1)
        }
        let apps = totals
            .map { AppMemory(name: $0.key, footprintBytes: $0.value.bytes, processCount: $0.value.count) }
            .sorted { first, second in
                first.footprintBytes != second.footprintBytes
                    ? first.footprintBytes > second.footprintBytes
                    : first.name < second.name
            }
        return Array(apps.prefix(max(limit, 0)))
    }

    private func readProcesses(
        includingPaths: Bool
    ) throws -> (processes: [(process: ProcessMemory, path: String?)], unreadableCount: Int) {
        var processes: [(process: ProcessMemory, path: String?)] = []
        var unreadableCount = 0

        for pid in try listProcessIDs() {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPointer)
                }
            }
            guard result == 0 else {
                // Any other failure means the process has exited since it was listed.
                if errno == EPERM { unreadableCount += 1 }
                continue
            }
            if usage.ri_phys_footprint > 0 {
                let process = ProcessMemory(
                    pid: pid,
                    name: processName(pid),
                    footprintBytes: usage.ri_phys_footprint
                )
                processes.append((process, includingPaths ? executablePath(pid) : nil))
            }
        }

        return (processes, unreadableCount)
    }

    static func largest(_ processes: [ProcessMemory], limit: Int) -> [ProcessMemory] {
        let sorted = processes.sorted { first, second in
            first.footprintBytes != second.footprintBytes
                ? first.footprintBytes > second.footprintBytes
                : first.pid < second.pid
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    private func listProcessIDs() throws -> [Int32] {
        // The extra room covers processes that start between the two calls.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else {
            throw MetricsError.processListFailed(code: errno)
        }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let byteCount = Int32(pids.count * MemoryLayout<Int32>.stride)
        let count = proc_listallpids(&pids, byteCount)
        guard count > 0 else {
            throw MetricsError.processListFailed(code: errno)
        }
        return Array(pids.prefix(Int(count)))
    }

    private func executablePath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is not available to Swift. This is its value.
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    private func processName(_ pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : "PID \(pid)"
    }
}
