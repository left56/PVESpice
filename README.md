# PVESpice

面向 **macOS 14+**、**Apple Silicon（arm64）** 的原生桌面应用，用于连接 **Proxmox VE** 并通过 **SPICE** 使用虚拟机控制台（显示、会话与相关能力由工程内 `CSpiceBridge` 与 Swift 层协同实现）。

## 要求

- Xcode（含 `xcodebuild`）、macOS 14 或更高版本  
- 本仓库当前仅针对 **arm64**，不产出 Intel 通用二进制  

## 预编译下载（GitHub Releases）

已发布的 **macOS arm64** 安装包见 **[GitHub Releases](https://github.com/left56/PVESpice/releases)**（zip 内为 `PVESpice.app`，解压后拖入「应用程序」即可）。维护者打 zip、发版与 tag 的流程见 [`Distribution/README.md`](Distribution/README.md)。

## 获取依赖（Vendor）

应用与 `build_release.sh` 会假定仓库根目录存在 **`Vendor-macos-arm64/`**（静态库与头文件等）。该目录由脚本生成，**不提交到 Git**（见 `.gitignore`）。

在仓库根目录执行：

```bash
./Scripts/build-deps-macos.sh
```

脚本会下载并编译上游依赖；耗时与磁盘占用取决于网络与机器性能。完成后应出现 `Vendor-macos-arm64/`，且包含例如 `libphodav-3.0.a`、`libsoup-3.0.a` 等供 Xcode / `pkg-config` 使用。

## 构建 Release

```bash
./build_release.sh
```

成功时输出类似：

`.build/release-derived/Build/Products/Release/PVESpice.app`

`.build/` 为本地构建产物目录，同样被 Git 忽略。

## 在 Xcode 中开发

打开 `PVESpice.xcodeproj`，选择 **PVESpice** scheme，目标为 **My Mac**。需已按上文准备好 `Vendor-macos-arm64/`。

## 仓库布局（简要）

| 路径 | 说明 |
|------|------|
| `PVESpiceMac/` | SwiftUI / AppKit 壳层、Proxmox 客户端、SPICE 会话封装等 |
| `CSpiceBridge/` | C/Objective-C 桥接与 SPICE 相关原生代码 |
| `Scripts/` | 依赖构建与辅助脚本（含 `package-macos-release.sh` 生成本地 Release zip） |
| `Distribution/` | 仅文档；实际 zip 由 Releases 提供，本地 zip 目录被 Git 忽略 |
| `icon.svg` | 应用图标源；可用 `Scripts/sync_app_icon.sh` 同步到 Asset Catalog |

## 许可证

本项目以 **MIT License** 发布，见仓库根目录 [`LICENSE`](LICENSE)。
