import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

// MARK: - Models

struct CPUStats {
    var total: Double
    var user: Double
    var system: Double
    var cores: [Double]
    var load: [Double]
}

struct MemoryStats {
    var total: Double
    var used: Double
    var app: Double
    var wired: Double
    var compressed: Double
    var cached: Double
    var pressure: Int32
    var swapUsed: Double
    var swapTotal: Double

    var fraction: Double { total > 0 ? used / total : 0 }
    var pressureLabel: String {
        switch pressure {
        case 4: return "Critical"
        case 2: return "Warning"
        default: return "Normal"
        }
    }
}

struct GPUStats {
    var name: String
    var cores: Int?
    var utilization: Double
}

struct DiskStats {
    var name: String
    var total: Double
    var free: Double
    var readPerSecond: Double
    var writePerSecond: Double

    var used: Double { max(total - free, 0) }
    var fraction: Double { total > 0 ? used / total : 0 }
}

struct NetworkStats {
    var interface: String?
    var kind: String
    var address: String?
    var down: Double
    var up: Double
    var totalDown: Double
    var totalUp: Double
}

struct BatteryStats {
    var level: Double
    var onAC: Bool
    var isCharging: Bool
    var isCharged: Bool
    var minutesRemaining: Int?
    var cycles: Int?
    var health: Double?
    var adapterWatts: Int?

    var stateLabel: String {
        if isCharged { return "Fully charged" }
        if isCharging { return "Charging" }
        if onAC { return "Not charging" }
        return "On battery"
    }
}

struct ProcessRow: Identifiable {
    var pid: Int32
    var name: String
    var cpu: Double
    var memory: Double
    var id: Int32 { pid }
}

// MARK: - Helpers

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

private func registryProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return properties?.takeRetainedValue() as? [String: Any]
}

private func forEachService(_ className: String, _ body: (io_registry_entry_t) -> Void) {
    var iterator = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iterator) }
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        body(entry)
        IOObjectRelease(entry)
    }
}

private func rate(_ now: UInt64, _ before: UInt64, over seconds: Double) -> Double {
    guard seconds > 0, now >= before else { return 0 }
    return Double(now - before) / seconds
}

// MARK: - CPU

/// Per-core busy time from the Mach host's tick counters, measured between two reads.
final class CPUReader {
    let name = Sysctl.string("machdep.cpu.brand_string") ?? "CPU"
    let performanceCores = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
    let efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0

    private let host = mach_host_self()
    private var previous: [[UInt32]] = []

    func read() -> CPUStats? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            current.append([CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE].map {
                UInt32(bitPattern: info[base + Int($0)])
            })
        }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        var cores: [Double] = []
        var user = 0.0, system = 0.0, all = 0.0
        for (now, before) in zip(current, previous) {
            let coreUser = Double(now[0] &- before[0]) + Double(now[3] &- before[3])
            let coreSystem = Double(now[1] &- before[1])
            let coreAll = coreUser + coreSystem + Double(now[2] &- before[2])
            cores.append(coreAll > 0 ? (coreUser + coreSystem) / coreAll : 0)
            user += coreUser
            system += coreSystem
            all += coreAll
        }

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        guard all > 0 else { return CPUStats(total: 0, user: 0, system: 0, cores: cores, load: load) }
        return CPUStats(total: (user + system) / all, user: user / all, system: system / all, cores: cores, load: load)
    }
}

// MARK: - Memory

/// Uses the same breakdown as Activity Monitor: used = app + wired + compressed.
final class MemoryReader {
    private let host = mach_host_self()
    private let pageSize = Double(getpagesize())
    private let total = Double(ProcessInfo.processInfo.physicalMemory)

    func read() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let app = Double(stats.internal_page_count &- stats.purgeable_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let cached = Double(stats.external_page_count + stats.purgeable_count) * pageSize

        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        return MemoryStats(total: total, used: min(app + wired + compressed, total), app: app, wired: wired,
                           compressed: compressed, cached: cached, pressure: pressure,
                           swapUsed: Double(swap.xsu_used), swapTotal: Double(swap.xsu_total))
    }
}

// MARK: - GPU

/// Reads the utilization the GPU driver publishes in the IORegistry.
final class GPUReader {
    func read() -> GPUStats? {
        var best: GPUStats?
        forEachService("IOAccelerator") { entry in
            guard let properties = registryProperties(entry),
                  let performance = properties["PerformanceStatistics"] as? [String: Any],
                  let percent = (performance["Device Utilization %"] ?? performance["GPU Activity(%)"]) as? NSNumber
            else { return }
            let name = (properties["model"] as? String)
                ?? Sysctl.string("machdep.cpu.brand_string").map { "\($0) GPU" }
                ?? "GPU"
            let stats = GPUStats(name: name, cores: (properties["gpu-core-count"] as? NSNumber)?.intValue,
                                 utilization: min(percent.doubleValue / 100, 1))
            if best == nil || stats.utilization > best!.utilization { best = stats }
        }
        return best
    }
}

// MARK: - Disk

