# 系统级编程视角 Code Review（v0.5 Rust daemon）

> **对 Agent**：强制执行准则已写入根目录 [`AGENTS.md`](../AGENTS.md)「硬约束：系统级编程安全」。本文是长文依据与缺口对照；改 daemon / 做 review 时以 AGENTS 强制条为准，不够再读本文与其中外链。

## 1. 我们算不算「系统级编程」？

**是——偏 Android/Linux 用户态系统编程（userspace systems programming），不是内核模块开发。**

| 层级 | 我们做的事 | 典型同类 |
|------|------------|----------|
| 进程控制 | `kill(SIGSTOP/CONT)`、扫 `/proc` | 调试器、容器运行时、墓碑 daemon |
| IPC / 服务总线 | fork `am`/`pm`/`dumpsys` → Binder | 大量 Magisk/KSU 模块 |
| 同步 / 单实例 | `flock` | 经典 Unix daemon |
| 策略副作用 | `pm disable` 改 PackageManager 状态 | Hail / Titanium「冻结」 |
| 未做 | 内核模块、eBPF、直接 `BINDER_FREEZE` ioctl、改 AMS | Freezeit+Xposed / AOSP CachedAppOptimizer |

特征：**以 root 身份、持续常驻、对别的进程与系统服务施加副作用**。出错代价是整机卡死（已发生过 Watchdog），因此应按 **privileged systems daemon** 的纪律写，而不是普通 App 业务代码。

---

## 2. Critical 面（必须当高压线）

### C1. PID TOCTOU（检查与使用之间的竞态）

```text
scan /proc → 记下 (pid, uid)
… 若干毫秒 …
kill(pid, SIGSTOP)
```

经典 **TOCTOU**（Secure Programming HOWTO / TLDP）：pid 可能已被回收并复用给**另一个 uid**。  
当前：`stop_running` **不再复核** `/proc/pid/status` 的 Uid。  
**准则**：信号前 `open(/proc/pid/status)` 再读 Uid，不匹配则跳过；或改用 **cgroup.freeze（按 uid）** 消掉按 pid 操作。

### C2. `kill` 目标集合（blast radius）

- 根身份下 `kill` 几乎无限制。
- 仅靠 `uid >= 10000` 过滤：**共享 uid 的多包、孤立进程、错误解析**都会扩大伤害。
- 内核文档明确：**SIGSTOP/SIGCONT 对任务可见**，不如 cgroup freezer；第三方可 `SIGCONT` 解冻。

**准则**：白名单操作面尽量 **cgroup / uid 作用域**；信号路径必须 **pid→uid 复核 + 关键包拒绝列表**。

### C3. Binder / `system_server` 预算（整机存活）

事故根因不是「冻结语义错」，而是 **用户态对 system_server 的 IPC/fork 风暴**。  
当前 fail-fast/circuit 方向对，但仍要注意：

| 调用 | 风险 |
|------|------|
| 每轮 `dumpsys activity` | 重；应事件化或更长节流 |
| `pm list -d` / `pm disable` | Binder；失败必须熔断（已有） |
| `am force-stop` | 同左 |
| 验证时再 `list_disabled` | apply 路径二次 Binder |

**准则**：给 daemon 设 **硬配额**（每秒 Binder 调用上限、每轮 dump 次数）；失败 **降级/停机**，禁止重试风暴。

### C4. 关键系统组件误伤

`is_critical` 字符串前缀防呆有用，但：

- 漏网 OEM 包 / 输入法 / 车机助手仍可能锁机；
- `pm disable` 比 SIGSTOP **危险一个数量级**（图标消失、开机组件不跑）。

**准则**：`disable` 模式默认关；开机强制 `stop`；deny-by-default（仅黑名单显式包）；永远不碰 `uid<10000`。

### C5. 单实例与启动竞态

`flock` 正确；但 `service.sh` + `boot-completed.sh` 仍可能短时间双启（第二个应立刻退出——依赖 flock）。  
pidfile **不是**锁，只是调试辅助。

**准则**：锁是唯一权威；启动脚本禁止 `pkill -f` 误伤。

### C6. `/proc` 扫描本身

- Θ(T) 打开大量小文件：在 T≈10⁴ 时仍有可测 CPU/页缓存压力。
- `read_dir` + 逐个 `open`：相对 BPF iterator / `cn_proc` 仍贵，但对 Magisk 模块可接受。
- `parse_status` 截断 2KiB：status 通常够；若异常截断可能丢 Uid → 跳过（安全偏向失败）。

