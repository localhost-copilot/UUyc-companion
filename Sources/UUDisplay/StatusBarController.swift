// 菜单栏：顶部状态卡（谁连着、屏幕现在什么样）+ 少量常用开关
import AppKit
import SwiftUI

/// 菜单顶部的状态卡
private struct StatusCard: View {
    enum State {
        case idle, paused, wedged
        case connected(name: String?, cfg: DeviceConfig?, physicalOff: Bool)
    }

    let state: State
    let needsPermission: Bool

    private var symbol: String {
        switch state {
        case .idle: return "display"
        case .paused: return "pause.circle"
        case .wedged: return "exclamationmark.triangle.fill"
        case .connected(_, let cfg, _): return cfg?.kind.symbol ?? "dot.radiowaves.left.and.right"
        }
    }

    private var tint: Color {
        switch state {
        case .idle, .paused: return .secondary
        case .wedged: return .red
        case .connected: return .accentColor
        }
    }

    private var title: String {
        switch state {
        case .idle: return "等待连接"
        case .paused: return "已暂停"
        case .wedged: return "屏幕设置卡住了"
        case .connected(let name, _, _): return name ?? "正在识别设备…"
        }
    }

    private var detail: String {
        switch state {
        case .idle: return needsPermission ? "还没授权，认不出连接的设备" : "UU远程 连上时自动准备屏幕"
        case .paused: return "连上时不做调整"
        case .wedged: return "请重启 Mac"
        case .connected(_, let cfg, let off):
            guard let cfg else { return "屏幕没有调整" }
            return "\(cfg.width) × \(cfg.height)\(cfg.hiDPI ? " 高清" : "")\(off ? " · Mac 屏幕已熄灭" : "")"
        }
    }

    private var live: Bool {
        if case .connected = state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(live ? 0.18 : 0.12))
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if live { Circle().fill(Color.green).frame(width: 6, height: 6) }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 280, alignment: .leading)
    }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: Coordinator
    private let openSettings: (SettingsPage?) -> Void
    private let store = ConfigStore.shared

    init(coordinator: Coordinator, openSettings: @escaping (SettingsPage?) -> Void) {
        self.coordinator = coordinator
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        // 关闭自动启用，否则各项设置的 isEnabled 会被覆盖
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    /// 菜单栏图标：Assets/AppIcon/MenuBarIconTemplate（模板图，深色菜单栏自动反白）；
    /// 非 .app 运行（调试）找不到资源时退回系统图标
    private static let menuBarIcon: NSImage = {
        if let image = NSImage(named: "MenuBarIconTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!
    }()

    func refresh() {
        let icon = StatusBarController.menuBarIcon
        icon.accessibilityDescription = "UU远程伴侣"
        item.button?.image = icon
        item.button?.appearsDisabled = store.config.paused  // 暂停自动切换时图标变灰
        item.button?.toolTip = "UU远程伴侣：\(coordinator.statusText)"
    }

    private var cardState: StatusCard.State {
        if coordinator.display.wedged { return .wedged }
        if store.config.paused { return .paused }
        guard coordinator.connected else { return .idle }
        let cfg = coordinator.display.isActive ? coordinator.display.current : nil
        return .connected(name: coordinator.controllerName, cfg: cfg, physicalOff: coordinator.display.physicalOff)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let card = NSMenuItem()
        let host = NSHostingView(rootView: StatusCard(state: cardState, needsPermission: !UUReader.isTrusted))
        host.frame.size = host.fittingSize
        card.view = host
        menu.addItem(card)

        if coordinator.display.physicalOff || PhysicalDisplays.pending != nil {
            let restore = action("点亮所有屏幕", #selector(restorePhysical), key: "9")
            restore.keyEquivalentModifierMask = [.control, .option, .command]
            restore.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
            menu.addItem(restore)
        }
        if !UUReader.isTrusted {
            let warn = action("授权读取设备名称…", #selector(showGeneral))
            warn.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            menu.addItem(warn)
        }
        if store.config.shouldDisablePhysical && store.config.shouldRunWatchdog && !Watchdog.isRunning {
            let warn = action("后台守护没有运行…", #selector(showRecovery))
            warn.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        let auto = action("自动准备屏幕", #selector(togglePause))
        auto.state = store.config.paused ? .off : .on
        menu.addItem(auto)
        let physical = action("远程时熄灭 Mac 屏幕", #selector(toggleDisablePhysical))
        physical.state = store.config.shouldDisablePhysical ? .on : .off
        physical.isEnabled = !store.config.paused
        menu.addItem(physical)
        menu.addItem(.separator())

        menu.addItem(action("设置…", #selector(showSettings), key: ","))
        menu.addItem(action("退出", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func showSettings() { openSettings(nil) }

    @objc private func showGeneral() { openSettings(.general) }

    @objc private func showRecovery() { openSettings(.recovery) }

    @objc private func restorePhysical() { coordinator.restorePhysical() }

    @objc private func toggleDisablePhysical() { coordinator.setDisablePhysical(!store.config.shouldDisablePhysical) }

    @objc private func togglePause() { coordinator.setPaused(!store.config.paused) }

    @objc private func quit() { NSApp.terminate(nil) }
}
