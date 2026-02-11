# LiteStat Lite

一款超轻量级的 macOS 菜单栏系统监控工具。

## 简介

LiteStat  是 MiniStat 的精简版本，专注于最核心的系统监控功能。它只在菜单栏显示关键指标，没有面板、没有复杂设置，简洁高效。

## 功能特性

- 📊 **实时显示**：CPU 使用率、内存使用率、网络上下行速度
- 🎯 **极简设计**：仅占用菜单栏空间，无弹窗无面板
- ⚡ **轻量高效**：284 行代码，资源占用极低
- 🌙 **智能节能**：系统自动休眠/锁屏时暂停监控
- 🖱️ **便捷操作**：
  - 左键点击：立即刷新数据
  - 右键点击：显示菜单（关于、退出）

## 界面展示

```
[下载速度]↓ C:[CPU]%    ← 第一行
[上传速度]↑ M:[内存]%   ← 第二行
```

示例：
```
  1.5M↓ C: 25%
  256K↑ M: 62%
```

## 系统要求

- macOS 10.15 或更高版本
- Intel 或 Apple Silicon Mac

## 安装使用

### 方式一：直接编译

```bash
git clone https://github.com/tzdjack/LiteStat.git
cd LiteStat
swiftc -O -o LiteStat Sources/LiteStat.swift -framework Cocoa -framework IOKit -parse-as-library
./LiteStat
```

### 方式二：打包为 .app

```bash
# 编译
swiftc -O -o LiteStat Sources/LiteStat.swift -framework Cocoa -framework IOKit -parse-as-library

# 创建应用包
mkdir -p LiteStat.app/Contents/MacOS
mkdir -p LiteStat.app/Contents/Resources
cp LiteStat LiteStat.app/Contents/MacOS/
cp Sources/Info.plist LiteStat.app/Contents/
cp Sources/AppIcon.icns LiteStat.app/Contents/Resources/

# 运行
open LiteStat.app
```

### 开机自启

1. 打开「系统设置」→「通用」→「登录项」
2. 点击「+」添加 LiteStat.app

## 技术细节

- **代码量**：285 行 Swift 代码
- **依赖**：仅使用系统框架（Cocoa、IOKit）
- **更新频率**：每秒更新一次
- **内存占用**：< 10 MB
- **CPU 占用**：< 1%

## 完整版对比

| 功能 | LiteStat Lite | LiteStat 完整版 |
|------|---------------|-----------------|
| 菜单栏显示 | ✅ | ✅ |
| 详细信息面板 | ❌ | ✅ |
| 多语言支持 | ❌ | ✅（7种语言） |
| 主题切换 | ❌ | ✅（明/暗） |
| GPU 监控 | ❌ | ✅ |
| 磁盘监控 | ❌ | ✅ |
| 电池状态 | ❌ | ✅ |
| 温度/风扇 | ❌ | ✅ |
| 代码行数 | ~285 行 | ~445 行 |

## 定制修改

如需修改显示格式，编辑 `AppDelegate.updateMenuBarDisplay()` 方法：

```swift
// 修改显示格式示例
let line1 = "CPU:\(cpuStr)% MEM:\(memStr)%"  // 单行显示
let line2 = "↓\(downStr) ↑\(upStr)"           // 网速在第二行
```

## 许可证

MIT License

Copyright (c) 2026 tzdjack

## 致谢

MiniStat 精简版：https://github.com/tzdjack/MiniStat

---

**提示**：如需精简功能（如磁盘监控、电池状态、GPU 使用率等），请使用 [MiniStat 精简版](https://github.com/tzdjack/MiniStat)。
