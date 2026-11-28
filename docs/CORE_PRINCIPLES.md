# 核心原理（给人看）

> ksu-bgfreeze 是什么、靠什么冻、为什么敢开、边界在哪。  
> 状态机细节 → [`TOMBSTONE_PLAN.md`](TOMBSTONE_PLAN.md) · 业界对照 → [`INDUSTRY_COMPARE.md`](INDUSTRY_COMPARE.md) · 安全高压线 → [`SYSTEMS_PROGRAMMING_REVIEW.md`](SYSTEMS_PROGRAMMING_REVIEW.md)

## 1. 要解决什么

手机上部分 App 退后台后仍占 CPU / 乱拉起。本模块只对你**勾选的黑名单包**，在**确认已退后台**后做「CPU 停住、进程还在内存」的冻结；回前台再解冻。  
名单外的包：**零干预**。

## 2. 我们在哪一层？（内核 vs 用户态）

| 问题 | 答案 |
|------|------|
| 有没有自研内核模块（`.ko`）？ | **没有** |
| 是不是 KernelSU **用户态**模块？ | **是**（root daemon + 脚本 + WebUI） |
| 会不会用到内核能力？ | **会**——通过 sysfs 调用内核**已有的** cgroup freezer |

```text
App / system_server     ← Binder freeze 在框架/驱动（本仓不做）
        ▲
bgfreeze (root 用户态)  ← KernelSU 模块装的常驻进程
        │ open/write
        ▼
内核 cgroup freezer     ← 真正挂起线程；我们只「调用」不「实现」
```

**口径**：有「调用内核设施的 root 用户态能力」，没有「内核级插件 / 完整框架墓碑」。

## 3. 核心机制（一句话）

**写 cgroup：`cgroup.freeze = 1`。**

内核 freezer 把该 uid 下任务挂起，不再吃 CPU；解冻写 `0`。  
在 OP12（ColorOS）上路径通常是：

```text
/sys/fs/cgroup/apps/uid_<应用UID>/cgroup.freeze
```

AOSP 风格机器也可能是：

```text
/sys/fs/cgroup/uid_<UID>/cgroup.freeze
```

本模块两种都认；都没有则退到 cgroup v1 `/dev/freezer`，再不行才 `SIGSTOP`（信号前复核 uid，防 PID 复用）。

这叫 **CPU 墓碑 / stop 模式**，不是把 App 从包管理器里禁用。

## 4. 和「完整墓碑」差在哪（以及有没有机会）

业界完整方案（AOSP CachedAppOptimizer）是：

1. **先** Binder freeze（`ioctl(/dev/binder, BINDER_FREEZE)`）  
2. **再** `cgroup.freeze`

| | 当前默认 | 完整墓碑（驱动层） |
|--|----------|-------------------|
| CPU | ✅ cgroup.freeze | ✅ |
| Binder | ❌（未接线） | ✅ `BINDER_FREEZE` |
| 风险 | 冻后 sync Binder 可能杀被冻进程 | 驱动直接回 `BR_FROZEN_REPLY` |

**机会（2026-11 调研 + OP12 探针）**：root 用户态**可以直接**打 `BINDER_FREEZE`，**不必**改 AMS / Xposed。OP12 上对他 pid freeze/thaw 已成功。  
→ 详细评估与分阶段计划：[`FULL_TOMBSTONE_FEASIBILITY.md`](FULL_TOMBSTONE_FEASIBILITY.md)。

当前发版仍只宣传「黑名单后台 CPU 冻结」；Binder 双冻须门闩、默认关。

## 5. 系统怎么转起来

