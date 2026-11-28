# AGENTS.md — ksu-bgfreeze

给自动化 Agent 的操作说明。人类可读总览见 `README.md`；云朵合规台账见 `docs/CLOUD_RELEASE.md`。

## 仓库身份

| 项 | 值 |
|----|-----|
| 模块 `id` | `ksu-bgfreeze`（`module/module.prop` 与根目录 `module.yaml` 必须一致，上架后**不可改**） |
| 公开发版仓库 | https://github.com/q2333gh/ksu-bgfreeze （`main`） |
| 云朵门户 | https://developers.kernelsu.org/ |
| 官方发版文档 | https://developers.kernelsu.org/docs/zh-CN/releasing |
| 官方上架文档 | https://developers.kernelsu.org/docs/zh-CN/getting-started |

本工作区若是 Origin 镜像，**发版与 Actions 以 GitHub 仓为准**。本机无 `gh` 凭证时，用已授权的 **`daily_env1`** 环境推送到 `q2333gh/ksu-bgfreeze`：该环境**已有可用的 GitHub token / `gh` 登录**，子 Agent 应直接 `gh auth status` 后 `git push` / `gh`，不要再向用户要 token，也不要假设当前 Origin VM shell 能直接 `gh release`。

## 硬约束（违反会浪费 versionCode / tag）

1. **只发 immutable Release**。仓库已开 Release immutability；资源一旦发布不可替换、不可删改 zip、tag 不可复用。
2. **正确顺序**：draft → 上传 zip → 发布。禁止先发布再补资源。一律走 CI 的 `module-release`，不要手搓残缺 release。
3. **每个 release 恰好 1 个模块 zip**。CI 会命名为 `{id}-{versionCode}-{version}.zip`。
4. **`versionCode` 必须严格递增**（正十进制 int32）。云朵记住历史最高值：删除 release 也不能回退号段。
5. **出错只能发更高 `versionCode` 的新 tag**，不能“修”已发布的 immutable release。
6. **不要**在 PR/`main` 上对已发布号段跑 `module-release` dry-run 当门禁——会对当前 `versionCode` 报 `version-not-newer`。结构门禁用 `.github/workflows/precheck.yml`。
7. **不要**改已上架的 `id`；不要把 zip 上传到 modules.kernelsu.org（云朵只索引 GitHub immutable release）。
8. **不要**新建 PR 来完成发版；发版是 push `main` + push `v*` tag。

## 硬约束：系统级编程安全（privileged daemon —— 违反可锁机 / Watchdog）

本模块是 **Android/Linux 特权用户态系统编程**（root 常驻、扫 `/proc`、`kill`、经 `am`/`pm` 打 Binder），**不是**普通 App。改 `daemon/`、`module/bin/`、启动脚本、冻结语义前必须遵守；做 code review / 架构改动时先读本节，不够再打开下方「长手册」。

详细审查与缺口对照见 [`docs/SYSTEMS_PROGRAMMING_REVIEW.md`](docs/SYSTEMS_PROGRAMMING_REVIEW.md)；Big-O 见 [`docs/BIG_O_ANALYSIS.md`](docs/BIG_O_ANALYSIS.md)。

### 强制准则（默认必须遵守）

