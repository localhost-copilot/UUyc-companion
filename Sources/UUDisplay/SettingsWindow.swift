// 设置窗口：左侧边栏（设备列表 / 通用 / 找回屏幕），右侧详情；所有修改立即生效，没有「保存」按钮
import AppKit
import PermissionFlow
import ServiceManagement
import SwiftUI
import SystemSettingsKit

enum SettingsPage: Hashable {
    case device(String)
    case general
    case recovery
}

final class SettingsModel: ObservableObject {
    // 注意：SwiftUI 的 @State 在仅有 Command Line Tools 时无法编译（宏插件缺失），界面状态统一放在 ObservableObject 里
    @Published var page: SettingsPage? = .general
    @Published var devices: [DeviceConfig]
    @Published var defaultDevice: String
    @Published var autoVirtual: Bool
    @Published var disablePhysical: Bool
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var watchdogEnabled: Bool
    @Published var watchdogRunning = Watchdog.isRunning
    @Published var physicalOff = PhysicalDisplays.pending != nil
    @Published var trusted = UUReader.isTrusted
    @Published var importMessage: String?

    var onConfigChanged: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var restorePhysical: (() -> Void)?
    private var timer: Timer?
    private var pendingApply: DispatchWorkItem?
    private let store = ConfigStore.shared

    init() {
        devices = store.config.devices
        defaultDevice = store.config.defaultDevice ?? ""
        autoVirtual = !store.config.paused
        disablePhysical = store.config.shouldDisablePhysical
        watchdogEnabled = store.config.shouldRunWatchdog
        if let first = devices.first(where: \.needsReview) ?? devices.first { page = .device(first.name) }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        pendingApply?.perform()
    }

    func refresh() {
        let running = Watchdog.isRunning
        if running != watchdogRunning { watchdogRunning = running }
        let off = PhysicalDisplays.pending != nil
        if off != physicalOff { physicalOff = off }
        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
        let ax = UUReader.isTrusted
        if ax != trusted { trusted = ax }
    }

    // MARK: 设备

    func binding(for name: String) -> Binding<DeviceConfig>? {
        guard let current = devices.first(where: { $0.name == name }) else { return nil }
        return Binding(get: { [weak self] in self?.devices.first { $0.name == name } ?? current },
                       set: { [weak self] in self?.update($0) })
    }

    func update(_ cfg: DeviceConfig) {
        guard let i = devices.firstIndex(where: { $0.name == cfg.name }) else { return }
        devices[i] = cfg
        persistDevices()
    }

    /// 配置立即写盘；通知协调器重建虚拟屏稍作合并，避免输入自定义尺寸时每敲一个数字就重建一次
    private func persistDevices() {
        store.config.devices = devices
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onConfigChanged?() }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func setDefault(_ name: String) {
        defaultDevice = name
        store.config.defaultDevice = name.isEmpty ? nil : name
    }

    func remove(_ name: String) {
        devices.removeAll { $0.name == name }
        if defaultDevice == name { setDefault("") }
        persistDevices()
        page = devices.first.map { .device($0.name) } ?? .general
    }

    func add(name raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if !devices.contains(where: { $0.name == name }) {
            devices.append(DeviceConfig.make(name: name, kind: Presets.guessKind(name: name, isComputerGroup: false)))
            persistDevices()
        }
        page = .device(name)
    }

    func importFromUU() {
        guard let n = store.importFromUU() else {
            importMessage = trusted
                ? "没有读到 UU远程 的设备列表。请打开 UU远程 并停在「全部设备」页面，再试一次。"
                : "需要先允许读取设备名称（在「通用」里授权）。"
            return
        }
        importMessage = n == 0 ? "UU远程 里没有其他设备。" : nil
        devices = store.config.devices
        defaultDevice = store.config.defaultDevice ?? ""
        persistDevices()
        if case .device(let name)? = page, devices.contains(where: { $0.name == name }) { return }
        if let first = devices.first { page = .device(first.name) }
    }

    /// 用 NSAlert 输入名称（比在 SwiftUI 里维护弹层状态简单）
    func promptAdd() {
        let alert = NSAlert()
        alert.messageText = "添加设备"
        alert.informativeText = "名字要和 UU远程 里显示的完全一样，连接时才认得出来。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "例如 iPad Air"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { add(name: field.stringValue) }
    }

    // MARK: 通用

    func toggleLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "没有设置成功。请先把 UU远程伴侣 放进「应用程序」文件夹，再试一次。"
            Log.info("⚠️ 开机启动设置失败：\(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func toggleAutoVirtual(_ on: Bool) {
        autoVirtual = on
        setPaused?(!on)
        Log.info("设置：自动启动虚拟屏 → \(on ? "开" : "关")")
    }

