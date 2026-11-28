# ksu-bgfreeze

KernelSU 黑名单后台冻结模块。人类总览：`README.md`。

## Identity

| 项 | 值 |
|----|-----|
| 模块 `id` | `ksu-bgfreeze`（`module/module.prop` ≡ `module.yaml`，上架后**不可改**） |
| 发版仓 | https://github.com/q2333gh/ksu-bgfreeze （`main`；Actions 以此为准） |
| Origin 镜像 | 无 `gh` 时用 **`daily_env1`** 同步 GitHub（已有 token，勿向用户要） |

## Map（先读再改）

| 区域 | 先读 |
|------|------|
| Rust daemon | `daemon/AGENTS.md` → 源码 `daemon/src/` |
| 模块 / WebUI / shell | `module/AGENTS.md` |
| 系统编程硬边界（长文） | `docs/SYSTEMS_PROGRAMMING_REVIEW.md` |
| Big-O / 业界对照 | `docs/BIG_O_ANALYSIS.md` · `docs/INDUSTRY_COMPARE.md` |
| 发版 runbook | skill `release` → `.cursor/skills/release/SKILL.md` |
| 云朵台账 | `docs/CLOUD_RELEASE.md` |
| OP12 事故 | `docs/INCIDENT_2026-11-28_OP12_SOFTLOCK.md` |

## Commands

```bash
bash scripts/build-daemon.sh    # 需 ANDROID_NDK_HOME 或 aarch64 musl
bash scripts/pack.sh            # → dist/；不发版
bash scripts/hot-update.sh      # 打印安全热更步骤（完整 zip → apps.sh hot-update）
```

CI（GitHub）：`Precheck` → `Auto Tag`（升号 → lightweight `v*` → `gh workflow run Release.yml`）→ `Release`。  
注：`GITHUB_TOKEN` 推 tag 不连锁；须显式 dispatch；用轻量 tag（annotated 易 403）。

## Boundaries（常驻）

1. **改完必闭环**：升 `version`/`versionCode` + `CHANGELOG` → commit → push Origin → 同步 GitHub `main` → 盯 Precheck / Auto Tag / Release 全绿。例外：用户说不要提交/发版；纯问答；仅文档且未要求发版可不升号。
2. **immutable only**：禁止手搓残缺 release、禁止 `git tag -f`、禁止复用 `versionCode`/tag；失败只能升号重发。细节 → skill `release`。
3. **特权 daemon / shell 安全**（改 `daemon/` / `module/bin/` / WebUI 胶水前必守）：fail-fast + 熔断；`flock` 单实例；只动黑名单 app uid≥10000；PID 用前复核 uid（或 cgroup-uid）；Binder 有超时/配额；热路径 Θ(T) 一拍快照；**WebUI 路径禁止 `/proc` 全表扫描**。细则 → `docs/SYSTEMS_PROGRAMMING_REVIEW.md` · `module/AGENTS.md`。
4. **黑名单-only**；`mode=disable` 须先有 `allow-disable`；默认 `mode=stop`。
5. **机内热更**：只用完整 zip + `apps.sh hot-update`（拒绝缺 `bgfreeze` 的半包）；`status` 须 `aligned=1`。禁止只推脚本。
6. **不改生成物当作源**：`daemon/target/`；`dist/*.zip` 仅作产物提交，勿当已发版。

## Habits

- 功能：Rust → `daemon/` → 产物 `module/bin/bgfreeze`；胶水/WebUI → `module/`。
- 触达某目录时读该目录 `AGENTS.md`（叶子只写 delta，不重复本文件）。
- 发版/上架流程变更：同步 skill `release` 与 `docs/CLOUD_RELEASE.md`。
