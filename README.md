# ksu-bgfreeze

纯 **KernelSU** 模块：只对黑名单里的应用做退后台冻结；名单外零干预。

## 安装

1. 刷入 Release 里的 zip：  
   https://github.com/q2333gh/ksu-bgfreeze/releases/latest
2. 重启
3. KernelSU → 本模块 → **WebUI** → 勾选应用 → **应用**

## 行为

WebUI 可选两种冻结模式：

| 模式 | 退后台约 3 秒后 | 再用时 |
|------|----------------|--------|
| **SIGSTOP** | `kill -STOP` 暂停进程 | 回前台 `SIGCONT` |
| **Hail 停用** | `am force-stop` + 整包 `pm disable`（对齐 [Hail](https://github.com/aistra0528/Hail)） | WebUI「解冻」或「打开」（enable + 启动） |

停用模式下桌面图标可能消失，这是 PackageManager 整包 disable 的正常表现。  
黑名单空 = 空转。

配置：`/data/adb/ksu-bgfreeze/blacklist.txt` · 模式：`/data/adb/ksu-bgfreeze/mode`（`stop` / `disable`）  
日志：`/data/local/tmp/ksu-bgfreeze.log`

## 架构（v0.5+）

- **Rust daemon** `module/bin/bgfreeze`（静态 aarch64 musl）：每轮 **Θ(T)** 扫 `/proc` 一次建 `uid→pids`，黑名单 **Θ(N+P)**；`flock` 单实例；Hail disable fail-fast + circuit。
- Shell 仅 `service.sh` / `apps.sh`（WebUI）胶水。
- Big-O：[`docs/BIG_O_ANALYSIS.md`](docs/BIG_O_ANALYSIS.md)

```bash
./scripts/build-daemon.sh   # 需 aarch64-linux-musl 交叉链
./scripts/pack.sh
```

产出：`dist/ksu-bgfreeze-<version>.zip`

## 文档

- [AGENTS.md](AGENTS.md) — **给 Agent 的发版/操作手册**
- [docs/CLOUD_RELEASE.md](docs/CLOUD_RELEASE.md) — 云朵合规台账
- [docs/UX.md](docs/UX.md) — WebUI 交互
- [docs/FEASIBILITY.md](docs/FEASIBILITY.md) — 可行性说明
- [docs/PERF_LIST.md](docs/PERF_LIST.md) — WebUI 列表大 O / 秒开策略

## 发版（CI）

推 `v*` tag 即触发官方 `module-release` action，自动预检并以 immutable Release 发 zip：

```bash
# 先改 module/module.prop 的 version / versionCode，更新 CHANGELOG.md
git tag v0.3.2
git push origin v0.3.2
```

也可在 Actions 里手动跑 `Release`（可勾 dry-run）。`main`/PR 上会跑结构 `Precheck`（打包 + prop/yaml 一致性）。

本地只打包：`./scripts/pack.sh`

## 上架 KernelSU Modules（云朵）

流程复核见 [docs/CLOUD_RELEASE.md](docs/CLOUD_RELEASE.md)。当前：immutable + Check Run 通过，Portal **Pending review**。

- App：https://github.com/apps/kernelsu-modules/installations/new  
- 门户：https://developers.kernelsu.org/
