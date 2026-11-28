# ksu-bgfreeze

KernelSU 黑名单后台冻结模块。人类总览：`README.md`。  
**文档结构**：根目录本文件 = 短路由表；细节按需加载嵌套 `AGENTS.md` / `docs/` / Skills（勿把本文件写成百科）。

## Identity

| 项 | 值 |
|----|-----|
| 模块 `id` | `ksu-bgfreeze`（`module/module.prop` ≡ `module.yaml`，上架后**不可改**） |
| 发版仓 | https://github.com/q2333gh/ksu-bgfreeze （`main`；Actions 为准） |
| Origin | 开发推送处；无 `gh` → **`daily_env1`** 同步 GitHub（已有 token，勿向用户要） |
| 当前号段 | 以 `module/module.prop` 为准（发版后 GH Release `ksu-bgfreeze-<code>-v*`） |

## Map（先读再改）

| 区域 | 先读 |
|------|------|
| **核心原理（人读）** | `docs/CORE_PRINCIPLES.md` |
| **完整墓碑可行性** | `docs/FULL_TOMBSTONE_FEASIBILITY.md`（Binder+cgroup） |
| **虚拟机测环境** | `docs/VM_TEST_ENV.md`（AVD/redroid；避 OP12 破坏性测） |
| Rust daemon | `daemon/AGENTS.md` → `daemon/src/` |
| 模块 / WebUI / shell | `module/AGENTS.md` |
| 发版一页纸 | `docs/workflows/ship.md` |
| 发版 runbook | skill `release` → `.cursor/skills/release/SKILL.md` |
| 墓碑/冻结期望状态 | `docs/TOMBSTONE_PLAN.md`（权威状态机 + 实机结论） |
| 系统编程硬边界 | `docs/SYSTEMS_PROGRAMMING_REVIEW.md` |
| Big-O / 业界 | `docs/BIG_O_ANALYSIS.md` · `docs/INDUSTRY_COMPARE.md` |
| 云朵台账 | `docs/CLOUD_RELEASE.md` |
| OP12 事故 | `docs/INCIDENT_2026-11-28_OP12_SOFTLOCK.md` |

## Commands

```bash
# 发版（唯一推荐入口）
bash scripts/bump-version.sh --patch    # 或 bump-version.sh X.Y.Z CODE
# 编辑 CHANGELOG.md 该版本条目
bash scripts/ship.sh -m "Release vX.Y.Z (versionCode N)"
# Origin → daily_env1 同步 GitHub main → 等 Actions

# 仅本地
bash scripts/build-daemon.sh
bash scripts/pack.sh
bash scripts/hot-update.sh              # 打印机内完整 zip 热更步骤
```

**固定 CI 链**：`Precheck` 绿 → `Auto Tag`（`workflow_run`；轻量 `v*` + `gh workflow run Release.yml`）→ `Release`（Auto Tag **等待**其成功）。  
绕过 Precheck 打 tag / annotated tag / 手搓 release = 禁止。

## Boundaries（常驻）

1. **改完必闭环**：升 `version`/`versionCode` + `CHANGELOG` → `ship.sh`（或等价 commit）→ push Origin → 同步 GitHub `main` → Precheck / Auto Tag / Release 全绿。例外：用户禁止提交/发版；纯问答；**仅文档且未要求发版可不升号**。
2. **immutable only**：禁手搓残缺 release、禁 `git tag -f`、禁复用 `versionCode`/tag；失败只能升号。→ skill `release`。
3. **特权路径安全**：fail-fast + 熔断；`flock`；只动黑名单 uid≥10000；PID 用前复核 uid / cgroup-uid；Binder 超时配额；热路径 Θ(T) 一拍；**WebUI/apps.sh 禁止 `/proc` 全表扫描**。→ `docs/SYSTEMS_PROGRAMMING_REVIEW.md` · `module/AGENTS.md`。
4. **黑名单-only**；默认 `mode=stop`；`disable` 须 `allow-disable`。
5. **机内热更**：完整 Release zip + `apps.sh hot-update`；`status` → `aligned=1`。禁只拷脚本/webroot。
6. **生成物**：`daemon/target/` 不当源；`dist/*.zip` 可提交作产物，≠ 已发版。

## Workers / 靶机

| 通道 | 用途 | 状态（2026-11-28 已验） |
|------|------|-------------------------|
| **PC Y9 `pc_y9win11mcp`** | Android 16 AVD 宿主；L1/L2 探针与 daemon 试验 | ✅ `bgfreeze-a16`；`adb root`；**snapshot**：`clean-pre-ksu` / `with-apis-and-module`；KSU-Next LKM 因 ENDBR panic 未上（已恢复 stock ramdisk）；模块文件可解压到 `/data/adb/modules/` 跑 `selfcheck`。详见 `docs/VM_TEST_ENV.md` §8–9 |
| **OP12 `phone_op12_termux`** | 发版后冒烟 / ColorOS 路径 | 仅已绿包；**禁止**破坏性双冻实验（默认） |
| **daily_env1** | Origin→GitHub 同步 | 非 Android 靶机 |

**AVD 遥控（MCP → PC）要点**：

```text
SDK = %LOCALAPPDATA%\Android\Sdk
AVD = bgfreeze-a16
scripts = C:\Users\12531\bgfreeze-avd\   # start-emu.ps1 / setup 日志
adb = %LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe
起模拟器：powershell -File C:\Users\12531\bgfreeze-avd\start-emu.ps1
控机：adb -s emulator-5554 shell …   （MCP 长命令易掉线 → 后台脚本 + 短轮询）
下载 SDK 包：用 curl.exe，勿用 Invoke-WebRequest（本机 TLS 易挂）
```

## Habits

- 功能改动：Rust → `daemon/` → `module/bin/bgfreeze`；胶水/WebUI → `module/`。
- 进目录先读该目录 `AGENTS.md`（叶子只写 delta）。
- 改发版流程：同步 `docs/workflows/ship.md` + skill `release` + 必要时 `docs/CLOUD_RELEASE.md`。
- **优先 AVD** 做 cgroup/Binder 试验；OP12：`phone_op12_termux` 只冒烟；日志 `/data/local/tmp/ksu-bgfreeze.log`；空黑名单应 idle。
