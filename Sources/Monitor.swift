import Foundation
import Combine

enum Module: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .battery: return "Battery"
        }
    }

    var caption: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "MEM"
        case .disk: return "SSD"
        case .network: return "NET"
        case .battery: return "BAT"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.3.layers.3d"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "arrow.up.arrow.down"
        case .battery: return "battery.75percent"
        }
    }
}

enum Series: CaseIterable {
    case cpu, gpu, memory, diskRead, diskWrite, netDown, netUp, battery
}

/// Samples every reader on a background queue and publishes the results on the main thread.
final class Monitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var cpu: CPUStats?
    @Published private(set) var memory: MemoryStats?
    @Published private(set) var gpu: GPUStats?
    @Published private(set) var disk: DiskStats?
    @Published private(set) var network: NetworkStats?
    @Published private(set) var battery: BatteryStats?
    @Published private(set) var topCPU: [ProcessRow] = []
    @Published private(set) var topMemory: [ProcessRow] = []
    @Published private(set) var history: [Series: [Double]] = [:]
    @Published var hidesAddress = false

    let cpuName: String
    let performanceCores: Int
    let efficiencyCores: Int
    let hasBattery: Bool
    let hasGPU: Bool

    var interval: TimeInterval = 2 {
        didSet { if interval != oldValue, timer != nil { schedule() } }
    }
    /// Process lists are only collected while a popover that shows them is open.
    var wantsProcesses = 0 {
        didSet { if wantsProcesses > oldValue { sample() } }
    }
    var onUpdate: (() -> Void)?

    private let queue = DispatchQueue(label: "Readout.sampler", qos: .utility)
    private let cpuReader = CPUReader()
    private let memoryReader = MemoryReader()
    private let gpuReader = GPUReader()
    private let diskReader = DiskReader()
    private let networkReader = NetworkReader()
    private let batteryReader = BatteryReader()
    private var timer: Timer?

    init() {
        cpuName = cpuReader.name
        performanceCores = cpuReader.performanceCores
        efficiencyCores = cpuReader.efficiencyCores
        hasBattery = batteryReader.read() != nil
        hasGPU = gpuReader.read() != nil
    }

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start() {
        queue.async { [self] in
            _ = cpuReader.read()
            _ = diskReader.read()
            _ = networkReader.read()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            sample()
            schedule()
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = interval * 0.1
    }

    private func sample() {
        let includeProcesses = wantsProcesses > 0
        queue.async { [self] in
            let result = collect(includeProcesses: includeProcesses)
            DispatchQueue.main.async { [self] in apply(result) }
        }
    }

    /// Takes one sample on the calling thread; used by the command-line modes.
    func sampleNow(includeProcesses: Bool = true) {
        queue.sync { apply(collect(includeProcesses: includeProcesses)) }
    }

    private struct Sample {
        var cpu: CPUStats?
        var memory: MemoryStats?
        var gpu: GPUStats?
        var disk: DiskStats?
        var network: NetworkStats
        var battery: BatteryStats?
        var processes: (cpu: [ProcessRow], memory: [ProcessRow])?
    }

    private func collect(includeProcesses: Bool) -> Sample {
        Sample(cpu: cpuReader.read(), memory: memoryReader.read(), gpu: hasGPU ? gpuReader.read() : nil,
               disk: diskReader.read(), network: networkReader.read(),
               battery: hasBattery ? batteryReader.read() : nil,
               processes: includeProcesses ? ProcessReader.top() : nil)
    }

    private func apply(_ sample: Sample) {
        if let value = sample.cpu { cpu = value }
        if let value = sample.memory { memory = value }
        gpu = sample.gpu ?? gpu
        if let value = sample.disk { disk = value }
        network = sample.network
        battery = sample.battery
        if let processes = sample.processes {
            topCPU = processes.cpu
            topMemory = processes.memory
        }

        var next = history
        func push(_ series: Series, _ value: Double?) {
            guard let value else { return }
            var values = next[series] ?? []
            values.append(value)
            if values.count > Self.historyLength { values.removeFirst(values.count - Self.historyLength) }
            next[series] = values
        }
        push(.cpu, sample.cpu?.total)
        push(.gpu, sample.gpu?.utilization)
        push(.memory, sample.memory?.fraction)
        push(.diskRead, sample.disk?.readPerSecond)
        push(.diskWrite, sample.disk?.writePerSecond)
        push(.netDown, sample.network.down)
        push(.netUp, sample.network.up)
        push(.battery, sample.battery?.level)
        history = next

        onUpdate?()
    }

    func available(_ module: Module) -> Bool {
        switch module {
        case .gpu: return hasGPU
        case .battery: return hasBattery
        default: return true
        }
    }
}

// MARK: - Preferences

enum BarStyle: String, CaseIterable, Identifiable {
    case labeled, compact
    var id: String { rawValue }
    var title: String { self == .labeled ? "Label above value" : "Icon and value" }
}

final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var enabled: Set<Module> {
        didSet { defaults.set(enabled.map(\.rawValue), forKey: "enabledModules") }
    }
    @Published var interval: Double {
        didSet { defaults.set(interval, forKey: "interval") }
    }
    @Published var style: BarStyle {
        didSet { defaults.set(style.rawValue, forKey: "barStyle") }
    }
    @Published var hidesAddress: Bool {
        didSet { defaults.set(hidesAddress, forKey: "hideAddress") }
    }

    init() {
        let saved = defaults.stringArray(forKey: "enabledModules")?.compactMap(Module.init(rawValue:))
        enabled = Set(saved ?? [.cpu, .memory, .network])
        let savedInterval = defaults.double(forKey: "interval")
        interval = savedInterval > 0 ? savedInterval : 2
        style = BarStyle(rawValue: defaults.string(forKey: "barStyle") ?? "") ?? .labeled
        hidesAddress = defaults.bool(forKey: "hideAddress")
    }
}

// MARK: - Formatting

enum Format {
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(fraction, 0) * 100).rounded()))%"
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(value, 0)), countStyle: .memory)
    }

    static func size(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(value, 0)), countStyle: .file)
    }

    /// Short throughput like "840 KB/s" or "1.2 MB/s"; `compact` drops the "B/s".
    static func speed(_ bytesPerSecond: Double, compact: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(bytesPerSecond, 0)
        var unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let number = unit > 0 && value < 9.95 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        if compact { return number + (unit == 0 ? "B" : String(units[unit].prefix(1))) }
        return "\(number) \(units[unit])/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    /// "192.168.1.20" becomes "192.168.•.•", for screen sharing.
    static func masked(_ address: String) -> String {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return "•••" }
        return parts.prefix(2).joined(separator: ".") + ".•.•"
    }

    static func minutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
