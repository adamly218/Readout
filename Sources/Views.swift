import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

extension Module {
    var color: Color {
        switch self {
        case .cpu: return .blue
        case .gpu: return .purple
        case .memory: return .green
        case .disk: return .orange
        case .network: return .teal
        case .battery: return .mint
        }
    }
}

// MARK: - Building blocks

struct Sparkline: View {
    var values: [Double]
    var maxValue: Double?
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let top = max(maxValue ?? (values.max() ?? 0), 1e-9)
            let step = size.width / CGFloat(Monitor.historyLength - 1)
            let start = CGFloat(Monitor.historyLength - values.count) * step
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + CGFloat(index) * step,
                        y: size.height * (1 - CGFloat(min(max(value / top, 0), 1))))
            }
            ZStack {
                if let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.03)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct Chart: View {
    var series: [(values: [Double], color: Color)]
    var maxValue: Double?

    var body: some View {
        let top = maxValue ?? max(series.flatMap(\.values).max() ?? 0, 1)
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05))
            ForEach(series.indices, id: \.self) { index in
                Sparkline(values: series[index].values, maxValue: top, color: series[index].color)
            }
            .padding(.vertical, 6)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(height: 64)
    }
}

struct UsageBar: View {
    var segments: [(fraction: Double, color: Color)]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle().fill(segments[index].color)
                        .frame(width: geometry.size.width * CGFloat(min(max(segments[index].fraction, 0), 1)))
                }
                Spacer(minLength: 0)
            }
            .background(.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

struct DetailRow: View {
    var label: String
    var value: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

struct ProcessList: View {
    var title: String
    var rows: [ProcessRow]
    var value: (ProcessRow) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionTitle(text: title)
            if rows.isEmpty {
                Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                let app = NSRunningApplication(processIdentifier: row.pid)
                HStack(spacing: 6) {
                    Image(nsImage: app?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable))
                        .resizable().frame(width: 15, height: 15)
                    Text(app?.localizedName ?? row.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(value(row)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Popover

struct PopoverView: View {
    let module: Module
    @ObservedObject var monitor: Monitor
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            Divider().padding(.top, 2)
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(module.title, systemImage: module.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(module.color)
            Spacer()
            Text(headline)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private var headline: String {
        switch module {
        case .cpu: return monitor.cpu.map { Format.percent($0.total) } ?? "–"
        case .gpu: return monitor.gpu.map { Format.percent($0.utilization) } ?? "–"
        case .memory: return monitor.memory.map { Format.percent($0.fraction) } ?? "–"
        case .disk: return monitor.disk.map { Format.percent($0.fraction) } ?? "–"
        case .network: return monitor.network.map { Format.speed($0.down) } ?? "–"
        case .battery: return monitor.battery.map { Format.percent($0.level) } ?? "–"
        }
    }

    private func history(_ series: Series) -> [Double] { monitor.history[series] ?? [] }

    @ViewBuilder private var content: some View {
        switch module {
        case .cpu: cpuContent
        case .gpu: gpuContent
        case .memory: memoryContent
        case .disk: diskContent
        case .network: networkContent
        case .battery: batteryContent
        }
    }

    @ViewBuilder private var cpuContent: some View {
        Chart(series: [(history(.cpu), module.color)], maxValue: 1)
        if let cpu = monitor.cpu {
            DetailRow(label: "System", value: Format.percent(cpu.system), dot: .red)
            DetailRow(label: "User", value: Format.percent(cpu.user), dot: .blue)
            DetailRow(label: "Idle", value: Format.percent(1 - cpu.total), dot: .gray)
            DetailRow(label: "Load average", value: cpu.load.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            SectionTitle(text: coresTitle)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(cpu.cores.indices, id: \.self) { index in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 2).fill(module.color)
                            .frame(height: max(2, 34 * CGFloat(cpu.cores[index])))
                    }
                    .frame(height: 34)
                }
            }
        }
        ProcessList(title: "Top processes", rows: monitor.topCPU) { String(format: "%.1f%%", $0.cpu) }
    }

    private var coresTitle: String {
        let name = monitor.cpuName
        guard monitor.performanceCores > 0 else { return "\(name) · Cores" }
        return "\(name) · \(monitor.performanceCores)P + \(monitor.efficiencyCores)E cores"
    }

    @ViewBuilder private var gpuContent: some View {
        Chart(series: [(history(.gpu), module.color)], maxValue: 1)
        if let gpu = monitor.gpu {
            DetailRow(label: "Model", value: gpu.name)
            if let cores = gpu.cores { DetailRow(label: "Cores", value: "\(cores)") }
            DetailRow(label: "Utilization", value: Format.percent(gpu.utilization))
        }
    }

    @ViewBuilder private var memoryContent: some View {
        Chart(series: [(history(.memory), module.color)], maxValue: 1)
        if let memory = monitor.memory {
            UsageBar(segments: [(memory.app / memory.total, .green),
                                (memory.wired / memory.total, .orange),
                                (memory.compressed / memory.total, .pink)])
            DetailRow(label: "Used", value: "\(Format.bytes(memory.used)) of \(Format.bytes(memory.total))")
            DetailRow(label: "App memory", value: Format.bytes(memory.app), dot: .green)
            DetailRow(label: "Wired", value: Format.bytes(memory.wired), dot: .orange)
            DetailRow(label: "Compressed", value: Format.bytes(memory.compressed), dot: .pink)
            DetailRow(label: "Cached files", value: Format.bytes(memory.cached), dot: .gray)
            DetailRow(label: "Swap", value: memory.swapTotal > 0
                      ? "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))" : "Not used")
            DetailRow(label: "Pressure", value: memory.pressureLabel)
        }
        ProcessList(title: "Top processes", rows: monitor.topMemory) { Format.bytes($0.memory) }
    }

    @ViewBuilder private var diskContent: some View {
        Chart(series: [(history(.diskRead), .orange), (history(.diskWrite), .red)], maxValue: nil)
        if let disk = monitor.disk {
            DetailRow(label: "Read", value: Format.speed(disk.readPerSecond), dot: .orange)
            DetailRow(label: "Write", value: Format.speed(disk.writePerSecond), dot: .red)
            SectionTitle(text: disk.name)
            UsageBar(segments: [(disk.fraction, module.color)])
            DetailRow(label: "Used", value: Format.size(disk.used))
            DetailRow(label: "Available", value: Format.size(disk.free))
            DetailRow(label: "Capacity", value: Format.size(disk.total))
        }
    }

    @ViewBuilder private var networkContent: some View {
        Chart(series: [(history(.netDown), .teal), (history(.netUp), .pink)], maxValue: nil)
        if let network = monitor.network {
            DetailRow(label: "Download", value: Format.speed(network.down), dot: .teal)
            DetailRow(label: "Upload", value: Format.speed(network.up), dot: .pink)
            SectionTitle(text: "Connection")
            DetailRow(label: "Interface", value: network.interface.map { "\(network.kind) (\($0))" } ?? network.kind)
            DetailRow(label: "Local IP", value: network.address.map { monitor.hidesAddress ? Format.masked($0) : $0 } ?? "–")
            DetailRow(label: "Received since launch", value: Format.size(network.totalDown))
            DetailRow(label: "Sent since launch", value: Format.size(network.totalUp))
        }
    }

    @ViewBuilder private var batteryContent: some View {
        Chart(series: [(history(.battery), module.color)], maxValue: 1)
        if let battery = monitor.battery {
            UsageBar(segments: [(battery.level, battery.level < 0.2 ? .red : module.color)])
            DetailRow(label: "State", value: battery.stateLabel)
            if let minutes = battery.minutesRemaining {
                DetailRow(label: battery.isCharging ? "Until full" : "Time left", value: Format.minutes(minutes))
            }
            if let health = battery.health { DetailRow(label: "Health", value: Format.percent(health)) }
            if let cycles = battery.cycles { DetailRow(label: "Cycle count", value: "\(cycles)") }
            if let watts = battery.adapterWatts { DetailRow(label: "Power adapter", value: "\(watts) W") }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Uptime \(Format.duration(monitor.uptime))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: { Image(systemName: "waveform.path.ecg") }
                .help("Open Activity Monitor")
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Readout")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let monitor: Monitor
    @StateObject private var login = LoginItem()

    var body: some View {
        Form {
            Section("Menu bar") {
                ForEach(Module.allCases.filter(monitor.available)) { module in
                    Toggle(isOn: binding(for: module)) {
                        HStack(spacing: 8) {
                            Image(systemName: module.symbol).frame(width: 22)
                            Text(module.title)
                        }
                    }
                    .disabled(preferences.enabled == [module])
                }
                Picker("Style", selection: $preferences.style) {
                    ForEach(BarStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Hide local IP address", isOn: $preferences.hidesAddress)
            }
            Section("General") {
                Picker("Update every", selection: $preferences.interval) {
                    ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Toggle("Open at login", isOn: Binding(get: { login.enabled }, set: login.set))
                if let loginError = login.error {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                HStack {
                    Text("Readout \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    Spacer()
                    Button("Quit Readout") { NSApp.terminate(nil) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding(for module: Module) -> Binding<Bool> {
        Binding {
            preferences.enabled.contains(module)
        } set: { on in
            if on { preferences.enabled.insert(module) } else { preferences.enabled.remove(module) }
        }
    }
}

final class LoginItem: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        self.enabled = SMAppService.mainApp.status == .enabled
    }
}
