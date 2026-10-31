import Darwin
import Foundation

public enum MetricsError: Error, Equatable {
    case sysctlFailed(name: String, code: Int32)
    case hostStatisticsFailed(code: Int32)
    case unknownPressureLevel(Int32)
    case processListFailed(code: Int32)
}

/// Reads system-wide memory metrics from the kernel. Does not require root.
public struct SystemMemoryReader: Sendable {
    private let host: mach_port_t
    private let pageSize: UInt64
    private let physicalMemoryBytes: UInt64

    public init() throws {
        // Kept for the reader's lifetime because each `mach_host_self()` adds a port reference.
        host = mach_host_self()
        pageSize = UInt64(try readSysctl("vm.pagesize", initial: Int32(0)))
        physicalMemoryBytes = try readSysctl("hw.memsize", initial: UInt64(0))
    }

    public func read() throws -> MemorySnapshot {
        let statistics = try readHostStatistics()
        let swap = try readSysctl("vm.swapusage", initial: xsw_usage())
        let rawPressure = try readSysctl("kern.memorystatus_vm_pressure_level", initial: Int32(0))
        guard let pressure = MemoryPressureLevel(rawValue: rawPressure) else {
            throw MetricsError.unknownPressureLevel(rawPressure)
        }

        let counters = MemoryCounters(
            pageSize: pageSize,
            physicalMemoryBytes: physicalMemoryBytes,
            internalPages: UInt64(statistics.internal_page_count),
            externalPages: UInt64(statistics.external_page_count),
            purgeablePages: UInt64(statistics.purgeable_count),
            wiredPages: UInt64(statistics.wire_count),
            compressorPages: UInt64(statistics.compressor_page_count),
            freePages: UInt64(statistics.free_count),
            pageouts: statistics.pageouts,
            swapTotalBytes: swap.xsu_total,
            swapUsedBytes: swap.xsu_used,
            pressureLevel: pressure
        )
        return MemorySnapshot(timestamp: Date(), counters: counters)
    }

    private func readHostStatistics() throws -> vm_statistics64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(host, HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MetricsError.hostStatisticsFailed(code: result)
        }
        return statistics
    }
}

func readSysctl<Value>(_ name: String, initial: Value) throws -> Value {
    var value = initial
    var size = MemoryLayout<Value>.size
    let result = withUnsafeMutableBytes(of: &value) { buffer in
        sysctlbyname(name, buffer.baseAddress, &size, nil, 0)
    }
    guard result == 0 else {
        throw MetricsError.sysctlFailed(name: name, code: errno)
    }
    return value
}