```text
┌─────────────┐     勾选/模式      ┌──────────────────┐
│ KernelSU    │ ──apps.sh────────►│ blacklist.txt    │
│ WebUI       │                   │ mode (stop/…)    │
└─────────────┘                   └────────┬─────────┘
                                           │
┌─────────────┐   flock 单实例            ▼
│ bgfreeze    │◄── 读名单 / 模式 ──  /data/adb/ksu-bgfreeze/
│ (Rust 常驻) │
└──────┬──────┘
       │ 有黑名单才工作；空名单 → 睡觉（S0 Idle）
       │
       ├─ dumpsys 看前台（有配额；失败则本轮不冻）
       ├─ 一拍扫描 /proc → uid→pids（Θ(T)）
       └─ 后台够久 → freeze_uid / 回前台 → thaw_uid
```

- **决策在 daemon**：谁冻、何时冻。  
- **WebUI / apps.sh**：改名单与模式、热更、救急；**禁止**在 WebUI 路径全表扫 `/proc`。

## 6. 两条产品路径

### A. 默认：`mode=stop`（推荐）

1. 包在黑名单  
2. 不是前台  
3. 退后台超过 delay（约数秒）  
4. → `cgroup.freeze=1`，落盘 `frozen.<包名>`  
5. 回到前台或移出名单 → 解冻  

空黑名单：**整 daemon 空转**，不 dumpsys、不为冻包扫世界。这是「敢随便开」的根。

### B. 危险 opt-in：`mode=disable`（Hail）

须先有文件 `allow-disable`（开机保留还要 `allow-disable-on-boot`）：

- `am force-stop` + **一次** `pm disable`  
- 失败立刻 **circuit**（熔断）→ 退回 `stop`，禁止重试风暴  

OP12 上这条曾把 system_server 打出 `Failed transaction`；**默认关闭**，不是主目标。

## 7. 安全原则（写进代码的）

1. **黑名单-only**，不碰 uid &lt; 10000  
2. **空名单 idle**；前台未知 → 本轮不冻  
3. **Binder 有超时 + 每轮配额**；超了熔断  
4. **单实例 `flock`**；pidfile 只辅助  
5. **PID 用前复核 uid**（SIGSTOP / v1 路径）  
6. **cgroup 写后读回**校验  
7. **热更必须整包 zip**（`apps.sh hot-update`），禁只拷脚本  

事故教训见 [`INCIDENT_2026-11-28_OP12_SOFTLOCK.md`](INCIDENT_2026-11-28_OP12_SOFTLOCK.md)。

## 8. 你在日志里该看到什么

| 场景 | 日志 |
|------|------|
| 刚装上、名单空 | `start … mode=Stop backend=cgroup-uid … safe_enable=1`，然后安静 |
| 名单有包、在冻 | `freeze <pkg> uid=… backend=cgroup-uid` |
| 回前台 | `thaw …` |
| Hail 熔断 | `circuit-open …`，之后当 stop |

自检：`bgfreeze selfcheck` 或 `apps.sh diagnose`（backend、是否有 apps 层级、Binder 标明不可用）。

## 9. 配置与产物位置

| 路径 | 含义 |
|------|------|
| `/data/adb/modules/ksu-bgfreeze/` | 模块（含 `bin/bgfreeze`、WebUI） |
| `/data/adb/ksu-bgfreeze/blacklist.txt` | 黑名单 |
| `/data/adb/ksu-bgfreeze/mode` | `stop` / `disable` |
| `/data/adb/ksu-bgfreeze/allow-disable` | Hail 门闩 |
| `/data/local/tmp/ksu-bgfreeze.log` | 运行日志 |

## 10. 相关文档地图

| 文档 | 内容 |
|------|------|
| 本文 | 核心原理（你正在看的） |
| `TOMBSTONE_PLAN.md` | S0–S6 期望状态与实机结论 |
| `INDUSTRY_COMPARE.md` | 和 Hail / Freezeit / AOSP 比什么 |
| `BIG_O_ANALYSIS.md` | 每轮扫描复杂度 |
| `SYSTEMS_PROGRAMMING_REVIEW.md` | 特权 daemon 高压线 |
| `workflows/ship.md` | 发版固定链 |
