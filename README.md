# KSU BG Freeze

只对**黑名单**里的应用做退后台冻结的 KernelSU 模块。非黑名单应用不受影响。

在 KernelSU Manager 的 **WebUI** 里勾选应用、点 Apply 即可管理黑名单（带图标与复选框）。

## 功能

- 黑名单模式：仅冻结你选中的应用
- WebUI 管理：在模块页直接勾选 / 取消勾选并应用
- 开机后由 daemon 持续处理退后台场景

## 安装

1. 从 [Releases](https://github.com/q2333gh/ksu-bgfreeze/releases) 下载最新 `.zip`
2. 在 KernelSU Manager → 模块 → 从本地安装
3. 重启后打开本模块 WebUI，勾选需要冻结的应用并 Apply

上架 [KernelSU Modules](https://modules.kernelsu.org) 云端目录后，也可直接在 Manager 的模块目录中搜索安装（需仓库已启用 **immutable releases** 并完成 Portal 提交）。

## 模块信息

| 项 | 值 |
| --- | --- |
| id | `ksu-bgfreeze` |
| 作者 | btwl |

## 说明

本仓库用于发行与目录元数据（`module.yaml`）。模块 ZIP 以 GitHub Release 资产形式发布；KernelSU Modules **不会**代为托管或接收直接上传的 ZIP，只索引你仓库里的不可变 Release。
