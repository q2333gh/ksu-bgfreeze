# 完整墓碑可行性（cgroup + Binder freeze）

> 对应 `CORE_PRINCIPLES` §4「完整目标」。调研 + OP12 探针：2026-11-28（台北）。

## 1. 目标定义（真正意义上的墓碑）

与 [AOSP CachedAppOptimizer](https://source.android.com/docs/core/perf/cached-apps-freezer) 同序：

1. **Binder freeze**：对目标 **pid** 调 `BINDER_FREEZE`（驱动得知「此进程冻了」；同步调用得 `BR_FROZEN_REPLY`，避免调用方死等）  
2. **再** `cgroup.freeze=1`：停 CPU  
3. 解冻：**先** cgroup 解冻，**再** Binder unfreeze（与 AOSP 解冻顺序一致）

没有第 1 步，只有 CPU 冻 → 同步 Binder 仍可能把**被冻进程**打死（AOSP 文档行为）。

## 2. 以前以为「做不到」——现已证伪（部分）

| 旧说法 | 现结论 |
|--------|--------|
| 必须改 AMS / Xposed 才能 Binder freeze | **不必须**。UAPI：`ioctl(/dev/binder, BINDER_FREEZE, {pid, enable, timeout_ms})`（见 [binder.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/android/binder.h)、AOSP `IPCThreadState::freeze`） |
| 纯 KSU 用户态摸不到 | **root 用户态可调**。OP12 探针：对第三方 pid `GET_FROZEN_INFO` / `FREEZE enable=1` / thaw **均成功** |
| 必须刷 Re:Kernel | Re:Kernel 利于「同步 Binder 临时解冻」等高级策略；**不是** `BINDER_FREEZE` 的前置条件 |

OP12 现场：`use_freezer=true`，`CONFIG_ANDROID_BINDER_IPC=y`，`CONFIG_CGROUP_FREEZER=y`，`/sys/fs/cgroup/apps/uid_*/cgroup.freeze` 可写。

## 3. 机会评估

| 维度 | 评级 | 说明 |
|------|------|------|
| **技术可达（本仓边界）** | **高** | Rust daemon 内对黑名单各 pid：`BINDER_FREEZE` → `cgroup.freeze`；解冻反过来 |
| **与「完整墓碑」语义对齐** | **中高** | 驱动层 Binder+cgroup 齐；仍无 AMS 生命周期事件解冻、广播排队等框架策略 |
| **OEM 风险（ColorOS）** | **中** | Hans/Millet 可能抢冻/解冻；部分厂商内核曾 `#if 0` 掉 freeze ioctl（OP12 探针显示**未禁用**） |
| **产品风险** | **中** | 冻后同步交易 → 杀被冻进程（AOSP 预期）；需 fail-fast、名单小、可一键 thaw |
| **工程量** | **中低** | 无新依赖；主要是 ioctl 封装、多 pid、顺序、超时/`EAGAIN`、日志与门闩 |

**总判：有机会在本模块内逼近「真正意义上的墓碑」；不是幻想，也不是改 ROM 才能做。**  
达不到 100% AOSP（缺框架侧策略），但 **Binder+cgroup 双冻** 这条硬路径 **可做**。

## 4. 推荐实现路径（计划）

### Phase 0 — 探针固化（已部分完成）

- [x] OP12：`BINDER_FREEZE` / `GET_FROZEN_INFO` 对他 pid 成功  
- [ ] `bgfreeze selfcheck` 打印 `binder_freeze=ok|fail`（替换「unavailable」文案）  
- [ ] 多机抽样（若有）

### Phase 1 — 可选能力，默认关

- 新开关文件：`/data/adb/ksu-bgfreeze/allow-binder-freeze`（或 WebUI 高级项）  
- `mode=stop` 且开关存在时：  
  `for pid in uid_pids: BINDER_FREEZE(pid,1,timeout)` → 失败则 **不** cgroup 冻，打日志 / 计入 circuit  
  成功 → 现有 `cgroup.freeze=1`  
- 解冻：`cgroup=0` → `BINDER_FREEZE(pid,0)`  
- 超时/`EAGAIN`：短重试有上限（禁风暴）

### Phase 2 — 实机验收（应用宝）

1. 勾选 yyb + 打开 binder-freeze 门闩  
2. 退后台 → 日志：`binder-freeze …` 然后 `freeze … cgroup-uid`  
3. `GET_FROZEN_INFO` / 无 Watchdog；再打开可恢复  
4. 对比关门闩时的「冻后被 sync 杀」率

### Phase 3 — 策略打磨（可选）

- 仅对 **主进程** binder-freeze vs 全 pid  
- 与系统 `use_freezer` 并存时的冲突观察  
- 文档：明确「完整度 = 驱动双冻，≠ 框架完整 CachedAppOptimizer」

### 明确仍不做

- 改 system_server / 刷 Re:Kernel 作为硬依赖  
- 默认对所有第三方开 Binder freeze（必须门闩 + 黑名单）  
- Hail `pm disable` 冒充完整墓碑  

## 5. 顺序口诀（写进代码注释）

```text
冻：  Binder FREEZE(enable=1)  →  cgroup.freeze=1
解：  cgroup.freeze=0          →  Binder FREEZE(enable=0)
```

与 AOSP「先 binder 再 process；解冻相反」一致。

## 6. 与现有文档关系

| 文档 | 关系 |
|------|------|
| `CORE_PRINCIPLES.md` | 应用层原理；§4 应链到本文（旧「摸不到」已过时） |
| `TOMBSTONE_PLAN.md` | 增加状态 **S2b Full**（Binder+cgroup） |
| `INDUSTRY_COMPARE.md` | 更新「本模块可追平驱动层双冻」 |

## 7. 下一步（需你拍板）

1. **同意 Phase 1**：默认关的 `allow-binder-freeze` + daemon 双冻路径 → 升号实装  
2. 或先只做 **selfcheck 探针进正式包**，再开 Phase 1  

建议：先 1（门闩默认关，风险可控）。
