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
    
    // 电源
    var batteryPresent: Bool = false
    var batteryPercent: Int = 0
    var isCharging: Bool = false
    var onAC: Bool = false
    var powerW: Double = 0
    var powerWInitialized: Bool = false
    var batteryChargePower: Double = 0  // 电池充电功率（W），插电时有效
    var timeToEmptyMin: Int = -1
    var timeToFullMin: Int = -1
}

// MARK: - 监控器

class Monitor {
    let metrics = Metrics()

    func update() {
        updateCPU()
        updateMemory()
        updateNetwork()
        updatePower()
    }

    private func updatePower() {
        // 检测是否有电池（台式机/无电池设备 list 为空）
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            metrics.batteryPresent = false
            metrics.powerW = 0
            return
        }
        metrics.batteryPresent = true

        // 读取 IOPS 提供的状态与时间（系统已计算）
        var systemTimeToEmpty: Int?
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else { continue }
            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            metrics.onAC = (state != kIOPSBatteryPowerValue as String)
            metrics.isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            metrics.batteryPercent = (desc[kIOPSCurrentCapacityKey as String] as? Int) ?? 0
            systemTimeToEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int
            if let t = systemTimeToEmpty { metrics.timeToEmptyMin = t }
            if let t = desc[kIOPSTimeToFullChargeKey as String] as? Int { metrics.timeToFullMin = t }
            break
        }

        // 读 AppleSmartBattery 瞬时功率：mA × mV = μW → /1e6 = W
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var amp = 0, volt = 0, curMAh = 0
        if let a = IORegistryEntryCreateCFProperty(service, "InstantAmperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int { amp = a }
        if let v = IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int { volt = v }
        if let c = IORegistryEntryCreateCFProperty(service, "AppleRawCurrentCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int { curMAh = c }

        guard volt > 0 else { return }
        // 计算当前功耗：
        // - 插电时：整机功耗 = SystemPowerIn - 电池充电功率（SystemPowerIn 为电源适配器实际输出）
        // - 放电时：电池放电功率 = |InstantAmperage| × Voltage
        let raw: Double
        if let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
           let systemPowerIn = telemetry["SystemPowerIn"] as? Int,
           let batteryPower = telemetry["BatteryPower"] as? Int,
           systemPowerIn > 0 {
            // 插电：整机功耗 = 系统输入功率 - 电池充电功率（单位 mW → W）
            raw = Double(systemPowerIn - abs(batteryPower)) / 1000.0
            // 存储充电功率（单位 mW → W），用于插电时显示
            metrics.batteryChargePower = Double(abs(batteryPower)) / 1000.0
        } else {
            // 放电：电池放电功率 = |电流| × 电压（mA × mV = μW → /1e6 = W）
            raw = Double(abs(amp)) * Double(volt) / 1_000_000.0
            metrics.batteryChargePower = 0
        }
        // EMA 平滑，权重 0.5 让功耗更灵敏地跟随实际变化
        if !metrics.powerWInitialized {
            metrics.powerW = raw
            metrics.powerWInitialized = true
        } else {
            metrics.powerW = metrics.powerW * 0.5 + raw * 0.5
        }

        // 实际充电状态修正：当系统报告不在充电但电流为正（流入电池）时，
        // 说明有第三方工具（如 AlDente）接管了充电控制，按实际电流方向判定
        if !metrics.isCharging && amp > 100 {
            metrics.isCharging = true
        }

        // 若系统未提供待机时间估算（macOS 常返回 no estimate），则自行估算
        // 公式：剩余能量(Wh) = 当前容量(mAh) × 电压(V) / 1000
        //      剩余时间(h) = 剩余能量(Wh) / 放电功率(W)
        let hasSystemEstimate = (systemTimeToEmpty ?? -1) > 0
        if !metrics.onAC && !hasSystemEstimate && curMAh > 0 && metrics.powerW > 0.1 {
            let energyWh = Double(curMAh) * Double(volt) / 1_000_000.0
            let estHours = energyWh / metrics.powerW
            metrics.timeToEmptyMin = Int(estHours * 60)
        }
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
        var cur: UnsafeMutablePointer<ifaddrs>? = first

        while let ptr = cur {
            let iface = ptr.pointee
            let name = String(cString: iface.ifa_name)

            // 仅监控物理网卡：macOS 上 WiFi 与有线网卡均为 en* 命名
            // 过滤 lo0/awdl0/llw0/utun/gif/stf/bridge 等虚拟/隧道接口
            if name.hasPrefix("en"),
               let addr = iface.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let data = iface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let bytesIn = UInt64(data.pointee.ifi_ibytes)
                let bytesOut = UInt64(data.pointee.ifi_obytes)
                totalIn += bytesIn
                totalOut += bytesOut
            }

            cur = iface.ifa_next
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
        if bps < 1024 { return String(format: "%.0fB", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1fK", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1fM", bps / (1024 * 1024)) }
        return String(format: "%.2fG", bps / (1024 * 1024 * 1024))
    }

    /// 计算字符串在等宽字体下的显示宽度（ASCII 字符宽度为 1，中文字符宽度为 2）
    func displayWidth(_ s: String) -> Int {
        var w = 0
        for c in s.unicodeScalars {
            if c.value <= 0x7F {
                w += 1
            } else {
                w += 2
            }
        }
        return w
    }

    /// 将分钟数格式化为小时数，智能调整精度以控制宽度：
    /// - <100h → 一位小数（如 8.5）
    /// - ≥100h 且 ≤999h → 整数（如 120）
    /// - >999h → 固定显示 999（上限保护）
    /// 输出宽度：最多 3 字符（个位数小数 3 字符，三位数整数 3 字符）
    func formatDurationHours(_ minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        let hours = Double(minutes) / 60.0
        if hours >= 999 {
            return "999"
        } else if hours >= 100 {
            return String(format: "%.0f", hours)
        } else {
            return String(format: "%.1f", hours)
        }
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

        var lines = [line1, line2]
        // 第三行：电源信息（无电池设备不显示）
        // 插电 → 显示充电功率；放电 → 显示待机时间
        if m.batteryPresent {
            // 左侧：功率+W，8字符右对齐（与网速列对齐）
            let pStr = String(format: "%.1fW", m.powerW)
            let powerPad = String(repeating: " ", count: max(0, col1Width - pStr.count))
            let powerAligned = "\(powerPad)\(pStr)"

            // 右侧：插电显示充电功率，放电显示待机时间
            let rightStr: String
            let label: String
            if m.isCharging || m.onAC {
                // 插电时显示充电功率（P: 代表功率）
                label = "P:"
                let chargeW = m.batteryChargePower
                if chargeW >= 100 {
                    rightStr = String(format: "%.0f", chargeW)
                } else if chargeW >= 1 {
                    rightStr = String(format: "%.1f", chargeW)
                } else if chargeW > 0 {
                    rightStr = String(format: "%.1f", chargeW)
                } else {
                    rightStr = "0.0"
                }
            } else {
                // 放电时显示待机时间（H: 代表小时）
                label = "H:"
                rightStr = m.timeToEmptyMin > 0 ? formatDurationHours(m.timeToEmptyMin) : ""
            }
            let rightPad = String(repeating: " ", count: max(0, 4 - displayWidth(rightStr)))
            let rightAligned = "\(rightPad)\(rightStr)"

            lines.append("\(powerAligned) \(label)\(rightAligned)")
        }

        let menuText = lines.joined(separator: "\n")

        let attributedText = NSMutableAttributedString(string: menuText)
        let fullRange = NSRange(location: 0, length: (menuText as NSString).length)

        // 使用8pt等宽字体
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        attributedText.addAttribute(.font, value: font, range: fullRange)

        // 设置行间距（三行时收紧以塞进菜单栏）
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lines.count > 2 ? 0 : 1
        attributedText.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        // 将文本渲染为图像
        let textSize = attributedText.size()
        let imageHeight: CGFloat = lines.count > 2 ? 28 : 22
        let imageSize = NSSize(width: textSize.width, height: imageHeight)
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

    /// 用户是否希望监控运行（独立于 timer 的实际状态，避免 sleep 与 session 事件互相覆盖）
    private var wantsTimer: Bool = true

    /// 启动定时器（若尚未运行）
    private func startTimerIfNeeded() {
        guard timer == nil || !(timer?.isValid ?? false) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.update() }
        timer?.tolerance = 0.05
        update()
    }

    /// 停止定时器
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc func systemWillSleep() {
        // 休眠时停止 timer，但不改变 wantsTimer，以便唤醒后恢复
        stopTimer()
    }

    @objc func systemDidWake() {
        if wantsTimer { startTimerIfNeeded() }
    }

    @objc func sessionDidResignActive() {
        wantsTimer = false
        stopTimer()
    }

    @objc func sessionDidBecomeActive() {
        wantsTimer = true
        startTimerIfNeeded()
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication.delegate 是 weak 引用，需保证 delegate 在 run() 期间存活
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
