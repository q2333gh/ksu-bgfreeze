# module/（KernelSU zip 根）

叶子约定；全局边界与发版链见根 `AGENTS.md` · `docs/workflows/ship.md`。

## Layout

| 路径 | 作用 |
|------|------|
| `module.prop` | `version` / `versionCode`（升号只改这里 + CHANGELOG + Cargo） |
| `service.sh` / `boot-completed.sh` | 启动胶水（薄） |
| `action.sh` | KernelSU「执行」；O(1) 停/启 daemon |
| `bin/bgfreeze` | Rust 产物（语义改源在 `daemon/`） |
| `bin/apps.sh` | WebUI / CLI 胶水 |
| `bin/tombstone-lib.sh` | Hail/进程辅助（Binder 缓存 + timeout） |
| `webroot/` | WebUI（`app.js` / `index.html` / `style.css`） |

## `apps.sh` 子命令（机内）

| 命令 | 用途 |
|------|------|
| `snapshot` / `get-mode` / `set-mode` / `set-blacklist` | WebUI 主路径 |
| `status` | `prop`/`binary`/`ui`/`aligned`/`disabled`/`panic` |
| `hot-update <zip\|dir>` | **唯一**推荐热更；缺 `bgfreeze` 等则 REFUSE |
| `enable` | 清 `disable`/`panic` 并重启 daemon |
| `emergency` | 软恢复（不清模块 disable） |
| `panic` | 硬停 + sticky disable；恢复靠 `enable`/`hot-update` |
| `restart` / `circuit-status` / `circuit-clear` | 运维 |

热更 bootstrap（已装版本过旧、无 `hot-update` 时）：

```bash
ZIP=…/ksu-bgfreeze-N-vX.Y.Z.zip
W=/data/local/tmp/ksu-hot
rm -rf "$W" && unzip -o "$ZIP" -d "$W"
sh "$W/bin/apps.sh" hot-update "$ZIP"
sh /data/adb/modules/ksu-bgfreeze/bin/apps.sh status   # aligned=1
```

## Local rules

- WebUI **禁止**每包 `dumpsys package`；列表走 snapshot + `labels.cache`；图标限流（`docs/UX.md` / `docs/PERF_LIST.md`）。
- **禁止** `apps.sh` / `action.sh` 热路径全表扫 `/proc`；停 daemon：pidfile + `/proc/$pid/cmdline` + flock。
- Binder：`/system/bin/pm|am` + `timeout`；`pm list -d` 每操作 ≤1 次（tombstone-lib 缓存）。
- `emergency` 禁整机 `pm enable`；只 revive 本模块 tombstone；**勿**留 `module/disable`（挡热更）。硬停 → `panic`。
- **热更必须完整 zip**（`hot-update`）；禁只拷 `apps.sh`/`webroot`。
- `set-mode disable` 无 `allow-disable` → 拒绝。
- 开机无双 allow 文件 → 强制 `mode=stop`（`service.sh`）。
- 打包：仓库根 `bash scripts/pack.sh`；说明：`bash scripts/hot-update.sh`。