1. **失败默认安全**：不确定就不冻结 / 不 `pm disable`；Binder/`pm`/`am` 失败 → **立刻熔断**（写 `circuit.open`、回落 `mode=stop`），**禁止**紧循环重试或「再试几次」拖垮 `system_server`。
2. **单实例**：daemon 必须以 `flock`（或等价互斥）为唯一权威；抢不到锁 → 退出。禁止靠 pidfile  alone 防双开；禁止 `pkill -f` 误伤无关进程。
3. **作用域最小**：只动黑名单包对应 **app uid（≥10000）**；永不对 `uid<10000`、SystemUI/电话/输入法/启动器/OEM 核心/`pm disable` 关键前缀列表动手。`disable` 模式默认关；开机无 `allow-disable-on-boot` 时强制 `mode=stop`。
4. **PID TOCTOU**：凡对 pid 发信号或写入 cgroup，**使用前必须再确认该 pid 仍属目标 uid**（或改用按 uid 的 `cgroup.freeze`，避免按 pid 操作）。禁止「扫一遍 `/proc` 后无复核就 `kill`」。
5. **Binder / IPC 预算**：对 `dumpsys` / `am` / `pm` 设硬上限——每轮至多有限次数；子进程必须有 **超时 + 输出字节帽**；exec 用 **绝对路径**（如 `/system/bin/pm`）。禁止热路径 shell 循环、`awk` 每 pid、每包一次全表 `ps`。
6. **热路径复杂度**：进程枚举每轮 **Θ(T) 一次** 共享快照（或更优的 uid cgroup / 事件驱动）；黑名单决策 **Θ(N+P)**。禁止回退到 **Θ(N·T)** 全表×每包扫描或 per-pid fork。
7. **可杀、可回滚、可观测**：保留模块 `disable`、`panic`、emergency thaw；每次强制副作用打结构化日志（pkg/uid/pid/rc/binder_fail）；离开 `disable` 模式必须 revive。
8. **冻结原语升级纪律**：SIGSTOP → cgroup freezer →（可选）Binder freeze 必须 **分步、可关、可回退**；不得在未熔断/未 kill-switch 的情况下引入新的全机副作用路径。完整墓碑语义见 AOSP/Freezeit：**freezer + binder freeze**；我们未具备后者时不得宣称「完整冻结」。

### 何时打开长手册 / 外链（需要更多准则或做 review 时）

| 场景 | 先读仓库内 | 再读外链 |
|------|------------|----------|
| 改 daemon / 信号 / `/proc` / 锁 | `docs/SYSTEMS_PROGRAMMING_REVIEW.md` | TLDP Race/TOCTOU（下表） |
| 引入或评审 cgroup 冻结 | 同上 §C7 + OP12 路径备注 | Kernel cgroup v2 freezer |
| Binder/`pm`/`am` 或「会不会再次卡死」 | 事故文 `docs/INCIDENT_*` + Review §C3 | AOSP Cached apps freezer |
| 复杂度 / 性能回归 review | `docs/BIG_O_ANALYSIS.md` | — |
| 对照业界墓碑实现 | Review §业界对照 | Freezeit 文档；Hail README |

**外链（权威 / 长手册）——Agent 在 review 或设计新冻结路径时按需深入：**

- TLDP Secure Programming HOWTO — Race Conditions / TOCTOU：https://tldp.org/HOWTO/Secure-Programs-HOWTO/avoid-race.html
- Linux 内核文档 — cgroup v2（`cgroup.freeze`）：https://docs.kernel.org/admin-guide/cgroup-v2.html
- Linux 内核文档 — cgroup v1 freezer（SIGSTOP 为何不够）：https://docs.kernel.org/admin-guide/cgroup-v1/freezer-subsystem.html
- AOSP — Cached apps freezer：https://source.android.com/docs/core/perf/cached-apps-freezer
- man kill(2)：https://man7.org/linux/man-pages/man2/kill.2.html
- man signal(7)：https://man7.org/linux/man-pages/man7/signal.7.html
- Hail（pm disable / 工作模式，非进程 freezer）：https://github.com/aistra0528/Hail/blob/master/README.zh_CN.md
- Freezeit 实践说明（V1/V2/SIGSTOP 与 Binder freeze 陷阱）：https://jark006.github.io/Freezeit/

**Review 检查清单（改动涉及进程控制或 Binder 时，回复用户前自检）：**

- [ ] 有无新的每 pid / 每包全表扫描或重试风暴？
- [ ] `kill`/cgroup 写入前是否复核身份或按 uid 作用？
- [ ] 失败是否 fail-fast + 熔断，而非盲重试？
- [ ] 是否仍保持 flock、kill-switch、默认 `stop`？
- [ ] 日志能否定位误伤包 / binder 失败？

