<p align="center">
  <img src="docs/icon.png" width="128" alt="Kitty Clear 图标">
</p>

<h1 align="center">Kitty Clear</h1>

<p align="center">
  纯原生的 macOS 清理与维护工具：清理 · 卸载 · 磁盘分析 · 系统状态 · 软件更新 · 登录项 · 电池养护
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift + SwiftUI">
  <img src="https://img.shields.io/badge/%E5%BC%95%E6%93%8E-Mole-4A90D9" alt="引擎 Mole">
  <a href="https://github.com/YyAdnBug/kitty-clear/releases/latest"><img src="https://img.shields.io/github/v/release/YyAdnBug/kitty-clear?display_name=release&label=%E4%B8%8B%E8%BD%BD" alt="下载最新版"></a>
</p>

Kitty Clear 是开源命令行工具 [Mole](https://github.com/tw93/mole) 的图形界面，用 Swift + SwiftUI / AppKit 写成，Mole 已经打包在 App 里，装好就能用，不用另外装命令行。每次清理、卸载前先给出预览，逐项勾选，取消勾选的会被保留；东西都是移到废纸篓，不直接删除。常驻菜单栏，随时看 CPU、内存、网速和电池。新版本在 设置 › 关于 里一键升级。

> 个人项目，持续更新中。只支持 Apple 芯片、macOS 14 及以上。Kitty Clear 是独立的界面，不是 Mole 的官方应用。

## 功能

### 📊 状态

- 健康度评分、CPU、显卡、内存、磁盘、网速、电池，一屏看完，实时刷新
- 占用最高的进程列表，点开看详情，可以直接结束进程

### 🧹 清理

- 先扫描、出预览：缓存、日志、开发工具的缓存、浏览器数据……按类别列出，每一项都能取消勾选
- **保护名单**：列进去的路径以后每次都跳过，保护一个文件夹，里面的内容也一起保护
- 可选清理系统级的缓存（需要管理员密码）和外接磁盘
- **项目清理**：找出旧项目里的 `node_modules`、构建产物这类能重新生成的大文件夹

### 🗑️ 卸载

- 应用和它留下的偏好设置、缓存、支持文件一起移到废纸篓
- 系统目录里的残留（`/Library` 下的启动项、安装收据等）单独列出，默认不动，勾上才处理

### 💽 磁盘分析

- 色块图看哪里占地方，双击进入文件夹，右键移到废纸篓

### ⬆️ 软件更新

- Homebrew、App Store 和应用自带更新里的新版本集中在一处，挑着更新

### ⚡️ 登录项、安装包、优化

- **登录项**：开机或登录时自己启动的程序，能停用、启用、移除
- **安装包**：装完就用不上的磁盘映像、安装器和压缩包
- **优化**：重建索引、刷新缓存等维护任务，取消勾选的以后每次跳过；可以先预览

### 🤖 AI 工具

- 列出 Claude Code 和 Codex 很久没动过的会话，挑出来删掉（Codex 用它自己的 `codex delete`）

### 🕘 历史

- 清理和卸载实际动过的东西，每一次都有记录

### 🐱 菜单栏

- 图标旁边显示 CPU、内存或网速（可选），读系统计数器，不另外启动进程
- 点开看 CPU、显卡、内存、磁盘、网速、电池、占用最高的进程，还有摄像头和麦克风有没有在用
- 图标有彩色和单色剪影两种；可以开「仅菜单栏模式」，关掉窗口后不占程序坞

### 🔋 电池养护、隐私提醒

- **电池养护**：把充电上限控制在 80% 上下，减缓电池老化（第一次打开要管理员密码装一个小助手）
- **隐私提醒**：摄像头或麦克风一开始被使用就发通知，写上是哪个应用

## 安装

1. 从 [Releases](https://github.com/YyAdnBug/kitty-clear/releases/latest) 下载 `Kitty.Clear_x.y.z_arm64.dmg`（`_arm64.zip` 是 App 内升级用的，不用手动下载）。
2. 把 `Kitty Clear.app` 拖进「应用程序」。
3. App 使用 Apple Development 签名、没有公证，第一次打开会被系统拦下：到「系统设置 › 隐私与安全」里点「仍要打开」。也可以在终端执行：
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Kitty Clear.app"
   ```
4. 建议在 设置 › 通用 里给「完全磁盘访问权限」，这样扫描和清理才进得去邮件、Safari 和各应用容器这些受保护的文件夹。

只有第一次安装要放行。之后的新版本到 **设置 › 关于** 点「升级到 x.y.z」：自动下载、核对签名、替换并重新打开，权限和设置都保留，不用再放行。清理引擎 Mole 也能在 设置 › 清理 里单独升级，新引擎通过兼容性检查后才会启用。

## 从源码构建

需要 Xcode 命令行工具（Swift 5.10 及以上）和 Apple 芯片的 Mac，没有第三方 Swift 依赖。

```bash
git clone https://github.com/YyAdnBug/kitty-clear.git
cd kitty-clear
./build-app.sh --check     # 构建 build/Kitty Clear.app，并跑自检
./build-dmg.sh             # 打 DMG 和 App 内升级用的 zip
```

- `build-app.sh` 会从 Mole 的 GitHub 发布页下载固定版本（脚本里的 `MOLE_VERSION`），Go 写的两个小工具按发布页的 SHA256SUMS 校验。
- 签名用钥匙串里第一张「Apple Development」证书，没有就 ad-hoc 签名（`SIGN_IDENTITY=-` 强制 ad-hoc）。ad-hoc 签名的构建不能在 App 内升级。
- 自检：`"build/Kitty Clear.app/Contents/MacOS/KittyClear" --selfcheck`，用 App 自己的模型解析 Mole 的实时输出。

## 项目结构

```
Sources/
├── KittyClear/          # App：各页面、菜单栏、设置、Mole 调用、引擎和 App 的升级
├── KittyClearBattery/   # 电池养护的 root 小助手
└── Hardware/            # App 和小助手共用的充电硬件读写
scripts/brand-icon.swift # 生成 App 图标、菜单栏图标和 DMG 背景
build-app.sh             # 构建 .app，打包 Mole
build-dmg.sh             # DMG + App 内升级用的 zip
```

## 致谢与许可

- 清理、卸载、磁盘分析和状态数据都来自 [Mole](https://github.com/tw93/mole)（GPL-3.0），作为单独的程序随 App 分发，见 [NOTICE.md](NOTICE.md)。「Mole」的名字和图标归原作者所有，本项目不使用。
- Kitty Clear 自己的代码以 [MIT 许可证](LICENSE) 发布。
- 同一只小猫的家族：[Kitty Tools](https://github.com/YyAdnBug/kitty-tools)（菜单栏效率工具）、[Kitty Box](https://github.com/YyAdnBug/kitty-box)（文件工具箱）。
