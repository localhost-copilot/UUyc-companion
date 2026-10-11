// 首次引导：一个窗口三步走——介绍 → 授权 → 确认设备。取代原来的功能导览、权限窗口和设备向导
import AppKit
import SwiftUI

final class OnboardingModel: ObservableObject {
    enum Step: Int { case welcome, permission, devices }

    @Published var step: Step = .welcome
    @Published var trusted = UUReader.isTrusted
    @Published var devices: [DeviceConfig] = ConfigStore.shared.config.devices
    @Published var readFailed = false

    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ax = UUReader.isTrusted
            guard ax != self.trusted else { return }
            self.trusted = ax
            Log.info("辅助功能权限：\(ax ? "已授权" : "未授权")")
            // 授权完成后自动进入下一步
            if ax && self.step == .permission {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.next() }
            }
        }
    }

    func stop() { timer?.invalidate() }

    func next() {
        withAnimation(.easeInOut(duration: 0.25)) {
            switch step {
            case .welcome: step = trusted ? .devices : .permission
            case .permission: step = .devices
            case .devices: break
            }
        }
        if step == .devices { readDevices() }
    }

    func readDevices() {
        readFailed = ConfigStore.shared.importFromUU() == nil
        devices = ConfigStore.shared.config.devices
    }
}

// MARK: - 插画

/// 平板 ⇢ Mac：左侧设备与右侧虚拟屏比例一致
private struct HeroArt: View {
    var body: some View {
        HStack(spacing: 28) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.gradient).padding(7)
                )
                .frame(width: 150, height: 104)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.gradient)
                            .frame(width: 150 - 14, height: 104 - 14)
                    )
                    .frame(width: 190, height: 120)
                Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 26, height: 20)
                Capsule().fill(Color.primary.opacity(0.7)).frame(width: 80, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 三步

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 26) {
            HeroArt().padding(.top, 8)
            VStack(spacing: 6) {
                Text("远程画面，刚好铺满").font(.largeTitle.bold())
                Text("用平板或手机通过 UU远程 操控这台 Mac 时，\n自动准备一块和你的设备尺寸一致的屏幕。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(symbol: "rectangle.dashed", title: "没有黑边，文字清晰",
                           detail: "认出连进来的设备，几秒内换上合适的高清屏幕；断开后一切还原。")
                FeatureRow(symbol: "moon", title: "可以熄灭 Mac 的屏幕",
                           detail: "远程期间只留一块屏幕，窗口不会跑到看不见的地方。")
                FeatureRow(symbol: "lifepreserver", title: "随时找回",
                           detail: "坐在 Mac 前按 ⌃⌥⌘9，所有屏幕立刻亮起来。")
            }
            .frame(maxWidth: 420)
        }
    }
}

private struct PermissionStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: model.trusted ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 64))
                .foregroundStyle(model.trusted ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .padding(.top, 24)
            VStack(spacing: 6) {
                Text("允许读取设备名称").font(.largeTitle.bold())
                Text("这样它才能认出连进来的是哪台设备。\n只读取 UU远程 窗口里的设备名，不读取其他内容，也不联网。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            PermissionRow(trusted: model.trusted)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                .frame(maxWidth: 460)
        }
    }
}

private struct DevicesStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("你的设备").font(.largeTitle.bold()).padding(.top, 8)
                Text(model.devices.isEmpty
                     ? "还没读到设备。打开 UU远程 并停在「全部设备」页面，再点「重新读取」。"
                     : "从 UU远程 读到这些设备，屏幕尺寸已按名称填好。\n标了橙色的是推测的尺寸，请在设置里核对。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.devices) { d in
                        HStack(spacing: 12) {
                            Image(systemName: d.kind.symbol).foregroundStyle(.tint).frame(width: 24)
                            Text(d.name)
                            Spacer()
                            Text(verbatim: "\(d.width) × \(d.height)").monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: d.needsReview ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(d.needsReview ? .orange : .green)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        if d.id != model.devices.last?.id { Divider().padding(.leading, 50) }
                    }
                }
            }
            .frame(maxWidth: 460, maxHeight: 230)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            Button("重新读取") { model.readDevices() }.controlSize(.small)
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onFinish: (_ openSettings: Bool) -> Void

    private var needsReview: Bool { model.devices.isEmpty || model.devices.contains(where: \.needsReview) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .permission: PermissionStep(model: model)
                case .devices: DevicesStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 40).padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(model.step)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().fill(i == model.step.rawValue ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                switch model.step {
                case .welcome:
                    Button("开始") { model.next() }.keyboardShortcut(.defaultAction)
                case .permission:
                    if !model.trusted { Button("稍后") { model.next() } }
                    Button("继续") { model.next() }.keyboardShortcut(.defaultAction).disabled(!model.trusted)
                case .devices:
                    if needsReview {
                        Button("以后再说") { onFinish(false) }
                        Button("去核对尺寸") { onFinish(true) }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("完成") { onFinish(false) }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 620, height: 600)
    }
}

final class OnboardingWindowController {
    private var window: NSWindow?
    private var model: OnboardingModel?

    /// - Parameter onFinish: 参数表示是否要接着打开设置窗口核对设备
    func show(onFinish: @escaping (Bool) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = OnboardingModel()
        model.start()
        self.model = model
        var finished = false
        let finish: (Bool) -> Void = { [weak self] openSettings in
            guard !finished else { return }
            finished = true
            ConfigStore.shared.config.tourShown = true
            self?.window?.close()
            onFinish(openSettings)
        }
        let hosting = NSHostingController(rootView: OnboardingView(model: model, onFinish: finish))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.setContentSize(hosting.view.fittingSize)
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.model?.stop()
            self?.model = nil
            self?.window = nil
            finish(false)
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 调试：渲染三步为 PNG（--render-onboarding <目录>）
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = OnboardingModel()
        if ProcessInfo.processInfo.environment["UUDISPLAY_RENDER_SAMPLE"] == "1" || model.devices.isEmpty {
            model.devices = ["iPad Air", "OPPO Pad 3 Pro", "iPhone 17", "Xiaomi Pad 6", "M1"].map {
                DeviceConfig.make(name: $0, kind: Presets.guessKind(name: $0, isComputerGroup: $0 == "M1"))
            }
        }
        for step in [OnboardingModel.Step.welcome, .permission, .devices] {
            model.step = step
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model) { _ in }))
            w.styleMask = [.titled, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.setContentSize(NSSize(width: 620, height: 600))
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if let view = w.contentView?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("onboarding-\(step.rawValue + 1).png"))
            }
            w.close()
        }
    }
}