## 目录与 CI

```
daemon/                 # Rust 源码（bgfreeze）；交叉编译 → module/bin/bgfreeze
module/                 # ZIP 根内容（module.prop、service.sh、webroot/…）
module.yaml             # 云朵元数据；description → README.md
CHANGELOG.md            # Release notes（CI 读这个）
scripts/pack.sh         # 本地打包 → dist/；不发版
scripts/build-daemon.sh # aarch64 musl 交叉编译 daemon
.github/workflows/
  release.yml           # push tags v* → 官方 module-release（pin SHA）；先编 Rust
  precheck.yml          # main/PR：编 Rust + prop/yaml + pack.sh（ubuntu-latest）
docs/CLOUD_RELEASE.md   # 云朵流程合规台账（给人看）
docs/SYSTEMS_PROGRAMMING_REVIEW.md  # 系统级安全审查（Agent 强制准则的长文）
docs/BIG_O_ANALYSIS.md  # 关键路径复杂度
```

`release.yml` 固定使用：

`KernelSU-Modules/tools/actions/module-release@424471eacf6c0bd00e8e3708980f6b1882b5bf33`

升级 action 时必须 pin **完整 commit SHA**，并先在 workflow_dispatch + `dry_run=true` 验证。

## 标准发版流程（Agent 按序执行）

适用：模块已在 Portal 提交过（首次需人审；通过后后续版本自动进云朵）。

### 0. 前置检查

- [ ] GitHub `main` 与要发的代码一致（Origin 有改动则先同步到 GitHub `main`）
- [ ] `gh release view v0.3.1 -R q2333gh/ksu-bgfreeze --json isImmutable,assets`（或 API）确认历史 immutable 仍健康
- [ ] 读最新已接受 `versionCode`（看最新成功 Check Run / 最新 immutable release 的 `module.prop`）
- [ ] 不创建 tag，直到 prop / CHANGELOG / main 都已推送

### 1. 改版本

编辑 `module/module.prop`：

- `version`：展示用，建议 `vX.Y.Z`，与即将打的 tag 一致
- `versionCode`：整数，**必须 > 云朵曾接受的最大值**（当前基线：`301` = `v0.3.1`）

### 2. 写更新日志

在 `CHANGELOG.md` **顶部**追加一节（CI 整文件作为 release notes）：

```markdown
## vX.Y.Z

- 用户可见的变更要点
```

### 3. 本地校验（可选但推荐）

```bash
bash scripts/pack.sh
# 确认 dist/ksu-bgfreeze-vX.Y.Z.zip 可解压且含 module.prop
```

### 4. 提交并推到 GitHub `main`

```bash
git add module/module.prop CHANGELOG.md
# 若还有功能改动一并加入
git commit -m "Release vX.Y.Z (versionCode N)"
git push origin main
```

若当前远程是 Origin：把同一 commit 推到 `https://github.com/q2333gh/ksu-bgfreeze` 的 `main`（常用 `daily_env1` + `gh`/`git`）。

等 GitHub Actions **Precheck** 变绿：  
https://github.com/q2333gh/ksu-bgfreeze/actions

### 5. 打 tag 触发正式发版

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

tag 必须在**已包含新 versionCode 的 commit**上。推送后看 **Release** workflow：

- 成功：出现 immutable release，asset 形如 `ksu-bgfreeze-N-vX.Y.Z.zip`
- 失败：不要复用该 tag；修代码后升 `versionCode`，用**新 tag**再发

### 6. 发版后复核

```bash
gh release view vX.Y.Z -R q2333gh/ksu-bgfreeze --json isImmutable,tagName,assets,url
gh api repos/q2333gh/ksu-bgfreeze/commits/vX.Y.Z/check-runs \
  --jq '.check_runs[]|{name,conclusion,title:.output.title}'
```

期望：

- `isImmutable: true`
- 恰好一个模块 zip
- Check Run `KernelSU Modules` → success（`vX.Y.Z (N) is valid`）
- 上架后数分钟内云朵自动同步（无需再审）

