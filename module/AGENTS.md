# module/（KernelSU zip 根）

叶子约定；全局边界见根 `AGENTS.md`。

## Layout

- `module.prop` — `version` / `versionCode`（发版升号在这里）
- `service.sh` / `boot-completed.sh` — 启动胶水（薄）
- `bin/bgfreeze` — Rust 产物（勿手改二进制语义；改源在 `daemon/`）
- `bin/apps.sh` — WebUI / CLI 胶水
- `webroot/` — WebUI

## Local rules

- WebUI **禁止**每包一次 `dumpsys package`；列表一次 dumpsys + cache；图标并发限流（见 `docs/UX.md` / `docs/PERF_LIST.md`）。
- `set-mode disable` 无 `allow-disable` 必须拒绝。
- 开机无 `allow-disable` + `allow-disable-on-boot` 时强制 `mode=stop`（`service.sh`）。
- 打包从仓库根：`bash scripts/pack.sh`。
