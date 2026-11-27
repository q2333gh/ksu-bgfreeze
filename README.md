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

## 上架 KernelSU Modules（云朵）

本仓库已含 `module.yaml`，并发布 immutable Release。还需在浏览器完成：

1. 安装 App：https://github.com/apps/kernelsu-modules/installations/new  
2. 门户提交：https://developers.kernelsu.org/
