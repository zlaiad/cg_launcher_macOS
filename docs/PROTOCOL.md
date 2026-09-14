# 本地互操作分析记录

## 边界与来源

分析对象为用户已安装的 `POLCN_Launcher.exe`、`cg_se_3000.exe` 和官方 XML 配置。只在用户这台机器实现官方账号正常登录与游戏启动，不修改官方程序，不伪造服务端认证结果。官方二进制副本、反汇编中间文件与工具保留在被 Git 忽略的 `work/`，不会放入应用包。

本地原始文件 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| POLCN_Launcher.exe | `109b13382e7fbd96759f52e8cdb4bc269c379a613dbbf1ddd04a69a4a5c8ef0e` |
| cg_se_3000.exe | `9baa0d2660f96c6699ccf42ad46bd918717b98ccb228f4edde2d92afb89d3126` |

官方启动器使用 UPX 压缩。解压副本经 PE 导入/字符串交叉引用和 Ghidra 静态分析得到下述路径，再用无凭据心跳与本地用户真实登录验证。

## 连接路径

`RegionList.xml` 为 GB18030 编码，怀旧服 game code 为 11。当前加载的计费地址为：

| 大区 | 地址 |
| --- | --- |
| 33 牧羊双子 | 221.122.108.12:9030 |
| 36 金牛 | 221.122.119.158:9030 |

本机观测到：macOS 直接连接牧羊双子可以完成 TCP connect，但等待应用握手超时；同机同一时间通过 CrossOver WinSock 收到正常响应。直接连接金牛成功。尚未证明网络路由或加速器的具体原因。

应用因此采用 `Swift → 匿名管道 → cg_network.exe → WinSock → 官方服务`。协议序列化、DH 与加解密仍在 Swift 中，网络小程序仅转发字节，没有登录界面或认证实现。它只接受上表计费地址和 9030 端口。应用不再启动一个官方登录器来代替原生认证。

## 认证协议

这是旧版 VCE TCP 协议，并非 HTTPS。实现严格匹配现有客户端以实现互操作；不能将其等同于现代 TLS 的服务器身份认证。

1. 客户端发送两个大端 UInt32：加密方式 1、密钥长度 8。
2. 服务端返回大端状态 0，以及各带 UInt32 长度的 ASCII 十六进制 DH generator、prime、public key。
3. 客户端核对已验证的 1024 位模数和 generator 2，使用系统安全随机数生成私钥，发送客户端公钥。
4. DH 共享秘密按原客户端 BN 十六进制格式解释，前八个字节成为 Blowfish 密钥。
5. 加密记录头为大端 UInt32 密文长度、原文长度。记录内为大端 UInt16 消息长度加消息。原客户端 Blowfish 的每个 32 位字采用小端表示；调用 CommonCrypto ECB 前后均交换字节。补零长度始终到下一个 8 字节边界。
6. 登录消息为 opcode 10、UInt32 sequence、长度前缀 PID、长度前缀密码、UInt32 game code 11。界面不会自动重复发送密码请求。
7. 成功响应 opcode 11，包含 sequence、状态、token、游戏账号字符串数组、五组对应整数数组及两个尾部整数。字段和数组长度均检查上限，未知结构停止启动。

主要静态分析位置：登录序列化 `0x46d810`，响应解析 `0x46d040`，成功回调 `0x4133a0`，启动/交接 `0x407a00`，DH 握手 `0x482a90`，共享秘密取密钥 `0x482fc0`，记录接收 `0x471c60`、发送 `0x472e70`。位置针对本地解压副本，后续官方升级可能失效。

## 交接给游戏

原启动器建立 256 字节命名共享内存 `CGSharedMem`，写入带 NUL 终止的字段：

```text
gid:<官方返回的游戏账号> glt:<官方返回的令牌>:<处理后的服务器整数> 
```

令牌字段与官方回调的 C 字符串行为一致：只采用第一个 NUL 结束符之前的内容。末尾整数按 UInt32 加 `0x80000000` 后取模，再转小写 32 进制，与原程序的 32 位字段及 `__ui64toa` 调用一致。共享内存由自有 `cg_bridge.exe` 建立，再调用 `CreateProcessW` 启动原版游戏。桥接进程随游戏存活以保持映射。

交接数据从 macOS 通过匿名 stdin 管道传入，票据不出现在进程参数、配置、调试输出或文件里。游戏参数来自官方大区 IP 列表及本地素材文件版本；当前不实现官方自动更新下载协议。

### LP5 与中文运行环境

首次真实游戏创建后出现 `Error while unpacking program, code LP5`。同一容器中，默认命令行启动的诊断程序报告 ACP 1252：`GetFileAttributesW` 可以访问中文游戏路径，而转换到 ANSI 后存在字符丢失、`GetFileAttributesA` 失败。设置子进程 `LANG=zh_CN.UTF-8`、`LC_ALL=zh_CN.UTF-8` 后 ACP 为 936，转换无丢失，两个文件接口均成功。

Windows 短路径在此环境并不足以解决问题：Wine 创建子进程后可能恢复完整 Unicode 模块路径，因此中文目录的子进程自读测试仍失败。最终采用简体中文进程环境，并在建立游戏共享内存之前验证路径可以通过当前 ANSI 接口访问。桥接测试在中文测试目录复制自有小程序，确认子进程的 `GetModuleFileNameA` 和 `GetFileAttributesA` 正常；没有修改或解包原版游戏可执行文件。

## 验证层次

协议检查包含独立 Python 模幂期望值、独立 PyCryptodome Blowfish 期望值、长度/截断检查及账号限制。Wine 桥接检查跨进程读共享内存、带空格与中文的路径、stdin 二进制封包，使用合成身份字段。

真实官方计费握手、加密心跳与用户本地实际账号认证已经成功。修复资料片后缀、令牌结束符及中文运行环境后，用户于 2026-09-14 明确确认“已经完全成功了”。该完整验证版本保存为 `v0.1.0-verified`。

参考：微软 [Named Shared Memory](https://learn.microsoft.com/en-us/windows/win32/memory/creating-named-shared-memory)，CodeWeavers [Run a Windows app from Terminal](https://support.codeweavers.com/run-a-windows-app-from-terminal)。
