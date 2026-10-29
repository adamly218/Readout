import AppKit
import SwiftUI

/// Draws the menu bar readouts as template images, so macOS tints them for light and dark menu bars.
enum StatusImage {
    private static let height = NSStatusBar.system.thickness
    private static let captionFont = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    private static let lineFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let compactFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    static func image(for module: Module, monitor: Monitor, style: BarStyle) -> NSImage {
        if module == .network {
            let network = monitor.network
            if style == .compact {
                let text = "↓\(Format.speed(network?.down ?? 0, compact: true)) ↑\(Format.speed(network?.up ?? 0, compact: true))"
                return compact(symbol: nil, text: text, widthTemplate: "↓999K ↑999K")
            }
            return twoLines(["↑ " + Format.speed(network?.up ?? 0), "↓ " + Format.speed(network?.down ?? 0)],
                            widthTemplate: "↓ 999 KB/s")
        }

        let value = text(for: module, monitor: monitor)
        if style == .compact {
            return compact(symbol: symbol(for: module, monitor: monitor), text: value, widthTemplate: "100%")
        }
        var caption = module.caption
        if module == .battery, monitor.battery?.isCharging == true { caption += " ⚡︎" }
        return labeled(caption: caption, value: value)
    }

    private static func text(for module: Module, monitor: Monitor) -> String {
        let fraction: Double?
        switch module {
        case .cpu: fraction = monitor.cpu?.total
        case .gpu: fraction = monitor.gpu?.utilization
        case .memory: fraction = monitor.memory?.fraction
        case .disk: fraction = monitor.disk?.fraction
        case .battery: fraction = monitor.battery?.level
        case .network: fraction = nil
        }
        return fraction.map(Format.percent) ?? "–"
    }

    private static func symbol(for module: Module, monitor: Monitor) -> String {
        guard module == .battery, let battery = monitor.battery else { return module.symbol }
        if battery.isCharging { return "battery.100percent.bolt" }
        let steps = [(0.9, "100"), (0.6, "75"), (0.35, "50"), (0.1, "25")]
        return "battery.\(steps.first { battery.level >= $0.0 }?.1 ?? "0")percent"
    }

    private static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func render(width: CGFloat, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func labeled(caption: String, value: String) -> NSImage {
        let valueWidth = max(width(value, valueFont), width("100%", valueFont))
        let total = max(valueWidth, width(caption, captionFont)) + 2
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        return render(width: total) { rect in
            let top = (rect.height - 21) / 2
            (caption as NSString).draw(in: NSRect(x: 0, y: top, width: rect.width, height: 9),
                                       withAttributes: [.font: captionFont, .paragraphStyle: centered])
            (value as NSString).draw(in: NSRect(x: 0, y: top + 7.5, width: rect.width, height: 14),
                                     withAttributes: [.font: valueFont, .paragraphStyle: centered])
        }
    }

    private static func twoLines(_ lines: [String], widthTemplate: String) -> NSImage {
        let total = max(width(widthTemplate, lineFont), lines.map { width($0, lineFont) }.max() ?? 0) + 2
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        return render(width: total) { rect in
            let top = (rect.height - 22) / 2
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(in: NSRect(x: 0, y: top + CGFloat(index) * 10.5, width: rect.width, height: 12),
                                        withAttributes: [.font: lineFont, .paragraphStyle: right])
            }
        }
    }

    private static func compact(symbol: String?, text: String, widthTemplate: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) }
        let iconWidth = icon.map { $0.size.width + 4 } ?? 0
        let textWidth = max(width(text, compactFont), width(widthTemplate, compactFont))
        return render(width: iconWidth + textWidth + 1) { rect in
            if let icon {
                icon.draw(in: NSRect(x: 0, y: (rect.height - icon.size.height) / 2,
                                     width: icon.size.width, height: icon.size.height))
            }
            let textHeight = compactFont.ascender - compactFont.descender
            (text as NSString).draw(at: NSPoint(x: iconWidth, y: (rect.height - textHeight) / 2),
                                    withAttributes: [.font: compactFont])
        }
    }
}

/// One menu bar item and the popover it opens.
final class StatusItemController: NSObject, NSPopoverDelegate {
    let module: Module
    private let monitor: Monitor
    private let item: NSStatusItem
    private let popover = NSPopover()

    init(module: Module, monitor: Monitor, openSettings: @escaping () -> Void) {
        self.module = module
        self.monitor = monitor
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        item.autosaveName = "Readout.\(module.rawValue)"
        item.button?.setAccessibilityLabel(module.title)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)

        let hosting = NSHostingController(rootView: PopoverView(module: module, monitor: monitor) { [weak self] in
            self?.popover.performClose(nil)
            openSettings()
        })
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self
    }

    func update(style: BarStyle) {
        item.button?.image = StatusImage.image(for: module, monitor: monitor, style: style)
    }

    func remove() {
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
    }

    private var showsProcesses: Bool { module == .cpu || module == .memory }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if showsProcesses { monitor.wantsProcesses += 1 }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        if showsProcesses { monitor.wantsProcesses -= 1 }
    }
}
