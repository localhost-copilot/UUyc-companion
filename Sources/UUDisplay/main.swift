// UU远程伴侣：本机被 UU远程 控制时，按控制端设备自动建虚拟屏并设为主屏，断开后还原
// 调试：UUDisplay --simulate "<设备名>" [秒数=10]  模拟一次连入/断开（不依赖 UU）
//      UUDisplay --simulate "A>B" 8            先按 A 建屏，3 秒后识别为 B 重建
//      UUDisplay --render-settings <目录>       渲染设置窗口各页面为 PNG
//      UUDisplay --render-onboarding <目录>     渲染首次引导三步为 PNG
//      UUDisplay --dump-devices                打印从 UU 读到的设备及预填配置
//      UUDisplay --watchdog                    看门狗模式（由 launchd 托管）
//      UUDisplay --onboarding                  只展示首次引导
import AppKit
import Carbon.HIToolbox
import PermissionFlow
import ServiceManagement
import SwiftUI

if CommandLine.arguments.contains("--watchdog") { Watchdog.run() }

// 只读诊断，不启动协调器或改变屏幕布局。
if CommandLine.arguments.contains("--connection-status") {
    print("辅助功能权限：\(UUReader.isTrusted)")
    print("覆盖窗口：\(UUMonitor.overlayPresent())")
    print("控制端：\(UUReader.readControllers() ?? [])")
    print("已连接：\(UUMonitor.connectionPresent())")
    exit(0)
}

