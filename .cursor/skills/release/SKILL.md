---
name: release
description: >-
  Ship an immutable KernelSU module release for ksu-bgfreeze: bump
  version/versionCode, CHANGELOG, push main, wait for Auto Tag + Release.
  Use when releasing, tagging, publishing a module zip, fixing a failed
  Release workflow, or when AGENTS says to follow the release runbook.
---

# Release（immutable）

## When to use

- 有可交付代码/配置改动要上 GitHub Release / 云朵
- Auto Tag 或 Release workflow 红了要重发
- 用户明确要求发版

不要用：纯问答；用户禁止推送/发版；仅文档且未要求发版（可不升号）。

## Preconditions

- 发版以 **GitHub** `q2333gh/ksu-bgfreeze` 为准（Origin 无 `gh` → `daily_env1`）
- 仓库已开 Release immutability
- 最新已发布 `versionCode`：`gh release list -R q2333gh/ksu-bgfreeze --limit 5`（看 asset `ksu-bgfreeze-N-…`）
- 新 `version`/`versionCode`/`tag` 必须从未用过；`versionCode` 严格更大

Action pin（勿随意升级）：

`KernelSU-Modules/tools/actions/module-release@424471eacf6c0bd00e8e3708980f6b1882b5bf33`

## Steps

1. Edit `module/module.prop`：`version=vX.Y.Z`，`versionCode=N`（N > 最新已发布）。
2. Prepend section to `CHANGELOG.md`：`## vX.Y.Z` + bullets。
3. If daemon changed：`bash scripts/build-daemon.sh`；then `bash scripts/pack.sh`。
4. Commit + push Origin `main`；sync same tip to GitHub `main`（`daily_env1` if needed）。
5. Watch Actions：
   - **Precheck** green
   - **Auto Tag** 打 **lightweight** `v*`（勿 annotated），再 `gh workflow run Release.yml --ref tag`（`GITHUB_TOKEN` 推 tag 不会连锁；annotated + 改 workflows 的 commit 会导致 Release `POST /releases` 403）
   - **Release** green → asset `ksu-bgfreeze-N-vX.Y.Z.zip`
   - Auto Tag skip（versionCode 未升高）≠ 已发版
   - Workflow 文件名是 **`Release.yml`**（大小写敏感）
6. Verify：

```bash
gh release view vX.Y.Z -R q2333gh/ksu-bgfreeze --json isImmutable,tagName,assets,url
```

Expect `isImmutable: true` and exactly one module zip.

7. OP12 / 机内热更（若要立刻验证）：下载 Release zip →  
   `sh …/apps.sh hot-update <zip>` → `apps.sh status` 期望 `aligned=1`。  
   **禁止**只 `cp apps.sh` / `webroot`。见 `scripts/hot-update.sh`、`module/AGENTS.md`。

## Failure

| 现象 | 处理 |
|------|------|
| `version-not-newer` | 再升 `versionCode` + 新 `version`，push |
| Auto Tag skip | prop 未高于已发布号段 |
| Release 红 / tag 已推 | **禁止** `tag -f`；升号 + 新 tag（经 Auto Tag） |
| 仅 Origin 有提交 | 先同步 GitHub `main` |
| Precheck 红 | 修 prop/yaml/`pack.sh`/Rust 构建 |

## Do not

- 手搓 `gh release create` / 手动 upload 到已 published immutable release
- `git tag -f` 或复用失败过的 `versionCode`
- 在 PR/`main` 对已发布号段跑 `module-release` dry-run 当门禁
- 改已上架 `id`；把 zip 传到 modules.kernelsu.org
- 重复 Portal「提交审核」（人审期间只修 Check Run 或升号）

台账背景：`docs/CLOUD_RELEASE.md`。手动 dry-run：Actions → Release → `dry_run`（不能代替正式发版）。
