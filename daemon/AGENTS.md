# daemon/（Rust bgfreeze）

叶子约定；全局边界见根 `AGENTS.md`。

## Stack

- Rust，edition 2021；交叉目标 CI 用 `aarch64-linux-android`（NDK），本地可 musl。
- 入口：`src/main.rs`；模块：`config` / `freezer` / `hail` / `ipc` / `lock` / `logutil` / `procscan`。

## Commands

```bash
# 从仓库根
bash scripts/build-daemon.sh
# 产出安装到 ../module/bin/bgfreeze
```

## Local rules

- 热路径：每轮至多一次 `/proc` 快照；空黑名单空转（勿 dumpsys）。
- 前台未知 → 本轮不冻；IPC 走 `ipc::run_capped` + 配额。
- `mode=disable` 仅当 `allow-disable` 存在；否则写回 `stop`。
- 改冻结/Binder 前先读 `docs/SYSTEMS_PROGRAMMING_REVIEW.md`。
- 复杂度论据：`docs/BIG_O_ANALYSIS.md`。