if CommandLine.arguments.contains("--dump-devices") {
    if !UUReader.hasMainWindow { UUReader.showMainWindow(); Thread.sleep(forTimeInterval: 1) }
    guard let devices = UUReader.readDevices() else { print("未读到 UU 主窗口"); exit(1) }
    for d in devices {
        let cfg = DeviceConfig.make(name: d.name, kind: Presets.guessKind(name: d.name, isComputerGroup: d.isComputerGroup))
        let size = cfg.sizeLabel
        print("\(d.isSelf ? "（本机，排除）" : "")\(d.name)\t→ \(cfg.kind.label)\t\(size)")
    }
    print("控制端：\(UUReader.readControllers() ?? [])")
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = Coordinator()
    let settings = SettingsWindowController()
    let onboarding = OnboardingWindowController()
    var statusBar: StatusBarController?
    private var heartbeatTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var demoController: PermissionFlowController?
    private var terminating = false

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.info("启动 UUDisplay，辅助功能权限：\(UUReader.isTrusted)")
        statusBar = StatusBarController(coordinator: coordinator,
                                        openSettings: { [weak self] in self?.settings.show(page: $0) })
        settings.onConfigChanged = { [weak self] in self?.coordinator.configChanged() }
        settings.setDisablePhysical = { [weak self] in self?.coordinator.setDisablePhysical($0) }
        settings.setPaused = { [weak self] in self?.coordinator.setPaused($0) }
        settings.restorePhysical = { [weak self] in self?.coordinator.restorePhysical() }
        coordinator.onChange = { [weak self] in self?.statusBar?.refresh() }

        // 心跳：看门狗据此判断主程序是否卡死（主线程定时器，卡住即停跳）
        Heartbeat.beat(Heartbeat.appURL)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Heartbeat.beat(Heartbeat.appURL) }
        installHotkey()

        let args = CommandLine.arguments
        // 调试：渲染设置窗口各面板后退出：--render-settings <目录>
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            SettingsWindowController.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        // 调试：渲染首次引导三步后退出
        if let i = args.firstIndex(of: "--render-onboarding"), i + 1 < args.count {
            OnboardingWindowController.render(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        // 调试：直接走「授权」按钮背后的 PermissionFlow 调用（打开系统设置 + 拖拽面板）
        if args.contains("--demo-authorize") {
            let url = Bundle.main.bundleURL
            demoController = PermissionFlowController(configuration: .init(
                requiredAppURLs: [url], promptForAccessibilityTrust: false, localeIdentifier: "zh-Hans"))
            demoController?.authorize(pane: .accessibility, suggestedAppURLs: [url],
                                      sourceFrameInScreen: CGRect(x: 800, y: 500, width: 32, height: 32))
            return
        }
        if let i = args.firstIndex(of: "--stress"), i + 1 < args.count, let n = Int(args[i + 1]) {
            stress(rounds: n)
            return
        }
        if let i = args.firstIndex(of: "--simulate"), i + 1 < args.count {
            simulate(name: args[i + 1], seconds: i + 2 < args.count ? Double(args[i + 2]) ?? 10 : 10)
            return
        }

        if args.contains("--onboarding") {
            onboarding.show { _ in NSApp.terminate(nil) }
            return
        }

        registerWatchdog()
        coordinator.start()
        // 首次启动走引导（介绍 → 授权 → 读取设备）；之后缺权限或没有设备时直接打开设置
        if ConfigStore.shared.config.tourShown != true {
            onboarding.show { [weak self] openSettings in
                if openSettings { self?.settings.show() }
            }
        } else if !UUReader.isTrusted || !ConfigStore.shared.isConfigured {
            settings.show(page: UUReader.isTrusted ? nil : .general)
        }
    }

    /// 退出前异步收尾（恢复物理屏、移除虚拟屏、还原布局）。
    /// 注意：.terminateLater 期间主队列的延时任务不会执行，收尾会卡住；
    /// 所以先取消本次退出，收尾完成后再真正退出（最多等 8 秒，残留由看门狗兜底）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        var done = false
        let finish = {
            guard !done else { return }
            done = true
            Log.info("退出 UUDisplay")
            NSApp.terminate(nil)
        }
        coordinator.shutdown(completion: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: finish)
        return .terminateCancel
    }

    /// 看门狗以 LaunchAgent 形式安装（KeepAlive）：仅当用户在设置里开启时安装，否则确保已卸载
    private func registerWatchdog() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            Log.info("非 .app 运行，跳过看门狗安装（可手动运行 --watchdog）")
            return
        }
        if ConfigStore.shared.config.shouldRunWatchdog {
            WatchdogAgent.ensureInstalled()
        } else {
            WatchdogAgent.uninstall()
        }
    }

    /// 全局快捷键 ⌃⌥⌘9：立即恢复物理屏（Carbon 热键，无需任何权限）
    private func installHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { delegate.coordinator.restorePhysical() }
            return noErr
        }, 1, &spec, me, nil)
        let id = EventHotKeyID(signature: OSType(0x5555_4453), id: 1)  // 'UUDS'
        let err = RegisterEventHotKey(UInt32(kVK_ANSI_9), UInt32(cmdKey | optionKey | controlKey), id,
                                      GetApplicationEventTarget(), 0, &hotKeyRef)
        Log.info(err == noErr ? "已注册快捷键 ⌃⌥⌘9" : "⚠️ 快捷键 ⌃⌥⌘9 注册失败 \(err)")
    }

    /// 压测：随机连入/换设备/断开，间隔 0.3–6 秒，制造上一轮未收尾就进入下一轮的情况
    private func stress(rounds: Int) {
        coordinator.display.shouldDisablePhysical = { [weak self] in self?.coordinator.physicalDisableAllowed ?? false }
        coordinator.display.recoverIfNeeded()
        let devices = ["iPad Air", "OPPO Pad 3 Pro", "iPhone 17", "OPPO Reno13 Pro", "M1"]
        // UUDISPLAY_STRESS_SLOW=1：每段停留 2.5–5 秒，确保走到关闭物理屏
        let slow = ProcessInfo.processInfo.environment["UUDISPLAY_STRESS_SLOW"] == "1"
        func hold(_ r: ClosedRange<Double>) -> Double { slow ? Double.random(in: 2.5...5) : Double.random(in: r) }
        var t = 0.0
        for r in 1...rounds {
            let a = devices.randomElement()!
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                Log.info("—— 压测第 \(r)/\(rounds) 轮：连入 \(a)")
                self?.coordinator.simulatedName = a
                self?.coordinator.handleConnect()
            }
            t += hold(0.3...4)
            if Bool.random() {
                let b = devices.randomElement()!
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    Log.info("—— 换设备为 \(b)")
                    self?.coordinator.simulatedName = b
                    self?.coordinator.handleConnect()
                }
                t += hold(0.3...3)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                Log.info("—— 断开")
                self?.coordinator.handleDisconnect()
                self?.coordinator.simulatedName = nil
            }
            t += hold(0.3...6)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 1) {
            Log.info("—— 压测结束，退出")
            NSApp.terminate(nil)
        }
    }

    private func simulate(name: String, seconds: Double) {
        coordinator.display.shouldDisablePhysical = { [weak self] in self?.coordinator.physicalDisableAllowed ?? false }
        coordinator.display.recoverIfNeeded()
        // "A>B"：先按 A 连入，3 秒后识别为 B（模拟名称延迟出现导致的重建）
        let names = name.components(separatedBy: ">")
        Log.info("模拟连入：\(name)，\(Int(seconds)) 秒后断开")
        coordinator.simulatedName = names[0]
        coordinator.handleConnect()
        if names.count > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.coordinator.simulatedName = names[1]
                self?.coordinator.handleConnect()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.coordinator.handleDisconnect()
            self?.coordinator.simulatedName = nil
            Log.info("模拟断开完成")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }  // 顶层代码运行在主线程
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
