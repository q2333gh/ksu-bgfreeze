# ksu-bgfreeze

纯 **KernelSU** 模块：只对黑名单里的应用做退后台冻结；名单外零干预。

## 安装

1. 刷入 Release 里的 zip：  
   https://github.com/q2333gh/ksu-bgfreeze/releases/latest
2. 重启
3. KernelSU → 本模块 → **WebUI** → 勾选应用 → **应用**

## 行为

- 勾选的应用退后台约 3 秒 → `SIGSTOP`
- 回到前台 → `SIGCONT`
- 黑名单空 = 空转

配置也可手改：`/data/adb/ksu-bgfreeze/blacklist.txt`  
日志：`/data/local/tmp/ksu-bgfreeze.log`

## 开发

```bash
./scripts/pack.sh
```

产出：`dist/ksu-bgfreeze-<version>.zip`

## 文档

- [docs/UX.md](docs/UX.md) — WebUI 交互
- [docs/FEASIBILITY.md](docs/FEASIBILITY.md) — 可行性说明

## 发版（CI）

推 `v*` tag 即触发官方 `module-release` action，自动预检并以 immutable Release 发 zip：

```bash
# 先改 module/module.prop 的 version / versionCode，更新 CHANGELOG.md
git tag v0.3.2
git push origin v0.3.2
```

也可在 Actions 里手动跑 `Release`（可勾 dry-run）。`main`/PR 上会跑 `Precheck` dry-run。

本地只打包：`./scripts/pack.sh`

## 上架 KernelSU Modules（云朵）

流程复核见 [docs/CLOUD_RELEASE.md](docs/CLOUD_RELEASE.md)。当前：immutable + Check Run 通过，Portal **Pending review**。

- App：https://github.com/apps/kernelsu-modules/installations/new  
- 门户：https://developers.kernelsu.org/
