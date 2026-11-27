# AGENTS.md — ksu-bgfreeze

给自动化 Agent 的操作说明。人类可读总览见 `README.md`；云朵合规台账见 `docs/CLOUD_RELEASE.md`。

## 仓库身份

| 项 | 值 |
|----|-----|
| 模块 `id` | `ksu-bgfreeze`（`module/module.prop` 与根目录 `module.yaml` 必须一致，上架后**不可改**） |
| 公开发版仓库 | https://github.com/q2333gh/ksu-bgfreeze （`main`） |
| 云朵门户 | https://developers.kernelsu.org/ |
| 官方发版文档 | https://developers.kernelsu.org/docs/zh-CN/releasing |
| 官方上架文档 | https://developers.kernelsu.org/docs/zh-CN/getting-started |

本工作区若是 Origin 镜像，**发版与 Actions 以 GitHub 仓为准**。本机无 `gh` 凭证时，用已授权的 `daily_env1` 环境推送到 `q2333gh/ksu-bgfreeze`，不要假设当前 shell 能直接 `gh release` / `git push` GitHub。

## 硬约束（违反会浪费 versionCode / tag）

1. **只发 immutable Release**。仓库已开 Release immutability；资源一旦发布不可替换、不可删改 zip、tag 不可复用。
2. **正确顺序**：draft → 上传 zip → 发布。禁止先发布再补资源。一律走 CI 的 `module-release`，不要手搓残缺 release。
3. **每个 release 恰好 1 个模块 zip**。CI 会命名为 `{id}-{versionCode}-{version}.zip`。
4. **`versionCode` 必须严格递增**（正十进制 int32）。云朵记住历史最高值：删除 release 也不能回退号段。
5. **出错只能发更高 `versionCode` 的新 tag**，不能“修”已发布的 immutable release。
6. **不要**在 PR/`main` 上对已发布号段跑 `module-release` dry-run 当门禁——会对当前 `versionCode` 报 `version-not-newer`。结构门禁用 `.github/workflows/precheck.yml`。
7. **不要**改已上架的 `id`；不要把 zip 上传到 modules.kernelsu.org（云朵只索引 GitHub immutable release）。
8. **不要**新建 PR 来完成发版；发版是 push `main` + push `v*` tag。

## 目录与 CI

```
module/                 # ZIP 根内容（module.prop、service.sh、webroot/…）
module.yaml             # 云朵元数据；description → README.md
CHANGELOG.md            # Release notes（CI 读这个）
scripts/pack.sh         # 本地打包 → dist/；不发版
.github/workflows/
  release.yml           # push tags v* → 官方 module-release（pin SHA）
  precheck.yml          # main/PR：prop/yaml 一致 + pack.sh
docs/CLOUD_RELEASE.md   # 云朵流程合规台账（给人看）
```

`release.yml` 固定使用：

`KernelSU-Modules/tools/actions/module-release@424471eacf6c0bd00e8e3708980f6b1882b5bf33`

升级 action 时必须 pin **完整 commit SHA**，并先在 workflow_dispatch + `dry_run=true` 验证。

## 标准发版流程（Agent 按序执行）

适用：模块已在 Portal 提交过（首次需人审；通过后后续版本自动进云朵）。

### 0. 前置检查

- [ ] GitHub `main` 与要发的代码一致（Origin 有改动则先同步到 GitHub `main`）
- [ ] `gh release view v0.3.1 -R q2333gh/ksu-bgfreeze --json isImmutable,assets`（或 API）确认历史 immutable 仍健康
- [ ] 读最新已接受 `versionCode`（看最新成功 Check Run / 最新 immutable release 的 `module.prop`）
- [ ] 不创建 tag，直到 prop / CHANGELOG / main 都已推送

### 1. 改版本

编辑 `module/module.prop`：

- `version`：展示用，建议 `vX.Y.Z`，与即将打的 tag 一致
- `versionCode`：整数，**必须 > 云朵曾接受的最大值**（当前基线：`301` = `v0.3.1`）

### 2. 写更新日志

在 `CHANGELOG.md` **顶部**追加一节（CI 整文件作为 release notes）：

