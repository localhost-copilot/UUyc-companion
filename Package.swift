// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UUDisplay",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 权限引导：打开系统设置隐私页 + 拖拽授权悬浮面板（MIT，内置副本见 Vendor/PermissionFlow/VENDORED.md）
        .package(path: "Vendor/PermissionFlow"),
    ],
    targets: [
        .target(name: "CGVirtualDisplayBridge"),
        .executableTarget(name: "vdprobe", dependencies: ["CGVirtualDisplayBridge"]),
        .executableTarget(name: "uuprobe"),
        .executableTarget(name: "uuwatch"),
        .executableTarget(name: "UUDisplay", dependencies: [
            "CGVirtualDisplayBridge",
            .product(name: "PermissionFlow", package: "PermissionFlow"),
            .product(name: "SystemSettingsKit", package: "PermissionFlow"),
        ]),
        .executableTarget(name: "dispoff", dependencies: ["CGVirtualDisplayBridge"]),
        .testTarget(name: "UUDisplayTests", dependencies: ["UUDisplay"]),
    ]
)