    func toggleDisablePhysical(_ on: Bool) {
        disablePhysical = on
        setDisablePhysical?(on)
        Log.info("设置：自动软关闭物理屏 → \(on ? "开" : "关")")
    }

    /// 只有在这里开启，看门狗才会安装为 LaunchAgent 并加载；关闭即卸载
    func toggleWatchdog(_ on: Bool) {
        watchdogEnabled = on
        store.config.watchdogEnabled = on
        Log.info("设置：看门狗 → \(on ? "开" : "关")")
        if on { WatchdogAgent.ensureInstalled() } else { WatchdogAgent.uninstall() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    static func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
        let credits = NSAttributedString(
            string: "用平板或手机通过 UU远程 操控这台 Mac 时，它会自动准备一块和你的设备尺寸一致的屏幕，让画面刚好铺满；断开后一切恢复原样。\n\n使用的开源组件：PermissionFlow、FreeDisplay（均为 MIT 协议）",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "UU远程伴侣",
            .applicationVersion: version,
            .credits: credits,
        ])
    }
}

// MARK: - 共用小部件

/// 按真实比例画出的屏幕，标出像素尺寸；用来一眼看出比例对不对
struct ScreenPreview: View {
    let width: Int
    let height: Int
    var hiDPI = true
    var box = CGSize(width: 340, height: 190)

    private var size: CGSize {
        guard width > 0, height > 0 else { return box }
        let r = CGFloat(width) / CGFloat(height)
        return r > box.width / box.height ? CGSize(width: box.width, height: box.width / r) : CGSize(width: box.height * r, height: box.height)
    }

    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(
                    Text(verbatim: "\(width) × \(height)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                )
                .frame(width: size.width, height: size.height)
                .shadow(color: Color.accentColor.opacity(0.25), radius: 12, y: 4)
                .frame(width: box.width, height: box.height)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: width)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: height)
            Text(verbatim: hiDPI && width > 1 && height > 1
                 ? "高清 · 界面按 \(width / 2) × \(height / 2) 显示"
                 : "标准 · 界面按 \(width) × \(height) 显示")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("屏幕尺寸 \(width) 乘 \(height)")
    }
}

struct KeyCaps: View {
    var size: CGFloat = 44

    private func cap(_ symbol: String, _ name: String?) -> some View {
        VStack(spacing: 1) {
            Text(symbol).font(.system(size: size * 0.42, weight: .medium, design: .rounded))
            if let name { Text(name).font(.system(size: size * 0.2)) }
        }
        .frame(width: name == nil ? size : size * 1.3, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1.5)
    }

    var body: some View {
        HStack(spacing: 6) {
            cap("⌃", "control")
            cap("⌥", "option")
            cap("⌘", "command")
            cap("9", nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("快捷键：control、option、command 和 9")
    }
}

/// 授权状态 + 授权按钮（设置「通用」页与首次引导共用）
struct PermissionRow: View {
    let trusted: Bool

    private var appURL: URL { Bundle.main.bundleURL }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // macOS 27 起叫「设备控制和数据访问」，更早为「辅助功能」；固定取简体中文
                Text(PermissionFlowResources.localizedString(
                    for: PermissionFlowResources.accessibilityName(), localeIdentifier: "zh-Hans"))
                Text(trusted ? "用来读取 UU远程 里显示的设备名称，不会读取其他内容。"
                             : "点「授权」后，把旁边小窗口里的 UU远程伴侣 拖进列表。如果列表里已经有它却还显示未授权，先点「−」删掉再拖一次。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if trusted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                PermissionFlowButton(
                    pane: .accessibility,
                    suggestedAppURLs: [appURL],
                    configuration: .init(requiredAppURLs: [appURL], promptForAccessibilityTrust: false, localeIdentifier: "zh-Hans")
                ) { _ in Text("授权") }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - 侧边栏

private struct DeviceSidebarRow: View {
    let cfg: DeviceConfig
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cfg.kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(cfg.name).lineLimit(1)
                Text(verbatim: "\(cfg.width) × \(cfg.height)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            if cfg.needsReview {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("尺寸是推测的，请核对")
            } else if isDefault {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary).help("认不出设备时用这台")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.page) {
                Section("连接设备") {
                    ForEach(model.devices) { d in
                        DeviceSidebarRow(cfg: d, isDefault: model.defaultDevice == d.name)
                            .tag(SettingsPage.device(d.name))
                            .contextMenu {
                                Button("认不出设备时用这台") { model.setDefault(d.name) }
                                Divider()
                                Button("移除", role: .destructive) { model.remove(d.name) }
                            }
                    }
                    if model.devices.isEmpty {
                        Text("还没有设备").foregroundStyle(.secondary)
                    }
                }
                Section("这台 Mac") {
                    Label("通用", systemImage: "gearshape").tag(SettingsPage.general)
                    Label("找回屏幕", systemImage: "lifepreserver").tag(SettingsPage.recovery)
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 2) {
                Button { model.promptAdd() } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                    .help("手动添加设备")
                Button { model.importFromUU() } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 20) }
                    .help("从 UU远程 重新读取设备列表")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .frame(width: 230)
    }
}

// MARK: - 设备详情

private struct DeviceDetail: View {
    @ObservedObject var model: SettingsModel
    @Binding var cfg: DeviceConfig

