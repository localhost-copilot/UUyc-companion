// 连入/断开 → 选设备配置 → 建屏/还原
// 设备名通常与连入同秒出现；读不到时先按「上次连入设备」或「默认设备」建屏，名称出现后不一致再重建
// 连接期间持续盯控制端列表：多台设备先后接入/离开时（UU 的连接状态不中断），切到最新接入且仍在的那台
import AppKit

final class Coordinator {
    let monitor = UUMonitor()
    let display = DisplayManager()
    private let store = ConfigStore.shared

    /// 状态变化时通知菜单栏刷新
    var onChange: (() -> Void)?

    private(set) var controllerName: String?
    private var namePoll: Timer?
    private var connectedAt = Date.distantPast
    private var usedFallback = false
    private var openedUUWindow = false
    private var watchTimer: Timer?
    /// 上一次读到的控制端列表（按 UU 表格顺序）
    private var knownControllers: [String] = []

    /// 调试：模拟连入的控制端名称（不读 UU）
    var simulatedName: String?

    var connected: Bool { monitor.connected || simulatedName != nil }

    func start() {
        display.shouldDisablePhysical = { [weak self] in self?.physicalDisableAllowed ?? false }
        display.recoverIfNeeded()
        monitor.onConnect = { [weak self] in self?.handleConnect() }
        monitor.onDisconnect = { [weak self] in self?.handleDisconnect() }
        monitor.start()
    }

    /// 开关打开且私有 API 可用时关闭物理屏；看门狗是可选兜底（快捷键 ⌃⌥⌘9 始终可用）
    var physicalDisableAllowed: Bool {
        store.config.shouldDisablePhysical && PhysicalDisplays.available
    }

    var statusText: String {
        if display.wedged { return "⛔️ 屏幕设置暂时卡住了，请重启 Mac" }
        if store.config.paused { return "已暂停：连接时不做调整" }
        guard connected else { return "等待设备连接" }
        let who = controllerName ?? "未知设备"
        if let c = display.current, display.isActive {
            return "\(who) 已连接 · 屏幕已换成 \(c.sizeLabel)\(display.physicalOff ? " · Mac 屏幕已熄灭" : "")"
        }
        return "\(who) 已连接 · 屏幕没有调整"
    }

    // MARK: - 事件

    func handleConnect() {
        connectedAt = Date()
        controllerName = nil
        usedFallback = false
        openedUUWindow = false
        onChange?()
        guard !store.config.paused else { return }
        if pollName() { return }
        namePoll?.invalidate()
        namePoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if self.pollName() { t.invalidate() }
        }
    }

    func handleDisconnect() {
        namePoll?.invalidate()
        namePoll = nil
        stopWatching()
        display.remove()
        controllerName = nil
        onChange?()
    }

    /// 返回 true 表示已拿到名称、无需继续轮询
    private func pollName() -> Bool {
        guard connected, !store.config.paused else { return true }
        let elapsed = Date().timeIntervalSince(connectedAt)

        if let name = simulatedName ?? readControllerName() {
            resolve(name)
            startWatching()
            return true
        }
        // 2 秒还没名字：先按上次/默认设备建屏，继续等名字
        if elapsed >= 2, !usedFallback {
            usedFallback = true
            let fallback = store.device(named: store.config.lastDevice) ?? store.device(named: store.config.defaultDevice)
            Log.info("暂未读到控制端名称，先按「\(fallback?.name ?? "无")」处理")
            apply(fallback)
        }
        if elapsed >= 30 {
            Log.info("30 秒内未读到控制端名称，停止等待")
            return true
        }
        return false
    }

    private func readControllerName() -> String? {
        guard UUReader.isTrusted else { return nil }
        switch UUReader.readControllers() {
        case .none:
            // 主窗口没开：打开一次 UU 主界面再读
            if !openedUUWindow {
                openedUUWindow = true
                Log.info("UU 主窗口未打开，尝试打开以读取控制端名称")
                UUReader.showMainWindow()
            }
            return nil
        case .some(let names):
            knownControllers = names
            // 同时有多台时取最后一台（UU 表格按接入先后排列，最新接入的在最后）
            return names.last
        }
    }

    // MARK: - 控制端变化

    private func startWatching() {
        guard simulatedName == nil, watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkControllers() }
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        knownControllers = []
    }

    /// 新接入的设备优先；当前设备离开时换成仍在的最后一台
    private func checkControllers() {
        guard connected, !store.config.paused, UUReader.isTrusted,
              let names = UUReader.readControllers(), !names.isEmpty, names != knownControllers else { return }
        let added = names.filter { !knownControllers.contains($0) }
        knownControllers = names
        let target: String
        if let newest = added.last {
            target = newest
        } else if let current = controllerName, names.contains(current) {
            return
        } else {
            target = names.last!
        }
        guard target != controllerName else { return }
        Log.info("控制端变化：\(names)，切换到「\(target)」")
        resolve(target)
    }

    private func resolve(_ name: String) {
        controllerName = name
        Log.info("控制端：\(name)")
        let cfg: DeviceConfig?
        // 列表里没有这台：可能是后来才在 UU 登录的新设备，先从 UU 重新读一次设备列表
        if store.device(named: name) == nil, simulatedName == nil, store.importFromUU() != nil {
            Log.info("「\(name)」不在列表里，已从 UU 重新读取设备列表")
        }
        if let known = store.device(named: name) {
            cfg = known
            store.config.lastDevice = name
        } else if simulatedName != nil {
            cfg = DeviceConfig.make(name: name, kind: Presets.guessKind(name: name, isComputerGroup: false))
        } else {
            // 新版 UU 的设备列表里不一定有手机/平板：把连进来的设备记进列表，之后在设置里能直接调整。
            // 认得出型号就按它的尺寸；认不出时优先用默认设备，没有默认设备再用推测的尺寸
            let added = DeviceConfig.make(name: name, kind: Presets.guessKind(name: name, isComputerGroup: false))
            store.config.devices.append(added)
            let fallback = store.device(named: store.config.defaultDevice)
            cfg = added.needsReview ? (fallback ?? added) : added
            if cfg?.name == name { store.config.lastDevice = name }
            Log.info("「\(name)」未配置，已加入设备列表（\(added.sizeLabel)），使用「\(cfg?.name ?? "无")」")
        }
        apply(cfg)
    }

    private func apply(_ cfg: DeviceConfig?) {
        defer { onChange?() }
        guard let cfg else {
            if display.isActive { display.remove() }
            Log.info("无可用配置，不切换")
            return
        }
        if display.matches(cfg) { return }
        display.create(cfg)
    }

    // MARK: - 菜单操作

    func setPaused(_ paused: Bool) {
        store.config.paused = paused
        if paused {
            namePoll?.invalidate()
            stopWatching()
            display.remove()
        } else if connected {
            handleConnect()
        }
        onChange?()
    }

    /// 配置变更后，若正在被控则按新配置重新应用
    func configChanged() {
        if connected, !store.config.paused {
            if let name = controllerName { resolve(name) } else { handleConnect() }
        }
        onChange?()
    }

    /// 快捷键 ⌃⌥⌘9 / 菜单：立即恢复物理屏
    func restorePhysical() {
        Log.info("手动恢复物理屏")
        display.restorePhysicalNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func setDisablePhysical(_ on: Bool) {
        store.config.disablePhysical = on
        if on { display.disablePhysicalIfNeeded() } else { display.restorePhysicalNow(override: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func shutdown(completion: @escaping () -> Void) {
        display.remove(completion: completion)
    }
}