### C7. 子进程执行面

`Command::new("pm")` 依赖 `PATH`/`/system/bin`。应固定绝对路径，避免 PATH 劫持（root 下更敏感）。  
stdout/stderr  unbounded：极端 dumpsys 输出应设超时与字节上限。

### C8. 冻结语义完整性（相对业界最优）

业界「完整墓碑」= **cgroup freezer + Binder freeze**（AOSP CachedAppOptimizer / Freezeit 文档）。  
我们只有 SIGSTOP 或 pm disable：

- SIGSTOP：CPU 停，Binder 仍可能排队 → 对端超时杀进程；
- pm disable：最强「不可运行」，但 Binder 脉冲 + UX 副作用大。

---

## 3. 可直接套用的 Linux / 安全开发准则

| 来源 | 对我们有用的条目 |
|------|------------------|
| **TLDP Secure Programming HOWTO** | 消除 TOCTOU；检查与作用不可分割；文件系统原子创建 |
| **POSIX / man 7 signal** | 不把 SIGSTOP 当通用作业控制；注意 pid 复用 |
| **cgroup v2 freezer 文档** | 优先 `cgroup.freeze`；写后读 `cgroup.events`；成员会变 |
| **AOSP Cached apps freezer** | 先 binder freeze 再 process freeze；生命周期事件解冻 |
| **Freezeit / NoActive 实践** | V2>V1>SIGSTOP；无 binder freeze 会闪退；OEM 冲突（Millet/Hans） |
| **经典 Unix daemon** | flock 单实例；fail-fast；可预测日志；kill-switch |
| **率限制 / 熔断** | 任何对 system_server 的调用都有预算与断路器 |

推荐阅读顺序（短）：

1. TLDP Secure Programming — Race Conditions  
2. Kernel doc: cgroup v2 `cgroup.freeze`  
3. AOSP: Cached apps freezer  
4. man 2 kill / man 7 signal  

---

## 4. 对照我们代码的「已做 / 未做」

| 准则 | v0.5 状态 |
|------|-----------|
| 单实例 flock | ✅ |
| fail-fast + circuit | ✅（disable 路径） |
| 默认 stop / 模块 disable | ✅ 运维层 |
| 关键包前缀拒绝 | ✅ 不完整 |
| PID 使用前 uid 复核 | ❌ |
| dumpsys 超时/字节帽 | ❌ |
| Binder 每秒配额 | ❌（仅失败熔断） |
| 绝对路径 exec | ❌ |
| cgroup freezer | ❌（OP12 上 `/sys/fs/cgroup/apps/uid_*/cgroup.freeze` 与 `/dev/freezer` 可用） |
| Binder freeze | ❌（需驱动/框架，超出当前模块） |

---

## 5. 写 safe 代码的最小纪律清单（本项目）

1. **作用域最小**：只动黑名单 uid；信号前复核 uid。  
2. **失败默认安全**：不确定 → 不冻结 / 不 disable；打开 circuit。  
3. **预算**：每轮最多 1× 轻量前台探测、1× `pm list`；apply ≤1 次/包并 cooldown。  
4. **可杀死**：`disable` 文件、`panic`、flock、永远能 `SIGKILL` 自己。  
5. **可观测**：每次强制副作用打结构化日志（pkg, uid, pid, rc, binder_fail）。  
6. **能回滚**：mode=stop 必须 revive；emergency 路径保留。  
7. **别在热路径造进程**：已用 Rust 扫 `/proc`；禁止再引入 shell 循环。  
8. **升级冻结原语时**：SIGSTOP → cgroup.freeze（验证 events）→（可选）框架/Binder 协同；每步单独可关。

---

## 6. 结论

- **是系统级（用户态特权）编程**；安全模型接近「微型 init/容器助手」，不是 App。  
- **最 critical**：PID TOCTOU、`kill`/`pm` 误伤、Binder 预算、disable 模式爆炸半径。  
- **手册价值最大的三块**：TOCTOU/竞态、cgroup freezer 语义、对 system_server 的熔断式 IPC。  
- 下一跳性能+安全同向：**按 uid 写 `cgroup.freeze`（O(1)、无 pid 复用）+ 更严的 IPC 配额**；比继续优化 `/proc` 扫描更符合业界最优路径。