    private var presetSelection: Binding<String> {
        Binding(get: {
            guard let p = Presets.preset(id: cfg.presetID), p.kind == cfg.kind else { return Presets.customID }
            return p.id
        }, set: { id in
            cfg.presetID = id == Presets.customID ? nil : id
            if let p = Presets.preset(id: id) { cfg.width = p.width; cfg.height = p.height }
        })
    }

    private var kindSelection: Binding<DeviceKind> {
        Binding(get: { cfg.kind }, set: { k in
            cfg.kind = k
            if Presets.preset(id: cfg.presetID)?.kind != k {
                let fresh = DeviceConfig.make(name: cfg.name, kind: k)
                cfg.presetID = fresh.presetID; cfg.width = fresh.width; cfg.height = fresh.height
            }
        })
    }

    private var isCustom: Bool { presetSelection.wrappedValue == Presets.customID }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    ScreenPreview(width: cfg.width, height: cfg.height, hiDPI: cfg.hiDPI)
                    Picker("", selection: kindSelection) {
                        ForEach(DeviceKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if cfg.needsReview {
                Section {
                    Label {
                        Text("这是按「\(cfg.kind.label)」推测的常见尺寸，不一定适合这台设备。请查到它的屏幕分辨率，选「自定义」填进去；对得上就不会有黑边。")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                    Button("尺寸没问题") { cfg.presetID = nil }
                }
            }

            Section {
                Picker("屏幕尺寸", selection: presetSelection) {
                    ForEach(Presets.all.filter { $0.kind == cfg.kind }) { p in
                        Text(verbatim: "\(p.name)  \(p.width)×\(p.height)").tag(p.id)
                    }
                    Divider()
                    Text("自定义").tag(Presets.customID)
                }
                if isCustom {
                    LabeledContent("宽 × 高（像素）") {
                        HStack(spacing: 6) {
                            TextField("宽", value: $cfg.width, format: .number.grouping(.never))
                                .frame(width: 70).multilineTextAlignment(.trailing)
                            Text("×").foregroundStyle(.secondary)
                            TextField("高", value: $cfg.height, format: .number.grouping(.never))
                                .frame(width: 70).multilineTextAlignment(.trailing)
                        }
                        .labelsHidden()
                    }
                    if cfg.width < cfg.height {
                        Text("请按横屏填写：大的数填「宽」，小的数填「高」。")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("填规格表上的原始分辨率，不要自己除以 2。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $cfg.hiDPI) {
                    Text("高清")
                    Text("文字和图标更清晰（推荐）")
                }
            }

            Section {
                Toggle(isOn: Binding(get: { model.defaultDevice == cfg.name },
                                     set: { model.setDefault($0 ? cfg.name : "") })) {
                    Text("认不出设备时用这台")
                    Text("读不到连接设备的名字，或它不在列表里时，按这台的尺寸准备屏幕")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("移除这台设备", role: .destructive) { model.remove(cfg.name) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(cfg.name)
    }
}

// MARK: - 通用

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.autoVirtual }, set: { model.toggleAutoVirtual($0) })) {
                    Text("连上时自动准备屏幕")
                    Text("按连接设备的尺寸准备一块虚拟屏幕，断开后收起。关掉后连上时不做任何调整。")
                }
                Toggle(isOn: Binding(get: { model.disablePhysical }, set: { model.toggleDisablePhysical($0) })) {
                    Text("远程时熄灭 Mac 的屏幕")
                    Text("只留下虚拟屏幕，窗口不会跑到看不见的地方；断开后自动亮回来。")
                }
                .disabled(!model.autoVirtual)
            }

            Section {
                Picker("认不出设备时", selection: Binding(get: { model.defaultDevice }, set: { model.setDefault($0) })) {
                    Text("不调整").tag("")
                    ForEach(model.devices) { Text($0.name).tag($0.name) }
                }
            } footer: {
                Text("读不到连接设备的名字，或它不在列表里时使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("开机时自动打开", isOn: Binding(get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
                if let err = model.loginError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("权限") {
                PermissionRow(trusted: model.trusted)
            }

            Section {
                HStack {
                    Button("关于 UU远程伴侣") { SettingsModel.showAbout() }
                    Spacer()
                    Button("退出 UU远程伴侣") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
    }
}

// MARK: - 找回屏幕

private struct RecoveryPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    KeyCaps(size: 52)
                    Text("屏幕黑着的时候，坐在 Mac 前按下这组键，所有屏幕立刻亮起来。\n远程画面不受影响，这次连接期间也不会再熄灭。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("现在点亮所有屏幕") { model.restorePhysical?() }
                        .disabled(!model.physicalOff)
                        .help(model.physicalOff ? "" : "现在没有熄灭的屏幕")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                Toggle(isOn: Binding(get: { model.watchdogEnabled }, set: { model.toggleWatchdog($0) })) {
                    Text("后台守护")
                    Text("UU远程伴侣 意外退出、卡住，或 UU远程 断开后屏幕没亮时，几秒内自动点亮屏幕。")
                }
                if model.watchdogEnabled {
                    LabeledContent("状态") {
                        if model.watchdogRunning {
                            Label("正在值守", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            HStack {
                                Label("没有运行", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                Button("去系统设置允许") { SystemSettings.open(.loginItems) }
                            }
                        }
                    }
                }
            } footer: {
                Text("打开时 macOS 会提示「已添加后台项目」，这是正常的。关掉开关即彻底移除。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("以上都不行时，重新打开 UU远程伴侣，或者重启 Mac，屏幕一定会恢复。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("找回屏幕")
    }
}

// MARK: - 整体

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    @ViewBuilder private var detail: some View {
        switch model.page {
        case .device(let name)?:
            if let b = model.binding(for: name) {
                DeviceDetail(model: model, cfg: b).id(name)
            } else {
                GeneralPage(model: model)
            }
        case .recovery?:
            RecoveryPage(model: model)
        case .general?, nil:
            GeneralPage(model: model)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            Divider()
            VStack(spacing: 0) {
                if let msg = model.importMessage {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(msg).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { model.importMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(Color.orange.opacity(0.12))
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 560)
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    var currentModel: SettingsModel? { model }
    var currentWindow: NSWindow? { window }
    var onConfigChanged: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var restorePhysical: (() -> Void)?

    /// - Parameter page: 打开时显示的页面，nil 表示保持默认（优先显示需要核对的设备）
    func show(page: SettingsPage? = nil) {
        if let window, let model {
            if let page { model.page = page }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SettingsModel()
        if let page { model.page = page }
        model.onConfigChanged = onConfigChanged
        model.setDisablePhysical = setDisablePhysical
        model.setPaused = setPaused
        model.restorePhysical = restorePhysical
        model.start()
        self.model = model
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = "UU远程伴侣"
        w.isReleasedWhenClosed = false
        w.setContentSize(hosting.view.fittingSize)  // 先定好尺寸再居中，否则按 0×0 居中会偏到右侧
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.model?.stop()
            self?.model = nil
            self?.window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 调试：渲染各页面为 PNG（--render-settings <目录>）
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = SettingsModel()
        if ProcessInfo.processInfo.environment["UUDISPLAY_RENDER_SAMPLE"] == "1" || model.devices.isEmpty {
            model.devices = ["iPad Air", "OPPO Pad 3 Pro", "iPhone 17", "Xiaomi Pad 6", "M1"].map {
                DeviceConfig.make(name: $0, kind: Presets.guessKind(name: $0, isComputerGroup: $0 == "M1"))
            }
            model.defaultDevice = "iPad Air"
        }
        var pages: [(String, SettingsPage)] = [("general", .general), ("recovery", .recovery)]
        if let d = model.devices.first(where: { !$0.needsReview }) { pages.append(("device", .device(d.name))) }
        if let d = model.devices.first(where: \.needsReview) { pages.append(("device-review", .device(d.name))) }
        for (name, page) in pages {
            model.page = page
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.styleMask = [.titled]
            w.title = "UU远程伴侣"
            w.setContentSize(NSSize(width: 780, height: 560))
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            // 侧边栏毛玻璃离屏画不出来；有屏幕录制权限时用 screencapture 截真实窗口
            let out = dir.appendingPathComponent("settings-\(name).png")
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", out.path]
            try? shot.run()
            shot.waitUntilExit()
            if shot.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) { w.close(); continue }
            if let view = w.contentView?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-\(name).png"))
            }
            w.close()
        }
    }
}
