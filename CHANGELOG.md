# Changelog

## v0.6.0

- Safe-to-enable defaults: empty blacklist = idle (no dumpsys/proc); fg unknown → skip freeze
- IPC budget (3/poll) + `timeout` on dumpsys/am/pm; binder-fail circuit trip
- `mode=disable` hard-gated by `allow-disable` file; boot needs both allow files
- AGENTS: agents must commit/push/CI themselves after code changes

## v0.5.1

- Industry compare doc; `mode=stop` prefers **cgroup uid freeze** (OP12 `apps/uid_*`), then `/dev/freezer`, then SIGSTOP
- SIGSTOP/cgroup.procs: **uid re-check before act** (TOCTOU)
- Absolute paths for `am`/`pm`/`dumpsys`
- See `docs/INDUSTRY_COMPARE.md`

## v0.5.0

- **Architecture: Rust daemon** (`module/bin/bgfreeze`, static aarch64 musl)
- Big-O: per-poll **Θ(T)** `/proc` snapshot → `uid→pids`; blacklist walk **Θ(N+P)** (was **Θ(N·T)**)
- packages.list HashMap O(1) lookup; `pm list -d` once/poll in disable mode
- Shell reduced to boot glue + WebUI `apps.sh`; no shell fallback loop
- See `docs/BIG_O_ANALYSIS.md`

## v0.4.1

- Fail-fast: one `pm disable` + one verify; binder failure opens circuit → `mode=stop`
- Per-pkg failure cooldown (10 min); no retry/SIGSTOP storm after hail fail
- Single-instance `flock` on daemon.lock
- Process scan: one `grep -l` over `/proc/*/status` (no per-pid awk fork bomb)
- `circuit-status` / `circuit-clear` helpers

## v0.4.0

- Hail-style freeze: whole-package `am force-stop` + `pm disable --user` (no component flood)
- WebUI: mode label + 「打开」= enable and launch (Hail LAUNCH)
- Daemon watches disabled state; re-force-stops leaked processes

## v0.3.1

- Immutable release for KernelSU Modules catalog
- `versionCode` 301
- Blacklist-only background freezer + KernelSU WebUI

## v0.3.0

- Initial public WebUI release (icons, checkboxes, Apply)
- Opt-in blacklist SIGSTOP freezer daemon
