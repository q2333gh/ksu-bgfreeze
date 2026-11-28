# 墓碑 / 冻结：期望状态与缺口

> Agent / 产品共同约定。业界对照 → `INDUSTRY_COMPARE.md`；系统安全 → `SYSTEMS_PROGRAMMING_REVIEW.md`。  
> 复核：OP12 · 调研更新 2026-11-28（台北）。

## 一句话

默认成功路径 = **黑名单 + `mode=stop` + `cgroup.freeze`（CPU 墓碑）**。  
**不是** Hail `pm disable`；**也不是** AOSP 完整墓碑（缺 Binder freeze）。

## 网络调研摘要（可落地 vs 不可）

| 来源 | 手段 | 本仓能否做 |
|------|------|------------|
| [AOSP Cached apps freezer](https://source.android.com/docs/core/perf/cached-apps-freezer) | 先 Binder freeze，再 `cgroup.freeze` | CPU ✅；Binder 可用 UAPI ioctl（不必改 AMS）→ 见可行性文 |
| [Binder freezer 语义](https://source.android.com/docs/core/architecture/ipc/binder-freezer) | 同步 Binder 打到已冻进程会杀对端 | 双冻后由驱动回 `BR_FROZEN_REPLY`；仍须门闩 |
| Freezer / NoActive（Xposed） | V2 + 同步 Binder 临时解冻 / Re:Kernel | 高级策略可参考；**不强制 Xposed** |
| OP12 实机 | cgroup 可写；**`BINDER_FREEZE` 对他 pid 成功** | ✅ 探针 2026-11-28 |

**结论**：默认仍走安全 CPU 墓碑；**完整双冻（S2b）在本仓可行**，门闩默认关 → [`FULL_TOMBSTONE_FEASIBILITY.md`](FULL_TOMBSTONE_FEASIBILITY.md)。

## 期望状态机（权威）

| 状态 | 触发 | 期望 | 现状 |
|------|------|------|------|
| **S0 Idle** | 黑名单空 | 不扫包、不冻；仅 start 日志 | ✅ OP12 已证 |
| **S1 Fg-skip** | 名单 ∩ 前台 / fg 未知 | 不冻 | ⏳ 需非空名单验 |
| **S2 Frozen** | 名单 ∩ 后台 ≥ delay；stop | `cgroup.freeze=1`（apps/ 或 uid_/） | ⏳ 代码有；日志未证 |
| **S2b Full** | S2 + `allow-binder-freeze` | 先 `BINDER_FREEZE` 再 cgroup | 🔜 可行（OP12 探针 OK）；见 `FULL_TOMBSTONE_FEASIBILITY.md` |
| **S3 Thaw** | 回前台 / 移出名单 / thaw | freeze=0 | ⏳ |
| **S4 Hail** | allow-disable + disable | pm disable；失败熔断 | ❌ OP12 失败 → 仅 opt-in |
| **S5 Circuit** | Binder 超预算 | 强制 stop | ✅ 已落地 |
| **S6 Panic** | `panic` | daemon 不起 | ✅ |

### 非目标（保持）

- Binder freeze / FrozenStateChangeCallback  
- 空名单 dumpsys/`/proc` 风暴  
- 未 gate 的 `mode=disable`  
- 宣传「完整墓碑」

## 还需要什么

### 必须（产品闭环）

1. **实机验 S2/S3**：WebUI 勾应用宝 → 保存 → 回桌 → 日志 `freeze … backend=cgroup-uid` 且 `cgroup.freeze=1` → 再打开解冻。  
2. **保持 S4 门控**：不把 Hail 当默认；circuit 保留。

### 已做 / 正在做的代码

- cgroup-uid 优先；写后读回校验；SIGSTOP uid 复核  
- **双路径**：`apps/uid_*`（OP12）+ `uid_*`（AOSP）  
- `bgfreeze selfcheck` 打印 backend / 路径 / binder 不可用说明  

### 明确边界

- **`BINDER_FREEZE`**：可在本模块做（门闩默认关）→ 见 `FULL_TOMBSTONE_FEASIBILITY.md`；**不**依赖 Xposed/Re:Kernel  
- 全局冻全机第三方（非黑名单）：不做  
- ColorOS Hans 对抗：冲突时文档降级，不刷 OEM 补丁  
- 改 AMS / 框架广播排队：不做

### 可选增强（有需求再开）

- 冻前 `am force-stop` 一次（更「静」但伤状态，默认关）  
- 冻后抽样读 `cgroup.events`  
- WebUI 显示 selfcheck / backend  

## 验收清单（S2）

1. `blacklist.txt` 含 `com.tencent.android.qqdownloader`  
2. 打开再回桌，等 delay  
3. 日志：`freeze … backend=cgroup-uid`  
4. `cat /sys/fs/cgroup/apps/uid_<uid>/cgroup.freeze` → `1`  
5. 再打开：thaw；无 Failed transaction 风暴  

## 变更策略

改冻结语义：先改本表 → `daemon/src/freezer.rs` → `bump` + `ship.sh`。  
路由：根 `AGENTS.md` → 本文件。
