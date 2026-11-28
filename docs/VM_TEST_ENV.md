# 虚拟机 / 模拟器测试环境（避真机翻车）

> 目的：完整墓碑（cgroup + `BINDER_FREEZE`）与 daemon 逻辑先在**可丢弃环境**验证，OP12 只做「已绿」的热更新冒烟。  
> 调研日：2026-11-28（台北）。本机（OP12）默认**禁止**破坏性探针。

## 1. 我们要测什么（分层）

| 层 | 内容 | 是否需要 KernelSU |
|----|------|-------------------|
| **L1 驱动能力** | `cgroup.freeze` 可写、`BINDER_FREEZE` / `GET_FROZEN_INFO` ioctl | **否**（`adb root` 即可） |
| **L2 daemon 逻辑** | 双冻顺序、门闩、超时/`EAGAIN`、日志 | 否（root 直接跑 `bgfreeze` 二进制也行） |
| **L3 模块形态** | KernelSU 模块安装、WebUI、`apps.sh` 热更新 | **是**（或 Magisk 等效；AVD 默认没有） |
| **L4 OEM 真实** | ColorOS Hans / 路径 `apps/uid_*` | 只能真机（OP12） |

**结论**：Android 16 虚拟环境**完全够用**做 L1/L2；L3 可选；L4 仍用真机、且只跑已过 VM 的包。

## 2. 可选方案对比

| 方案 | Android 16 | root | 适合本仓 | 落点 | 备注 |
|------|------------|------|----------|------|------|
| **Android Emulator AVD**（官方） | ✅ API 36「Baklava」 | ✅ 选 **Google APIs** 或 **AOSP**（**不要** Google Play） | **首选 L1/L2** | 你的 **Win11 PC（Y9）** | 文档：[Get Android 16](https://developer.android.com/about/versions/16/get) |
| **redroid**（Docker） | ✅ `redroid/redroid:16.0.0-latest` | 容器内 root | L1/L2（Linux） | Linux 主机 / WSL2+内核模块 | 需 `binder_linux`；多容器时 Binder freeze 有 PID 命名空间坑 |
| **Waydroid** | 社区有 16 镜像（实验） | 视镜像 | 次选 | 仅 Linux | 历史 cgroup 挂载问题多，不如 AVD 稳 |
| **Cursor 云端 agent VM** | ❌ 不指望开完整 AVD | N/A | 编文档 / 编译 / 同步 GitHub | `daily_env1` 等 | 无稳定嵌套 KVM；**不当 Android 靶机** |
| **OP12 真机** | ColorOS（非纯 A16） | KernelSU | **仅 L4 冒烟** | `phone_op12_termux` | 默认只读日志 + 已知安全热更 |

## 3. 推荐落地：PC 上 Android 16 AVD（你配权限）

宿主：**Y9 Win11**（本会话 MCP：`pc_y9win11mcp`）。  
探针（2026-11-28）：**i9-12900H / ~32 GB RAM** — 跑 AVD 足够；已有 **adb 37**（WinGet Platform-Tools）；**尚无** `%LOCALAPPDATA%\Android\Sdk`；**无 Docker** → 不做 redroid，走官方 Emulator。

### 你需要准备（一次）

1. 开虚拟化：BIOS VT-x + Windows **Hyper-V / WHPX**（或 Android Emulator Hypervisor）  
2. 装 **Android Studio**（或 cmdline-tools）+ **Android Emulator**（补上目前缺失的 Sdk）  
3. 系统镜像：`system-images;android-36;google_apis;x86_64`（本机是 Intel）  
   - **Google APIs** = userdebug，可 `adb root`  
   - **Google Play** = 不可 root，**别选**  
4. 建 AVD（如 Pixel 9 + API 36 Google APIs）  
5. 启动后给我通：本机 `adb devices` 见 `emulator-…`，MCP/`start.ps1` 保持在线  
6. 管理员权限：装 Studio/SDK 时用；日常测用普通用户 + 已装好的 adb 即可

### 我侧会做的（获 adb 后）

```text
adb root
adb shell 'ls /sys/fs/cgroup/*/cgroup.freeze 2>/dev/null | head'
adb shell  →  跑 BINDER_FREEZE 探针（同 OP12 那套）
必要时 push 预编译 bgfreeze，仅在模拟器内 freeze/thaw
```

**不会**在未确认的真机上开双冻门闩或乱写 cgroup。

### 启动提示（本机）

```powershell
# 可写 system（装探测工具时）
emulator -avd <AVD名> -writable-system -no-snapshot-load
adb wait-for-device
adb root
adb remount   # 若失败：avbctl disable-verification → reboot → 再 root/remount
```

## 4. 次选：Linux redroid（若 PC 上 Docker/WSL 成熟）

```bash
# 主机需 binder
modprobe binder_linux devices="binder,hwbinder,vndbinder"
docker run -itd --rm --privileged -p 5555:5555 \
  redroid/redroid:16.0.0-latest androidboot.redroid_gpu_mode=guest
adb connect 127.0.0.1:5555
```

- 镜像存在官方 16。  
- Win11 上更折腾（WSL2 内核模块 / 嵌套虚拟化）；**优先 AVD**。  
- 已知：多实例时 `BINDER_FREEZE` 可能串 PID（[redroid#901](https://github.com/remote-android/redroid-doc/issues/901)）→ 单容器测。

## 5. 云端 / Worker 怎么用

| 资源 | 角色 |
|------|------|
| **本 Cloud Agent** | 写代码、文档、Origin push；**不**跑 Android 16 GUI |
| **daily_env1** | GitHub 同步 / CI 辅助；**不**当模拟器宿主 |
| **PC Y9 (`pc_y9win11mcp`)** | **主靶机宿主**：起 AVD、给我 `adb`/`run_command` |
| **OP12 (`phone_op12_termux`)** | 发布后冒烟；破坏性测试默认拒绝 |

你说「配好读写权限」：对 AVD 指 `adb root` +（按需）`-writable-system`；对 MCP 指 FRP 常开 + 必要时 admin 装 SDK。

## 6. 与完整墓碑计划的衔接

见 [`FULL_TOMBSTONE_FEASIBILITY.md`](FULL_TOMBSTONE_FEASIBILITY.md)：

1. **先**在 AVD 上验证 L1（ioctl + cgroup）→ 再写 Phase 1 代码  
2. Phase 1 门闩默认关；VM 上把门闩打开压测  
3. OP12 只装已过 VM 的版本做打开/关闭应用宝冒烟  

## 7. 你回我一句即可开工

准备好后回复例如：

> AVD 已起，`adb devices` 有 emulator-5554，MCP 在线。

我就不会再拿 OP12 做 binder 双冻实验。
