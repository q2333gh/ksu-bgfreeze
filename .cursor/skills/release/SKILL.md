---
name: release
description: >-
  Ship an immutable KernelSU module release for ksu-bgfreeze: bump
  version/versionCode, CHANGELOG, push main, wait for Auto Tag + Release.
  Use when releasing, tagging, publishing a module zip, fixing a failed
  Release workflow, or when AGENTS says to follow the release runbook.
---

# Release（immutable）— 固定一键链

## When to use

- 有可交付代码/配置改动要上 GitHub Release / 云朵
- Auto Tag 或 Release workflow 红了要重发
- 用户明确要求发版

不要用：纯问答；用户禁止推送/发版；仅文档且未要求发版（可不升号）。

## Preconditions

- 发版以 **GitHub** `q2333gh/ksu-bgfreeze` 为准（Origin 无 `gh` → `daily_env1`）
- 仓库已开 Release immutability
- 新 `version`/`versionCode`/`tag` 从未用过；`versionCode` 严格更大

Action pin（勿随意升级）：

`KernelSU-Modules/tools/actions/module-release@424471eacf6c0bd00e8e3708980f6b1882b5bf33`

## One command（本地）

```bash
bash scripts/bump-version.sh --patch   # 或 bump-version.sh X.Y.Z CODE
# 编辑 CHANGELOG.md 条目
bash scripts/ship.sh -m "Release vX.Y.Z (versionCode N)"
```

`ship.sh`：对齐 Cargo 版本 → build → pack → commit → push Origin `main`。

然后：

1. **同步 GitHub `main`**（本环境无 `gh` 时用 **daily_env1**）
2. 云端固定链（已写进 workflow，勿手搓 tag）：
   - **Precheck** 绿
   - **Auto Tag**（`workflow_run` 接 Precheck）打 **lightweight** `v*` → `gh workflow run Release.yml --ref tag`
   - **Release** 绿 → `ksu-bgfreeze-N-vX.Y.Z.zip`（immutable）
   - Auto Tag **会等待** Release；Release 红则 Auto Tag 红
3. Verify：

```bash
gh release view vX.Y.Z -R q2333gh/ksu-bgfreeze --json isImmutable,tagName,assets,url
```

4. 机内热更：`apps.sh hot-update <zip>` → `status` 期望 `aligned=1`（见 `scripts/hot-update.sh`）

摘要图 / Agent 检查清单：`docs/workflows/ship.md`。  
根路由：`AGENTS.md`；机内热更：`module/AGENTS.md`。

## Failure

| 现象 | 处理 |
|------|------|
| `version-not-newer` / Auto Tag skip | 再升 `versionCode` + 新 `version`，`ship.sh` |
| Release 红 / tag 已推 | **禁止** `tag -f`；升号重发 |
| 仅 Origin 有提交 | 先 daily_env1 同步 GitHub `main` |
| Precheck 红 | 修构建；Auto Tag 不会跑 |
| Auto Tag 超时等 Release | 看 Release 日志；升号或修 Release.yml |

## Do not

- 手搓 `gh release create` / 手动 upload 到已 published immutable release
- `git tag -f` 或复用失败过的 `versionCode`
- 绕过 Precheck 直接打 tag
- 改已上架 `id`；把 zip 传到 modules.kernelsu.org
- 重复 Portal「提交审核」

台账：`docs/CLOUD_RELEASE.md`。
