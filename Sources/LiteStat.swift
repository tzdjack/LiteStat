// LiteStat Lite - 精简版：仅菜单栏显示
// 构建：swiftc -O -o LiteStat Sources/LiteStat.swift -framework Cocoa -framework IOKit -parse-as-library

import Cocoa
import IOKit
import IOKit.ps

// MARK: - 本地化

struct L10n {
    static let about = "关于 LiteStat"
    static let quit = "退出"
}

// MARK: - 指标

class Metrics {
    var cpu: Double = 0
    var mem: Double = 0, memUsed: UInt64 = 0, memTotal: UInt64 = 0
    var netIn: Double = 0, netOut: Double = 0
    var netTotalIn: UInt64 = 0, netTotalOut: UInt64 = 0
    
    var prevTime: Date?
    var prevCPUTicks: [UInt64]?
}

// MARK: - 监控器

class Monitor {
    let metrics = Metrics()

    func update() {
        updateCPU()
        updateMemory()
        updateNetwork()
    }

    private func updateCPU() {
        var info: processor_info_array_t?
        var msgCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &msgCount)
        guard result == KERN_SUCCESS, let cpuInfo = info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(msgCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        var ticks: [UInt64] = [], totalUsage: Double = 0
        for i in 0..<Int(cpuCount) {
            let off = Int(CPU_STATE_MAX) * i
            let u = UInt64(cpuInfo[off + Int(CPU_STATE_USER)]), s = UInt64(cpuInfo[off + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(cpuInfo[off + Int(CPU_STATE_IDLE)]), n = UInt64(cpuInfo[off + Int(CPU_STATE_NICE)])
            ticks.append(contentsOf: [u, s, idle, n])
            if let prev = metrics.prevCPUTicks, prev.count > off + 3 {
                let du = u - prev[off], ds = s - prev[off + 1], di = idle - prev[off + 2], dn = n - prev[off + 3]
                let total = du + ds + di + dn
                if total > 0 { totalUsage += Double(du + ds + dn) / Double(total) * 100 }
            }
        }
        if metrics.prevCPUTicks != nil { metrics.cpu = totalUsage / Double(cpuCount) }
        metrics.prevCPUTicks = ticks
    }

    private func updateMemory() {
        metrics.memTotal = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let memUsed = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * page
        metrics.memUsed = memUsed
        metrics.mem = Double(memUsed) / Double(metrics.memTotal) * 100
    }

    private func updateNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        let now = Date()
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var cur = first

        while true {
            let iface = cur.pointee
            let name = String(cString: iface.ifa_name)

            if name == "lo0" {
                guard let next = iface.ifa_next else { break }
                cur = next
                continue
            }

            if iface.ifa_addr.pointee.sa_family == UInt8(AF_LINK),
               let data = iface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let bytesIn = UInt64(data.pointee.ifi_ibytes)
                let bytesOut = UInt64(data.pointee.ifi_obytes)

                if bytesIn > 0 || bytesOut > 0 {
                    totalIn += bytesIn
                    totalOut += bytesOut
                }
            }

            guard let next = iface.ifa_next else { break }
            cur = next
        }

        if let pt = metrics.prevTime {
            let dt = now.timeIntervalSince(pt)
            if dt > 0 && metrics.netTotalIn > 0 {
                metrics.netIn = Double(totalIn > metrics.netTotalIn ? totalIn - metrics.netTotalIn : 0) / dt
                metrics.netOut = Double(totalOut > metrics.netTotalOut ? totalOut - metrics.netTotalOut : 0) / dt
            }
        }

        metrics.netTotalIn = totalIn
        metrics.netTotalOut = totalOut
        metrics.prevTime = now
    }
}

// MARK: - 应用代理

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var monitor = Monitor()
    var timer: Timer?
    var menu: NSMenu!

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        if let btn = statusItem.button {
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.action = #selector(handleClick)
            btn.target = self
        }

        setupMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.update() }
        timer?.tolerance = 0.05
        update()
        
        // 监听系统休眠/锁屏通知
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspaceNotificationCenter.addObserver(self, selector: #selector(sessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceNotificationCenter.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    func setupMenu() {
        menu = NSMenu()

        // 关于
        let aboutItem = NSMenuItem(title: L10n.about, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func formatSpeedCompact(_ bps: Double) -> String {
        if bps < 1024 { return String(format: "%.0fB/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1fK", bps / 1024) }
        return String(format: "%.1fM", bps / (1024 * 1024))
    }

    func updateMenuBarDisplay() {
        let m = monitor.metrics
        
        // 格式化显示数据
        let downStr = formatSpeedCompact(m.netIn)
        let upStr = formatSpeedCompact(m.netOut)
        let cpuStr = String(format: "%3d", Int(m.cpu))
        let memStr = String(format: "%3d", Int(m.mem))
        
        // 固定列宽对齐
        let col1Width = 8
        let downPad = String(repeating: " ", count: max(0, col1Width - downStr.count - 1))
        let upPad = String(repeating: " ", count: max(0, col1Width - upStr.count - 1))
        
        let line1 = "\(downPad)\(downStr)↓ C:\(cpuStr)%"
        let line2 = "\(upPad)\(upStr)↑ M:\(memStr)%"
        let menuText = "\(line1)\n\(line2)"
        
        let attributedText = NSMutableAttributedString(string: menuText)
        let fullRange = NSRange(location: 0, length: (menuText as NSString).length)
        
        // 使用8pt等宽字体
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        attributedText.addAttribute(.font, value: font, range: fullRange)
        
        // 设置行间距
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 1
        attributedText.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        
        // 将文本渲染为图像
        let textSize = attributedText.size()
        let imageSize = NSSize(width: textSize.width, height: 22)
        let image = NSImage(size: imageSize, flipped: false) { rect in
            let yOffset = (rect.height - textSize.height) / 2 + 1
            attributedText.draw(at: NSPoint(x: 0, y: yOffset))
            return true
        }
        image.isTemplate = true
        
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageOnly
    }

    func update() {
        monitor.update()
        updateMenuBarDisplay()
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // 左键点击可以显示详细信息弹窗或刷新
            update()
        }
    }

    @objc func showAbout() {
        autoreleasepool {
            let alert = NSAlert()
            alert.messageText = "LiteStat Lite"
            alert.informativeText = "A lightweight macOS menu bar system monitor.\n\n© 2026 tzdjack \n\nhttps://github.com/tzdjack/LiteStat"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Repository")
            
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                if let url = URL(string: "https://github.com/tzdjack/LiteStat") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - 系统休眠/锁屏处理
    
    private var wasUpdatingBeforeSleep = false
    
    @objc func systemWillSleep() {
        wasUpdatingBeforeSleep = timer?.isValid ?? false
        timer?.invalidate()
        timer = nil
    }
    
    @objc func systemDidWake() {
        if wasUpdatingBeforeSleep {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.update() }
            timer?.tolerance = 0.05
            update()
        }
    }
    
    @objc func sessionDidResignActive() {
        timer?.invalidate()
        timer = nil
    }
    
    @objc func sessionDidBecomeActive() {
        if timer == nil || !(timer?.isValid ?? false) {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.update() }
            timer?.tolerance = 0.05
            update()
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
