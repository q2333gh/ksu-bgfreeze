# 业界冻结路径对比（相对本仓库 v0.5 → v0.5.1）

对照：Hail、Freezeit/NoActive、AOSP CachedAppOptimizer、本模块。OP12（内核 6.1）实测路径见文末。

## 路径一览

| 方案 | 冻结手段 | 控制器成本 | 完整度 | 风险 |
|------|----------|------------|--------|------|
| **Hail** | `pm disable` / hide / suspend + force-stop | 事件驱动，低 | 「不可运行」强；suspend **不**停后台 CPU | Root 下 pm 慢；误伤系统包致命 |
| **AOSP Cached freezer** | cgroup v2 + **Binder freeze** | Framework 内，事件驱动 | 业界完整标准 | 需内核/驱动；OEM 可关 |
| **Freezeit / NoActive** | V2/V1 freezer > SIGSTOP；常配 Xposed | Native daemon + hook | 接近完整（有 binder 协同时） | OEM Millet/Hans 冲突；维护重 |
| **本模块 ≤v0.5** | SIGSTOP 或 Hail disable | Θ(T) `/proc` + 轮询 | 无 binder freeze | SIGSTOP TOCTOU；disable Binder |
| **本模块 v0.5.1** | **优先** `apps/uid_*/cgroup.freeze`，否则 V1 `/dev/freezer`，再 SIGSTOP（kill 前复核 uid） | stop：**O(1)/uid**（cgroup） | 仍无 binder freeze | 见下 |

## 性能结论（控制器侧）

1. **最高效且更安全的用户态 CPU 冻结**：按 uid 写 `cgroup.freeze`（OP12：`/sys/fs/cgroup/apps/uid_<uid>/cgroup.freeze`）→ **O(1)**，消灭 PID 复用与 Θ(T) 扫描依赖（仍可低频扫做观测）。
2. **SIGSTOP**：实现简单，但信号可见、可被 `CONT`、需扫 pid + TOCTOU。
3. **`pm disable`**：语义最强「停用」，不是高性能路径；Binder 脉冲大，本模块仅 opt-in + fail-fast。
4. **eBPF / cn_proc**：扫描可再降，但 KSU 模块交付与兼容成本高，非当前切片。

## 完整度结论

「完整墓碑」= **cgroup freezer + Binder freeze**（AOSP / Freezeit 文档）。  
本模块 **未**做 Binder freeze；冻结期间对端 Binder 超时仍可能导致杀进程/闪退——不得宣传为完整墓碑。

## OP12 实测（只读）

- `/sys/fs/cgroup/apps/uid_*/cgroup.freeze` 存在（第三方 uid 在 `apps/` 下）
- `/dev/freezer/{frozen,thaw}/cgroup.procs` 存在（cgroup v1 freezer）
- `device_config use_freezer` 曾为 null；`Apps frozen: 0` 时有之

## 本仓库落地选择

- `mode=stop`：**自动选** cgroup-uid → freezer-v1 → sigstop  
- `mode=disable`：保持 Hail 单次 apply + circuit（不变）  
- 默认仍 `stop`；模块 `disable` 未解除前不在用户机上跑热路径
