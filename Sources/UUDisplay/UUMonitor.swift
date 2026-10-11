// 优先检测覆盖窗口；部分 UU 版本不创建覆盖窗口，需读取主界面的控制端表格。
import CoreGraphics
import Foundation

final class UUMonitor {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var connected = false

    private var timer: Timer?
    private var lastSeen = Date.distantPast
    /// 切换主屏时覆盖窗口会短暂重建，断开需持续缺席这么久才算数
    private let debounce: TimeInterval = 1.5
    private let connectionPresent: () -> Bool
    private let now: () -> Date
    private let publishConnection: (Bool) -> Void

    init(connectionPresent: @escaping () -> Bool = UUMonitor.connectionPresent,
         now: @escaping () -> Date = Date.init,
         publishConnection: @escaping (Bool) -> Void = UUMonitor.publishConnection) {
        self.connectionPresent = connectionPresent
        self.now = now
        self.publishConnection = publishConnection
    }

    static func connectionPresent() -> Bool {
        if overlayPresent() { return true }
        guard UUReader.isTrusted else { return false }
        guard let controllers = UUReader.readControllers() else {
            UUReader.showMainWindow()
            return false
        }
        return !controllers.isEmpty
    }

    static func overlayPresent() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "UURemoteServer" }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() {
        let now = now()
        if connectionPresent() {
            lastSeen = now
            if !connected {
                connected = true
                Log.info("检测到 UU 连入")
                onConnect?()
            }
        } else if connected, now.timeIntervalSince(lastSeen) > debounce {
            connected = false
            Log.info("检测到 UU 断开")
            onDisconnect?()
        }
        publishConnection(connected)
    }

    // 看门狗是独立进程，未必有 AX 权限；共享主进程确认的连接状态，过期即失效。
    static func publishConnection(_ connected: Bool) {
        if connected {
            Heartbeat.beat(Heartbeat.connectionURL)
        } else {
            try? FileManager.default.removeItem(at: Heartbeat.connectionURL)
        }
    }
}