/// Capacity of the startup volume plus read/write throughput summed over every block storage driver.
final class DiskReader {
    private var previous: (read: UInt64, write: UInt64, time: TimeInterval)?

    func read() -> DiskStats? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage.map(Double.init)
            ?? Double(values.volumeAvailableCapacity ?? 0)

        var read: UInt64 = 0, write: UInt64 = 0
        forEachService("IOBlockStorageDriver") { entry in
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        let now = ProcessInfo.processInfo.systemUptime
        var readRate = 0.0, writeRate = 0.0
        if let previous {
            readRate = rate(read, previous.read, over: now - previous.time)
            writeRate = rate(write, previous.write, over: now - previous.time)
        }
        previous = (read, write, now)

        return DiskStats(name: values.volumeName ?? "Macintosh HD", total: Double(total), free: free,
                         readPerSecond: readRate, writePerSecond: writeRate)
    }
}

// MARK: - Network

/// Traffic on the primary interface (the one carrying the default route), from 64-bit interface counters.
final class NetworkReader {
    private let store = SCDynamicStoreCreate(nil, "Readout" as CFString, nil, nil)
    private var previous: (interface: String, down: UInt64, up: UInt64, time: TimeInterval)?
    private var totalDown = 0.0, totalUp = 0.0
    private var displayNames: [String: String] = [:]

    func read() -> NetworkStats {
        let interface = primaryInterface()
        let now = ProcessInfo.processInfo.systemUptime
        var down = 0.0, up = 0.0

        if let interface, let counters = interfaceCounters()[interface] {
            if let previous, previous.interface == interface {
                down = rate(counters.down, previous.down, over: now - previous.time)
                up = rate(counters.up, previous.up, over: now - previous.time)
                totalDown += down * (now - previous.time)
                totalUp += up * (now - previous.time)
            }
            previous = (interface, counters.down, counters.up, now)
        } else {
            previous = nil
        }

        return NetworkStats(interface: interface, kind: interface.map(displayName) ?? "Offline",
                            address: interface.flatMap(ipv4Address), down: down, up: up,
                            totalDown: totalDown, totalUp: totalUp)
    }

    private func primaryInterface() -> String? {
        guard let store,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    private func displayName(_ interface: String) -> String {
        if let cached = displayNames[interface] { return cached }
        var name = interface.hasPrefix("utun") ? "VPN" : interface
        for item in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        where SCNetworkInterfaceGetBSDName(item) as String? == interface {
            if let localized = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? { name = localized }
        }
        displayNames[interface] = name
        return name
    }

    private func ipv4Address(_ interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    private func interfaceCounters() -> [String: (down: UInt64, up: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (down: UInt64, up: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        result[String(cString: name)] = (info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }
}

// MARK: - Battery

final class BatteryReader {
    func read() -> BatteryStats? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery" else { continue }

            let current = (description["Current Capacity"] as? NSNumber)?.doubleValue ?? 0
            let max = (description["Max Capacity"] as? NSNumber)?.doubleValue ?? 100
            let onAC = description["Power Source State"] as? String == "AC Power"
            let charging = description["Is Charging"] as? Bool ?? false
            let charged = description["Is Charged"] as? Bool ?? false
            let minutes = (description[charging ? "Time to Full Charge" : "Time to Empty"] as? NSNumber)?.intValue

            var stats = BatteryStats(level: max > 0 ? current / max : 0, onAC: onAC, isCharging: charging,
                                     isCharged: charged, minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil)
            readSmartBattery(into: &stats)
            if onAC, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                stats.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
            }
            return stats
        }
        return nil
    }

    private func readSmartBattery(into stats: inout BatteryStats) {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return }
        defer { IOObjectRelease(entry) }
        guard let properties = registryProperties(entry) else { return }

        stats.cycles = (properties["CycleCount"] as? NSNumber)?.intValue
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        let design = (properties["DesignCapacity"] ?? data["DesignCapacity"]) as? NSNumber
        let full = (properties["AppleRawMaxCapacity"] ?? properties["NominalChargeCapacity"]
                    ?? data["NominalChargeCapacity"]) as? NSNumber
        if let design, let full, design.doubleValue > 0 {
            stats.health = min(full.doubleValue / design.doubleValue, 1)
        }
    }
}

// MARK: - Processes

enum ProcessReader {
    /// Process names left out of the lists (set by `--snapshot --exclude`).
    static var excluded: Set<String> = []

    /// One `ps` snapshot, returned as the top processes by CPU and by memory.
    static func top(_ limit: Int = 5) -> (cpu: [ProcessRow], memory: [ProcessRow]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ([], []) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let rows: [ProcessRow] = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), pid != ownPID, !excluded.contains(String(fields[3])),
                  let cpu = Double(fields[1]), let rss = Double(fields[2]) else { return nil }
            return ProcessRow(pid: pid, name: String(fields[3]), cpu: cpu, memory: rss * 1024)
        }
        return (Array(rows.sorted { $0.cpu > $1.cpu }.prefix(limit)),
                Array(rows.sorted { $0.memory > $1.memory }.prefix(limit)))
    }
}
