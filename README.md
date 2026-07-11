# LiteStat

一款超轻量级的 macOS 菜单栏系统监控工具。

## 简介

LiteStat  是 MiniStat 的精简版本，专注于最核心的系统监控功能。它只在菜单栏显示关键指标，没有面板、没有复杂设置，简洁高效。

## 功能特性

- 📊 **实时显示**：CPU 使用率、内存使用率、网络上下行速度
- 🔋 **电源监控**：实时功耗（W）、待机时间估算、充电状态识别
- 🎯 **极简设计**：仅占用菜单栏空间，无弹窗无面板
- ⚡ **轻量高效**：423 行代码，资源占用极低
- 🌙 **智能节能**：系统自动休眠/锁屏时暂停监控
- 🖱️ **便捷操作**：
  - 左键点击：立即刷新数据
  - 右键点击：显示菜单（关于、退出）

## 界面展示

```
[下载速度]↓ C:[CPU]%    ← 第一行
[上传速度]↑ M:[内存]%   ← 第二行
[功耗]W H:[时间]        ← 第三行（有电池设备）
```

示例（放电状态）：
```
  1.5M↓ C: 25%
  256K↑ M: 62%
  8.2W H:  5.3
```

插电/充电状态：
```
  1.5M↓ C: 25%
  256K↑ M: 62%
 12.3W H:  INF
```

### 第三行说明

| 状态 | 显示内容 |
|------|---------|
| 电池放电 | 待机时间（小时，一位小数） |
| 插电 / 充电 | `INF`（无限续航） |

- 功耗经 EMA 平滑处理，避免数字抖动
- 待机时间优先使用系统估算，系统无估算时自行计算（剩余能量 ÷ 放电功率）
- 兼容 AlDente 等充电管理工具（通过电流方向识别实际充电状态）

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

- **代码量**：423 行 Swift 代码
- **依赖**：仅使用系统框架（Cocoa、IOKit）
- **更新频率**：每秒更新一次
- **内存占用**：< 10 MB
- **CPU 占用**：< 1%
- **网络监控**：仅统计物理网卡（en*，WiFi/有线），过滤虚拟接口
- **电源监控**：通过 IOPS + AppleSmartBattery 双数据源，EMA 平滑功耗读数

## 完整版对比

| 功能 | LiteStat Lite | LiteStat 完整版 |
|------|---------------|-----------------|
| 菜单栏显示 | ✅ | ✅ |
| 详细信息面板 | ❌ | ✅ |
| 多语言支持 | ❌ | ✅（7种语言） |
| 主题切换 | ❌ | ✅（明/暗） |
| GPU 监控 | ❌ | ✅ |
| 磁盘监控 | ❌ | ✅ |
| 电池/电源 | ✅ | ✅ |
| 温度/风扇 | ❌ | ✅ |
| 代码行数 | ~423 行 | ~445 行 |

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
