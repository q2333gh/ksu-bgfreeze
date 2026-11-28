# Big-O 关键路径分析（改 Rust 前基线）

符号：

| 符号 | 含义 |
|------|------|
| \(N\) | 黑名单包数 |
| \(T\) | 系统进程/线程数（`/proc` 或 `ps` 行数） |
| \(P_u\) | 某 uid 进程数 |
| \(P=\sum P_u\) | 黑名单相关进程总数 |
| \(D\) | 已 disabled 包数（`pm list -d`） |
| \(A\) | `dumpsys activity` 输出行数 |
| \(L\) | `packages.list` 行数（已装包） |
| \(C\) | 每轮 poll（现 3s） |

---

## 1. v0.4.0 事故版（每 PID awk）

| 位置 | 工作 | 复杂度 |
|------|------|--------|
| `each_pid(uid)` | 对每个 `/proc/*/status` fork `awk` | **Θ(T) forks** |
| `snap_uid` / `freeze_uid` | 再对 \(P_u\) 个 pid 各 fork `awk` | **Θ(T + P_u)** forks |
| 主循环 × \(N\) 包 | 每包可能调用上述 | **Θ(N·T) forks / 轮** |
| 多实例 \(K\) | 无 flock | **Θ(K·N·T)** |
| `tombstone_apply` 重试链 | 多次 `pm`/`dumpsys` | **Θ(R)** Binder，R≥3 |

实测：数分钟内 ~2.9×10⁴ 次 `awk` → 与 **Θ(N·T/C)** 一致（T 大时灾难）。

---

## 2. v0.4.1 shell（改前最后一版）

| 位置 | 工作 | 每轮复杂度 |
|------|------|------------|
| `fg_pkg` | 1× `dumpsys` + grep | **Θ(A)** + **1 Binder**（有 2s 缓存 ≈ 每轮仍常打） |
| `uid_of` × N | 每包扫 `packages.list` | **Θ(N·L)** |
| `pids_for_uid` × N | 每包 1× `ps -A` + awk | **Θ(N·T)** ← 主瓶颈 |
| `freeze_uid` | 每相关 pid：`sed` State + `kill` | **Θ(P)** forks（额外） |
| `hail_is_pkg_disabled` × 标记包 | 每包 `pm list -d \| grep` | **Θ(M·D)** + **M Binder**（M≤N） |
| `tombstone_apply` | 1 am + 1 pm + 1 list | **O(1)** Binder（fail-fast）✓ |
| flock | 启动一次 | **O(1)** ✓ |

**总（stop 稳态）**：\(\mathbf{Θ(N·T + N·L + A + P)}\) 每轮，主导 **N·T**。  
**总（disable 稳态）**：\(\mathbf{Θ(A + M·D)}\) Binder 主导。

---

## 3. 目标 Rust 架构

| 位置 | 工作 | 每轮复杂度 |
|------|------|------------|
| 读 mode / killswitch | 文件 stat | **O(1)** |
| 载入黑名单 | 读文件 | **O(N)**（mtime 变才重读） |
| `packages.list` 索引 | HashMap pkg→uid | **O(L)** 构建，查 **O(1)** 均摊；mtime 刷新 |
| 进程快照 | 一次扫 `/proc` 或一次 `ps` | **Θ(T)** 建 `HashMap<uid, Vec<pid>>` |
| 前台包 | dumpsys（节流）或轻量探测 | **O(A)**，间隔 ≥5s |
| 对 N 包决策 | HashMap 查 pid 列表 + SIGSTOP | **Θ(N + P)** 无额外全表扫 |
| disable 校验 | 一次 `pm list -d` → HashSet | **Θ(D)** + **1 Binder** / 轮 |
| apply | 每包最多 1 次 | **O(1)** Binder；失败 cooldown / circuit |

**总（stop）**：\(\mathbf{Θ(T + L_{refresh} + N + P)}\) ≈ **Θ(T)**（T ≫ N,P）。  
相对 v0.4.1：去掉 **N 倍** 全表扫描 → **Θ(N·T) → Θ(T)**。  
相对事故版：去掉 per-pid fork → 常数因子再降 1–2 个数量级。

---

## 4. 复杂度对照

| 版本 | 每轮主导 | 相对事故版 |
|------|----------|------------|
| 事故 shell | Θ(N·T) forks | 1×（基线灾难） |
| v0.4.1 shell | Θ(N·T) 进程扫描（少 fork） | 同阶，常数↓ |
| **Rust 目标** | **Θ(T)** 一次快照 | **约 1/N** |

N=10、T=8000 时：事故/0.4.1 量级 ~8×10⁴ 扫描单元/轮；Rust ~8×10³（一次），并消灭 awk/sed 进程创建。
