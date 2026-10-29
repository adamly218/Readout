import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let preferences = Preferences()
    private var items: [StatusItemController] = []
    private var settingsWindow: NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor.interval = preferences.interval
        monitor.onUpdate = { [weak self] in self?.refresh() }

        preferences.$enabled.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildItems() }.store(in: &subscriptions)
        preferences.$style.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        preferences.$interval.receive(on: RunLoop.main)
            .sink { [weak self] in self?.monitor.interval = $0 }.store(in: &subscriptions)
        preferences.$hidesAddress
            .sink { [weak self] in self?.monitor.hidesAddress = $0 }.store(in: &subscriptions)

        monitor.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Recreates the items right to left so they always appear in module order.
    private func rebuildItems() {
        items.forEach { $0.remove() }
        let modules = Module.allCases.filter { preferences.enabled.contains($0) && monitor.available($0) }
        let shown = modules.isEmpty ? [.cpu] : modules
        items = shown.reversed().map { module in
            StatusItemController(module: module, monitor: monitor) { [weak self] in self?.showSettings() }
        }
        refresh()
    }

    private func refresh() {
        items.forEach { $0.update(style: preferences.style) }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(preferences: preferences, monitor: monitor)))
            window.title = "Readout Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Command-line modes

/// `--dump` prints one reading of every module, for checking values against system tools.
func dump(_ monitor: Monitor) {
    monitor.sampleNow()
    Thread.sleep(forTimeInterval: 1)
    monitor.sampleNow()

    if let cpu = monitor.cpu {
        print("CPU      \(monitor.cpuName) \(Format.percent(cpu.total)) (user \(Format.percent(cpu.user)), system \(Format.percent(cpu.system))), \(cpu.cores.count) cores, load \(cpu.load.map { String(format: "%.2f", $0) }.joined(separator: " "))")
    }
    if let gpu = monitor.gpu {
        print("GPU      \(gpu.name) \(gpu.cores.map { "\($0) cores " } ?? "")\(Format.percent(gpu.utilization))")
    }
    if let memory = monitor.memory {
        print("Memory   used \(Format.bytes(memory.used)) of \(Format.bytes(memory.total)) (app \(Format.bytes(memory.app)), wired \(Format.bytes(memory.wired)), compressed \(Format.bytes(memory.compressed)), cached \(Format.bytes(memory.cached))), swap \(Format.bytes(memory.swapUsed)), pressure \(memory.pressureLabel)")
    }
    if let disk = monitor.disk {
        print("Disk     \(disk.name) \(Format.size(disk.free)) free of \(Format.size(disk.total)), read \(Format.speed(disk.readPerSecond)), write \(Format.speed(disk.writePerSecond))")
    }
    if let network = monitor.network {
        print("Network  \(network.kind) \(network.interface ?? "-") \(network.address ?? "-"), down \(Format.speed(network.down)), up \(Format.speed(network.up))")
    }
    if let battery = monitor.battery {
        print("Battery  \(Format.percent(battery.level)) \(battery.stateLabel), \(battery.minutesRemaining.map(Format.minutes) ?? "-") left, health \(battery.health.map(Format.percent) ?? "-"), \(battery.cycles.map(String.init) ?? "-") cycles, adapter \(battery.adapterWatts.map { "\($0) W" } ?? "-")")
    }
    print("Top CPU  " + monitor.topCPU.map { "\($0.name) \(String(format: "%.1f", $0.cpu))%" }.joined(separator: ", "))
    print("Top RAM  " + monitor.topMemory.map { "\($0.name) \(Format.bytes($0.memory))" }.joined(separator: ", "))
}

/// `--snapshot <folder> [--exclude name,name]` renders the popovers and a menu bar strip to PNG files
/// for the README, with the local IP masked.
func snapshot(_ monitor: Monitor, to folder: URL) {
    monitor.hidesAddress = true
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for _ in 0..<Monitor.historyLength {
        monitor.sampleNow(includeProcesses: false)
        Thread.sleep(forTimeInterval: 0.25)
    }
    monitor.sampleNow()

    func save(_ view: NSView, _ name: String) {
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
    }

    for module in Module.allCases where monitor.available(module) {
        let root = PopoverView(module: module, monitor: monitor) {}
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        let hosting = NSHostingView(rootView: root)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        save(hosting, "\(module.rawValue).png")
    }

    let modules = Module.allCases.filter(monitor.available)
    let images = modules.map { StatusImage.image(for: $0, monitor: monitor, style: .labeled) }
    let gap: CGFloat = 14
    let size = NSSize(width: images.reduce(gap) { $0 + $1.size.width + gap }, height: NSStatusBar.system.thickness)
    let bar = NSImage(size: size, flipped: false) { rect in
        NSColor(white: 0.12, alpha: 1).setFill()
        rect.fill()
        var x = gap
        for image in images {
            let tinted = NSImage(size: image.size, flipped: false) { inner in
                image.draw(in: inner)
                NSColor.white.set()
                inner.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x, y: 0, width: image.size.width, height: image.size.height))
            x += image.size.width + gap
        }
        return true
    }
    if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bar.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("menubar.png"))
    }
}

let arguments = CommandLine.arguments
let app = NSApplication.shared

if arguments.contains("--dump") {
    dump(Monitor())
} else if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
    if let exclude = arguments.firstIndex(of: "--exclude"), exclude + 1 < arguments.count {
        ProcessReader.excluded = Set(arguments[exclude + 1].split(separator: ",").map(String.init))
    }
    app.setActivationPolicy(.prohibited)
    snapshot(Monitor(), to: URL(fileURLWithPath: arguments[index + 1]))
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
