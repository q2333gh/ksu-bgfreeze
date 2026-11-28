# 事故笔记：OP12 触控/按键失灵、疑似卡在 boot（2026-11-28）

时区：Asia/Taipei (UTC+8)

## 现象（用户反馈）

1. 无法触控，物理按键（含电源）似乎无效。
2. 屏幕停在类似 boot / 开机动画阶段。
3. **按住电源键约 60 秒无反应**（强制重启失败）。
4. 事故前：USB 连接 OP12 时 Windows 有插入提示音；**事故后 / 修复尝试后：插线无 USB 声音**（主机侧听不到枚举）。

## 时间线与我方操作（导致风险的操作）

仓库当时为 `ksu-bgfreeze`（后台冻结模块）。为模仿 [Hail](https://github.com/aistra0528/Hail) 整包冻结，做了热更与实机试验。

### A. 代码层面改动（意图）

- 将「墓碑」从**组件级** `pm disable` 洪水，改为 Hail 风格：
  - `am force-stop <pkg>`
  - **整包** `pm disable --user <N> <pkg>`
- 模式文件：`/data/adb/ksu-bgfreeze/mode` → `disable`
- 黑名单曾包含：`com.tencent.android.qqdownloader`（应用宝）
- WebUI 增加「打开」= enable + monkey/am 启动

### B. 实机热更与进程操作（高风险段）

通过 Termux MCP `run_root` / `run_command` + `su`：

1. **覆盖模块文件**到 `/data/adb/modules/ksu-bgfreeze/`（`tombstone-lib.sh`、`bgfreeze-daemon.sh`、`apps.sh`、WebUI 等）。
2. 写入 `mode=disable`，黑名单保留应用宝。
3. **清理状态文件**：`tombstone.*` / `frozen.*` / `bg.*` / `watch.*` / 旧 `comps-*`。
4. 对应用宝执行 **`pm enable` / `pm disable --user 0`** 手工验证；曾确认 `enabled=2`（整包停用成功）。
5. **多次重启冻结守护进程** `bgfreeze-daemon.sh`：
   - `kill` / 扫描 `/proc/*/cmdline` 匹配 `bgfreeze-daemon.sh` 后杀进程
   - 至少一次使用 **`kill -9`** 结束旧 daemon PID
   - `setsid ... bgfreeze-daemon.sh &` 后台拉起
6. 曾出现 **双 daemon**（例如 pid 13586 与 17061 同时存在）互相抢状态。
7. 守护进程在 `mode=disable` 下会周期性：
   - 对黑名单包 `force-stop` + `pm disable`
   - 若失败则 **`kill -STOP`（SIGSTOP）该 UID 下全部进程**（fallback）
8. 热更过程中 **OP12 MCP / frpc 多次掉线**；其后用户反馈整机失控。

### C. 事故后抢救尝试（未成功连上设备）

- 电脑 ADB：`adb devices` **空列表**。
- 无法执行 planned recover：`touch .../disable`、清空黑名单、`pm enable` 全部 `-d` 包。
- 仓库已追加安全补丁（杀开关、开机强制 stop、延迟 45s、拒绝关键包、`emergency` 命令），但**未能写入当时那台已卡死的手机**。

## 可能机制（推断，非已证实根因）

| 假设 | 说明 | 与「无 USB 声 / 电源无效」关系 |
|------|------|-------------------------------|
| A. 软锁在 Android 层 | SystemUI/输入被冻或死锁，但 SoC 仍运行 | 电源长按**通常仍有效**；USB 常仍会枚举 → 与现状不完全吻合 |
| B. 更深的 hang / 内核或电源管理异常 | 用户空间杀进程 + 反复 pm/am/dumpsys 加重负载；frpc/su 会话异常 | 可能导致长按电源无效、USB 不枚举 |
| C. 已掉电 / 电池保护 | 卡在亮屏耗电或假死直至关机 | **无 USB 声**常见于完全没电或未上电 |
| D. 模块误伤系统包 | 设计上黑名单仅应用宝；有 dumpsys 误判 `auto-clear` bug，但不应 disable SystemUI | 低概率，除非黑名单被污染（日志未见） |
| E. 硬件/线材巧合 | 线、口、驱动 | 需换线换口验证 |

**当前更符合「设备未真正上电或 USB 子系统未起来」**：60s 电源无效 + 无 USB 枚举提示音。

## 明确做过、且应记为危险的操作

1. 在用户日常机上对运行中系统做 **整包 `pm disable` 试验**（应用宝）。
2. **`kill -9` / 批量按 cmdline 杀脚本进程**（可能波及异常 shell 会话；曾伴随 MCP 掉线）。
3. **双实例 daemon** + SIGSTOP fallback 对用户 UID 进程发信号。
4. 在 MCP 不稳定时继续热更/重启 daemon，缺少「一键 panic 停模块」落地到机内。

## 未做过（就已知命令而言）

- 未执行 `fastboot oem` / 刷机 / 改分区。
- 未故意 `pm disable` SystemUI / launcher / `android`。
- 未改 Bootloader 锁。

## 恢复路径（按优先级）

### 1. 先当「没电 / 未上电」处理

- 换 **原装或已知可充电线** + **墙充（不是只靠 PC USB）** 充 **30–60 分钟**（黑屏也可充）。
- 充电时看：充电灯/屏幕微亮/电脑是否重新出现 USB 声。
- 再试：电源键短按；或 **音量上+电源** / **音量下+电源**（OP12 Fastboot 多为音量下+电源）。

### 2. 电脑侧确认是否完全无枚举

插上手机后在 Windows：

```powershell
# 设备管理器里看是否有 Unknown / Android / QUSB / EDL
Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Android|QUSB|EDL|OnePlus|ADB|Qualcomm' } | Format-Table Status,Class,FriendlyName
adb devices
fastboot devices
```

- 有 **Qualcomm HS-USB QDLoader 9008** → EDL，需官方/深度救砖工具（勿乱刷）。
- 有 Fastboot 设备 → `fastboot reboot` / recovery，并禁用模块目录。
- 完全无新设备 → 继续充电、换线换口、换电脑。

### 3. 一旦 ADB 恢复（立刻执行）

```sh
su -c 'touch /data/adb/modules/ksu-bgfreeze/disable
echo stop > /data/adb/ksu-bgfreeze/mode
: > /data/adb/ksu-bgfreeze/blacklist.txt
for st in /proc/[0-9]*/cmdline; do
  tr "\0" " " < "$st" 2>/dev/null | grep -q bgfreeze-daemon && kill -9 ${st#/proc/}${st%/cmdline}
done
pm list packages -d | sed "s/package://" | while read p; do pm enable --user 0 "$p"; done'
```

或：`su -c 'sh /data/adb/modules/ksu-bgfreeze/bin/apps.sh emergency'`（需已刷含该命令的版本）。

### 4. 售后

若充电数小时仍：**电源无效 + 无充电指示 + 无 USB 枚举** → 按硬件/深度软砖走售后或官方救援，不要再对机子做模块热更。

## 后续工程约束（已部分合入 main）

- 开机默认 `mode=stop`；无 `allow-disable-on-boot` 不在开机用 disable。
- `service.sh` 延迟 ~45s 再启 daemon。
- 存在 `modules/ksu-bgfreeze/disable` 或 `ksu-bgfreeze/panic` 则退出。
- 拒绝对 critical / OPlus / SystemUI 等包做 disable。
- **禁止**在用户唯一日用机上对 `pm disable` 做未经验证的批量试验；先模拟器/备用机。

## 相关提交（本仓库）

- Hail 整包冻结：v0.4.0 一带
- 安全补丁：`Safety: kill-switch, delay boot freeze, refuse critical pkgs`（事故后，可能未装到卡死机）

## Root cause（2026-11-28 深挖）

### 事故正点证据

| 时刻 | 证据 |
|------|------|
| 00:31:18 | dropbox `system_server_pre_watchdog`：`StorageManagerService.monitor` → `IVold.monitor` binder **卡住 15s** |
| 00:32:15 | dropbox `system_server_watchdog`：同一路径 **卡住 72s** → 正式 Watchdog |
| 同时 | CPU pressure avg10≈43%；采样 Firefox 很高，`system_server` 也忙 |
| sulog `2026-11-28-1` | **34732 行中 31729 来自 `bgfreeze-daemon`（~91%）**；`awk /^Uid:` **29070** 次；`pm` **1142** 次 |

Watchdog 栈要点：`watchdog.monitor` → `StorageManagerService.monitor` → `IVold.monitor` → `BinderProxy.transactNative`（**vold 无响应/ binder 堵死**），不是简单 Java 锁互等。

### 我方软件缺陷（因果链）

1. **`each_pid` / `snap_uid` / `freeze_uid`：对每个 `/proc/[pid]/status` fork 一次 `awk`**  
   → 每轮轮询 O(全机进程数) 次 exec；双 daemon 翻倍 → sulog 里海量 `awk`。
2. **`mode=disable` 失败重试风暴**：`dumpsys package` + 多次 `pm disable*` + `pm list -d`；误判 `auto-clear` 后又冻 → PackageManager **`Failed transaction`**。
3. **无单实例锁**：日志连续 `start pid=`（13586/17061/20775…）多守护进程并存。
4. **热更/杀进程操作**加剧多实例与抖动。

**Root cause 一句话：**  
bgfreeze 以 shell 全表扫描 + 高频 `pm`/`dumpsys`（多实例）打爆 binder/CPU，拖死 vold 健康检查，触发 **system_server Watchdog**，表现为红点卡死与按键失灵。应用宝 `pm disable` 是负载来源之一，不是唯一根因；**进程表 awk 风暴 + 多 daemon** 才是结构性毒瘤。

### 修复方向（代码，尚未必然已全部合入机内运行路径）

- 禁止全 `/proc` + 每 pid fork awk；改用 `pidof` / 按 uid 目录或一次 awk 批处理  
- 强制单实例（pidfile + flock）  
- disable 模式严格限流/熔断；失败不得紧循环  
- 开机默认 stop + 模块 disable 杀开关（已部分落地）

## 修复执行记录（2026-11-28 ≈07:55 CST，用户批准「全部执行」）

只读确认后执行（未启用模块）：

1. 保留 `modules/ksu-bgfreeze/disable`
2. `mode=stop`；黑名单清空
3. 清除 tombstone/frozen/bg/watch/hail-err/daemon.pid
4. `pm enable --user 0 com.tencent.android.qqdownloader` → `enabled=1`
5. 热更安全版 `service.sh` / `boot-completed.sh` / `tombstone-lib.sh` / `daemon` / `apps.sh`
6. **不**创建 `allow-disable-on-boot`；**不**删除 `disable`；daemon 未运行
7. 未改动其它 `enabled=3` 用户停用包；未动 altdb/droidbridge 的 disable