```markdown
## vX.Y.Z

- 用户可见的变更要点
```

### 3. 本地校验（可选但推荐）

```bash
bash scripts/pack.sh
# 确认 dist/ksu-bgfreeze-vX.Y.Z.zip 可解压且含 module.prop
```

### 4. 提交并推到 GitHub `main`

```bash
git add module/module.prop CHANGELOG.md
# 若还有功能改动一并加入
git commit -m "Release vX.Y.Z (versionCode N)"
git push origin main
```

若当前远程是 Origin：把同一 commit 推到 `https://github.com/q2333gh/ksu-bgfreeze` 的 `main`（常用 `daily_env1` + `gh`/`git`）。

等 GitHub Actions **Precheck** 变绿：  
https://github.com/q2333gh/ksu-bgfreeze/actions

### 5. 打 tag 触发正式发版

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

tag 必须在**已包含新 versionCode 的 commit**上。推送后看 **Release** workflow：

- 成功：出现 immutable release，asset 形如 `ksu-bgfreeze-N-vX.Y.Z.zip`
- 失败：不要复用该 tag；修代码后升 `versionCode`，用**新 tag**再发

### 6. 发版后复核

```bash
gh release view vX.Y.Z -R q2333gh/ksu-bgfreeze --json isImmutable,tagName,assets,url
gh api repos/q2333gh/ksu-bgfreeze/commits/vX.Y.Z/check-runs \
  --jq '.check_runs[]|{name,conclusion,title:.output.title}'
```

期望：

- `isImmutable: true`
- 恰好一个模块 zip
- Check Run `KernelSU Modules` → success（`vX.Y.Z (N) is valid`）
- 上架后数分钟内云朵自动同步（无需再审）

### 7. 禁止事项复查

- [ ] 没有手改已发布 release 的 asset
- [ ] 没有 `git tag -f` / 移动旧 tag
- [ ] 没有复用失败过的 `versionCode`
- [ ] 没有把仅本地 `dist/*.zip` 当成已发版

## 仅打包、不发版

```bash
./scripts/pack.sh
```

产出在 `dist/`。不要把 `dist/` 里的 zip 手动 `gh release upload` 到已 published 的 immutable release。

## 手动 dry-run（不发布）

GitHub → Actions → **Release** → Run workflow → 勾选 `dry_run`。  
用于验证 action / 打包；**不能**代替 tag 发版。

## 首次上架（一般已完成，勿重复）

一次性人工/半自动步骤（详见 `docs/CLOUD_RELEASE.md`）：

1. 公开仓 + Enable release immutability  
2. 根目录 `module.yaml`  
3. 安装 KernelSU Modules GitHub App  
4. Portal 预检无错误  
5. 发布首个 immutable release  
6. Portal「提交审核」（GitHub 账号注册满 1 年）  
7. 状态 Pending review → 通过后出现在 modules.kernelsu.org  

Agent **不要**重复提交收录；人审期间只修 Check Run 报错或按需发更高 versionCode。

## 上架后可选

在 `module/module.prop` 增加（需新 versionCode 发版才进包内）：

```properties
updateJson=https://modules.kernelsu.org/api/v1/modules/ksu-bgfreeze/update.json
```

## 故障速查

| 现象 | 处理 |
|------|------|
| `version-not-newer` | 提高 `versionCode`，新 tag |
| release 非 immutable | 确认仓库 immutability；用 action 发，勿先 publish 再上传 |
| zip 校验失败 | 修 `module/` 后升 versionCode 重发；旧 tag 作废 |
| tag 已推但 workflow 挂了 | 修 main → **新** versionCode + **新** tag |
| Precheck 红 | 看 prop/yaml/`pack.sh`；与云朵 version 比较无关 |
| 只有 Origin 有提交 | 同步到 GitHub `main` 再打 tag |

## 改代码时的默认习惯

- 功能改动落在 `module/`；用户说明落在 `README.md` / `docs/`
- WebUI：`module/webroot/`；守护进程：`module/bin/bgfreeze-daemon.sh`
- 保持黑名单-only：名单外零干预
- 发版相关流程变更时，同步更新本文件与 `docs/CLOUD_RELEASE.md`
