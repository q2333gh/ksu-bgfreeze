# 渐进性能深度分析（v0.4.1）

对照：2026-11-28 OP12 `system_server` Watchdog 事故。

## 结论

事故根因是 **全表 `/proc` × 每 PID `awk` fork 风暴** + 多 daemon 实例 + `pm` 重试链，拖垮 Binder → `StorageManagerService`/`IVold` → Watchdog。

v0.4.1 已切掉最致命路径（flock、fail-fast、circuit、`ps` 代 awk 全表），但 **shell 稳态仍有线性成本**：每轮 `dumpsys`、每包一次 `ps`、disable 稳态反复 `pm list -d`。

长期：**daemon 用 Rust/Go 静态二进制**；shell 只留 `service.sh` / WebUI 桥。

## 成本层级

| 层级 | 主路径 | 风险 |
|------|--------|------|
| L0 事故峰值 | `each_pid` × awk `/proc/*/status`（~29k awk）+ pm 重试 | WDT / 软锁 |
| L1 stop | 1×dumpsys + N×(ps\|awk + sed×P + kill) | 可控，随 N 升 |
| L1 disable | 首次 am+pm；稳态 pm list -d × 标记包 | Binder 敏感，有 circuit |

## 热路径（仍贵）

1. **`fg_pkg`**：每轮 `dumpsys activity`（2s 缓存仍重）— 最大稳态开销  
2. **`hail_is_pkg_disabled`**：每标记包全量 `pm list -d` — 应全局缓存  
3. **`pids_for_uid`**：每包一次全表 `ps` — 应每轮共享快照  
4. **`freeze_uid`**：每 pid `sed` State — 仍有 per-pid fork  
5. **`uid_of`**：每包 awk `packages.list` — 应常驻表  

## 语言选择

| 语言 | 裁决 |
|------|------|
| Shell | 只留 entry / WebUI 桥 |
| **Rust** | **daemon 首选**（无 fork、静态 aarch64、强 fail-fast） |
| Go | 次选（迭代快、GC 可接受） |
| Kotlin（Hail 路线） | 要 App + 系统 API 深度时 |
| C | 性能最优但维护差，不推荐 |
| Python / Node | 否决（模块无 runtime） |

语言换不掉 Binder（`am`/`pm` 仍贵），但能换掉 **fork 税** 和脆弱状态机。

## 推荐下一步（按收益）

- **P0** 每轮一次进程快照 `uid→pids`；`pm list -d` 每轮最多一次  
- **P1** 前台探测节流 ≥5s；`packages.list` 常驻  
- **P2** Rust/Go 重写 daemon（`freezectl` 子命令替代 `apps.sh` 核心）

交互画布：[ksu-bgfreeze 性能深度分析](https://cursor.com/canvas/store-7f4f7580-9b94-443c-939a-bdea5676d171/584631d2-0fd9-46f4-9efc-c5e0570c2080)
