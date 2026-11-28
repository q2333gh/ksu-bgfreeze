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
- **禁止**在 `apps.sh` / `action.sh` 热路径全表扫 `/proc`；停 daemon：pidfile + `/proc/$pid/cmdline` 身份核对 + flock。
- Binder：`pm`/`am` 走 `/system/bin/timeout`；`pm list -d` 每操作至多一次（tombstone-lib 缓存）。
- `emergency` **禁止**对整机所有 disabled 包 `pm enable`；只 revive 本模块 tombstone 标记；**不要**留 `module/disable`（那会挡后续热更）。硬停用 `panic`；恢复用 `enable` / `hot-update`。
- **热更必须完整 zip**：`apps.sh hot-update <zip>`（校验 `bgfreeze`+脚本+webroot，原子安装，清 disable/panic，restart，核对 `prop==binary`）。禁止只拷 `apps.sh`/`webroot`。
- `set-mode disable` 无 `allow-disable` 必须拒绝。
- 开机无 `allow-disable` + `allow-disable-on-boot` 时强制 `mode=stop`（`service.sh`）。
- 打包从仓库根：`bash scripts/pack.sh`；机内热更说明：`bash scripts/hot-update.sh`。

