# 魔力宝贝 macOS 原生启动器

面向这台 Mac 上的易玩通魔力宝贝怀旧服安装。SwiftUI 界面和 Swift 认证协议直接使用官方计费服务，游戏继续在已有 CrossOver 的 `CrossGate` 容器运行。

## 使用

打开 `dist/魔力宝贝启动器.app`，选择大区，输入易玩通通行证 PID 和密码，点击“验证官方账号”。官方返回游戏账号列表后，选择账号并点击“启动游戏”。游戏端继续选择服务器、角色。

- 支持本地官方配置中的牧羊双子、金牛两个怀旧大区。
- 密码只用于当次请求，验证完成后清空输入框；没有账号密码持久化、网络包日志或自动重试密码。
- 不需要先退出已经运行的官方启动器。已登录游戏账号若再次登录，行为由官方游戏服务决定。
- 游戏更新仍使用官方启动器。原生启动器读取现有素材版本，遇到重复版本会停止启动并提示更新。
- 认证结果只留在进程内存里，启动后释放；本地会话最长允许五分钟内交接，超时需重新验证。

当前自动识别安装位置：

```text
/Applications/CrossOver.app
~/Library/Application Support/CrossOver/Bottles/CrossGate
  drive_c/Program Files (x86)/易玩通/“易玩通”娱乐平台/POLCN_Launcher.exe
  drive_c/Program Files (x86)/PlayOnline/魔力宝贝/cg_se_3000.exe
```

这是针对现有安装的个人开发版本，尚未实现其他容器/安装目录的选择界面。

## 构建与验证

需要 macOS 13 或更新版本、Swift 工具链、MinGW-w64。当前开发机使用 Apple Silicon、Command Line Tools 和 CrossOver 26.2.0。

```sh
brew install mingw-w64
zsh scripts/build.sh
zsh scripts/test.sh
python3 scripts/test_bridge.py
'dist/魔力宝贝启动器.app/Contents/MacOS/CGLauncher' --diagnose
'dist/魔力宝贝启动器.app/Contents/MacOS/CGLauncher' --probe
```

构建脚本生成本机架构的原生程序、两个自有的 32 位 Windows 小程序，并做本地 ad-hoc 签名。没有 Apple 公证或开发者发行签名，也不包含官方游戏/启动器二进制或素材。

更新正在运行的程序时，先构建到其他目录，退出原生启动器后替换应用包，避免覆盖正在执行的文件：

```sh
zsh scripts/build.sh 'work/staged/魔力宝贝启动器.app'
```

`scripts/test.sh` 可在仅安装 Command Line Tools 的环境执行同一组协议检查；完整 Xcode 环境也可使用 `swift test`。桥接测试只使用专属测试共享内存和合成数据，不操作真实认证票据或启动真实游戏。`--probe` 仅执行无账号的握手与加密心跳，不登录账号。

## 已验证范围（2026-09-14）

- 原生应用构建、签名和界面运行成功。
- 读取官方 XML 的两个大区成功；28 项素材参数已逐项与正在运行的官方游戏匹配。
- 两个大区的真实服务器均通过原生 Swift DH/Blowfish 加密心跳测试。
- 用户在本地原生界面输入官方账号后，牧羊双子认证成功并返回可进入的游戏账号。
- Windows 子进程读取共享内存、中文路径、stdin 交接测试通过。
- 修复子进程中文运行环境后，用户确认已完全成功，官方认证、启动与实际进入游戏全部通过。
- 24 项协议和素材检查通过，包括资料片后缀和令牌 NUL 结束符处理。
- 桥接测试额外验证 ACP 936，以及中文目录中的子进程通过 ANSI 接口重新打开自身程序文件。

详细实现和证据边界见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

已验证版本保存在 Git 标签 `v0.1.0-verified` 及 `releases/0.1.0-verified/`，包含原始应用包和源码归档。
