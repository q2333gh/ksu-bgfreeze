# daemon/（Rust bgfreeze）

叶子约定；全局边界见根 `AGENTS.md`。

## Stack

- Rust edition 2021；CI：`aarch64-linux-android`（NDK）；本地可 musl（`CROSS_ROOT`）。
- 入口：`src/main.rs`；模块：`config` / `freezer` / `hail` / `ipc` / `lock` / `logutil` / `procscan`。
- `version` 与 `module/module.prop` 对齐（`ship.sh` / `bump-version.sh` 会改 `Cargo.toml`）。

## Commands

```bash
# 仓库根
bash scripts/build-daemon.sh          # → module/bin/bgfreeze
"$MOD/bin/bgfreeze" version|daemon|selfcheck
```

## Local rules

- 热路径：每轮至多一次 `/proc` 快照；**空黑名单 idle**（勿 dumpsys / 勿冻包）。
- 前台未知 → 本轮不冻；IPC：`ipc::run_capped` + 配额；失败熔断 → `circuit.open` + 回 `stop`。
- `mode=disable` 仅当 `allow-disable` 存在；否则写回 `stop`。
- cgroup-uid freeze 优先于 SIGSTOP；信号/写 cgroup.procs 前 **uid 复核**（TOCTOU）。
- 改冻结/Binder 前读 `docs/SYSTEMS_PROGRAMMING_REVIEW.md`；复杂度：`docs/BIG_O_ANALYSIS.md`。
