# KernelSU 云朵发版流程复核

> Agent 发版 runbook：`.cursor/skills/release/SKILL.md`（根 [AGENTS.md](../AGENTS.md) 只作路由）。本文是合规台账与背景。

依据：https://developers.kernelsu.org/docs/zh-CN/getting-started  
https://developers.kernelsu.org/docs/zh-CN/releasing

## 完整流程

1. 公开 GitHub 仓库（管理员）
2. 启用 Release immutability
3. 选定 `module.prop` / `module.yaml` 的 `id`
4. 根目录 `module.yaml` + 描述文档
5. 安装 KernelSU Modules GitHub App
6. Portal 预检
7. 发布 **immutable** Release（恰好 1 个模块 zip；`versionCode` 递增）
8. Portal 提交审核（账号满 1 年）→ 待审 → 通过后进云朵
9. 之后每次更高 `versionCode` 的 immutable Release **自动同步**，无需再审

官方推荐发版方式：推 `v*` tag → `module-release` action（draft→上传→发布）。  
本仓：`main` 升 `versionCode` 后由 **Auto Tag** 自动推 tag，再触发 Release。

## 我们是否符合（复核时点：提交 Pending review 之后）

| 要求 | 状态 | 说明 |
|------|------|------|
| 公开仓库 | ✅ | `q2333gh/ksu-bgfreeze` |
| Release immutability 已开 | ✅ | API `immutable-releases.enabled=true` |
| `id` 合法且一致 | ✅ | `ksu-bgfreeze`（prop 与 yaml） |
| `module.yaml` | ✅ | 根目录，指向 `README.md` |
| Modules App | ✅ | 已有 Check Run |
| Portal 提交 | ✅ | Pending review |
| 账号 ≥1 年 | ✅ | q2333gh @ 2017 |
| 当前稳定 zip immutable | ✅ | 最新如 `v0.6.0`（601 起走 Auto Tag）；历史 `v0.3.1` 仍 immutable |
| ZIP 结构 / module.prop 字段 | ✅ | Sync Check 随每次 Release |
| `module.yaml` 文档检查 | ✅ | Check：`module.yaml and documents are valid` |
| 仓库内发版 CI | ✅ | `Auto Tag`（main）→ `Release`（tag）→ module-release；`Precheck` 结构/打包 |
| 已出现在 modules.kernelsu.org | ⏳ | 等人审 |

## 已知非阻断项

- `v0.3.0` 是 immutability 开启前发的，`immutable:false`，云朵会忽略它（符合预期）。
- 上架后可在 `module.prop` 加官方 `updateJson`：  
  `https://modules.kernelsu.org/api/v1/modules/ksu-bgfreeze/update.json`
- 图标 `module.yaml` 的 `icon` 可选，当前未配。

## 以后怎么发版（固定一键）

```bash
bash scripts/bump-version.sh --patch
# 编辑 CHANGELOG
bash scripts/ship.sh -m "Release vX.Y.Z"
# Origin → daily_env1 同步 GitHub main
```

Actions 固定链：**Precheck** 成功 → **Auto Tag** → **Release**（immutable zip）。  
见 [workflows/ship.md](workflows/ship.md) · [AGENTS.md](../AGENTS.md)。