### 7. 禁止事项复查

- [ ] 没有手改已发布 release 的 asset
- [ ] 没有 `git tag -f` / 移动旧 tag
- [ ] 没有复用失败过的 `versionCode`
- [ ] 没有把仅本地 `dist/*.zip` 当成已发版

## 仅打包、不发版

```bash
./scripts/pack.sh
```

产出在 `dist/`。不要把 `dist/` 里的 zip 手动 `gh release upload` 到已 published 的 immutable release。

## 手动 dry-run（不发布）

GitHub → Actions → **Release** → Run workflow → 勾选 `dry_run`。  
用于验证 action / 打包；**不能**代替 tag 发版。

## 首次上架（一般已完成，勿重复）

一次性人工/半自动步骤（详见 `docs/CLOUD_RELEASE.md`）：

1. 公开仓 + Enable release immutability  
2. 根目录 `module.yaml`  
3. 安装 KernelSU Modules GitHub App  
4. Portal 预检无错误  
5. 发布首个 immutable release  
6. Portal「提交审核」（GitHub 账号注册满 1 年）  
7. 状态 Pending review → 通过后出现在 modules.kernelsu.org  

Agent **不要**重复提交收录；人审期间只修 Check Run 报错或按需发更高 versionCode。

## 上架后可选

在 `module/module.prop` 增加（需新 versionCode 发版才进包内）：

```properties
updateJson=https://modules.kernelsu.org/api/v1/modules/ksu-bgfreeze/update.json
```

## 故障速查

| 现象 | 处理 |
|------|------|
| `version-not-newer` | 提高 `versionCode`，新 tag |
| release 非 immutable | 确认仓库 immutability；用 action 发，勿先 publish 再上传 |
| zip 校验失败 | 修 `module/` 后升 versionCode 重发；旧 tag 作废 |
| tag 已推但 workflow 挂了 | 修 main → **新** versionCode + **新** tag |
| Precheck 红 | 看 prop/yaml/`pack.sh`；与云朵 version 比较无关 |
| 只有 Origin 有提交 | 同步到 GitHub `main` 再打 tag |

## 冻结语义（Agent 勿回退）

- 默认 **`mode=stop`**：黑名单包退后台 ≥3s 后，对该 uid 进程 `SIGSTOP`（Rust `module/bin/bgfreeze`）；前台 `SIGCONT`
- **`mode=disable`**（Hail）：单次 `am force-stop` + `pm disable` + 校验；失败 cooldown / circuit；**禁止**重试风暴与 SIGSTOP 兜底洪水
- 每轮 **一次** 进程快照（Θ(T)），禁止 per-pid awk / 每包全表 `ps`
- 对方保活拉起记 **`WAKE`**；控制器是 `bgfreeze`（`bgfreeze-daemon.sh` 仅兼容启动器）
- 日志：`/data/local/tmp/ksu-bgfreeze.log`（`apps.sh log`）

## WebUI 性能（Agent 勿回退）

- **禁止**对每个包各跑一次 `dumpsys package`（曾导致 ~20s）
- 列表：一次 `dumpsys package` → `labels.cache`（24h）+ `pm list packages -3`
- 图标：列表先渲染；`ICON_CONCURRENCY=2` 排队拉取

## 改代码时的默认习惯

- 功能改动：Rust 在 `daemon/`，打包产物 `module/bin/bgfreeze`；胶水/WebUI 在 `module/`；说明在 `README.md` / `docs/`
- 改进程控制或 Binder 路径时：**先满足「硬约束：系统级编程安全」**，再提交；需要论据或做 review 时打开该节「长手册 / 外链」
- 保持黑名单-only：名单外零干预
- 发版相关流程变更时，同步更新本文件与 `docs/CLOUD_RELEASE.md`
- 交叉编译：`bash scripts/build-daemon.sh`（需 aarch64-linux-musl）；CI 在 `ubuntu-latest` 上同样执行
