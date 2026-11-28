# WebUI 应用列表：大 O 性能分析

设：

| 符号 | 含义 | 本机量级 |
|------|------|----------|
| \(n\) | 第三方包数（`pm list packages -3`） | ≈ 60–100 |
| \(m\) | 黑名单行数 | ≈ 1–10 |
| \(k\) | 视口内可见行数 | ≈ 8–15 |
| \(T_{\mathrm{exec}}\) | 一次 `ksu.exec` 往返（起 shell + IPC） | 数十～数百 ms |
| \(T_{\mathrm{icon}}\) | `pm path` + `unzip` 抽图标 | 约 50–200 ms |
| \(T_{\mathrm{aapt}}\) | `aapt dump badging` 一包 | 约 100–500 ms |

---

## 1. 壳层 `apps.sh list`（数据路径）

| 步骤 | 复杂度 | 说明 |
|------|--------|------|
| `pm list packages -3` | \(O(P)\) | \(P\) 为包管理器扫描规模；输出 \(n\) 行 |
| `sed` + `sort -u` | \(O(n \log n)\) | 写 `pkgs.tmp` |
| `awk` 与 `labels.cache` 一次 join | \(O(n + L)\) | \(L\) 为缓存行数；**禁止**再对每包起 awk |

**合计：\(O(n \log n)\)**，常数小。实测纯 shell ≈ **0.07–0.1 s**，不是 8 s 量级。

`get-blacklist`：**\(O(m)\)**，可忽略。

---

## 2. WebUI `boot()`（用户感知的「读取应用列表」）

```
状态「读取应用列表…」 → Promise.all(list, get-blacklist) → parse → render
```

| 步骤 | 复杂度 | 墙钟 |
|------|--------|------|
| 2× `ksu.exec` | \(O(1)\) 次调用，载荷 \(O(n)\) | 应 ≈ shell 时间 + \(2 T_{\mathrm{exec}}\) |
| `parseList` + `localeCompare` 排序 | \(O(n \log n)\) | < 10 ms |
| `render` 建 DOM | \(O(n)\) | < 50 ms |

若状态栏卡在「读取应用列表…」接近 **8 s**，而 shell `list` 只有 ~0.1 s，则瓶颈在：

1. **机上模块仍是旧 `list`（每包 dumpsys / 每包 awk）** → 旧实现约 \(O(n \cdot T_{\mathrm{dumpsys}})\) 或 \(O(n)\) 次进程，可达数秒～二十秒；或  
2. **首次 `ksu.exec` 冷启动**（与 \(n\) 无关的 \(O(1)\) 大常数）。

---

## 3. 图标队列（首屏之后的隐形 \(O(n)\)）

旧逻辑：`render` 后对**每一行** `enqueueIcon` → `apps.sh icon <pkg>`。

\[
T_{\mathrm{icons}} \approx \frac{n}{C}\,(T_{\mathrm{exec}} + T_{\mathrm{icon}}),\quad C=2
\]

例：\(n=70\)，\(T_{\mathrm{exec}}+T_{\mathrm{icon}}\approx 200\,\mathrm{ms}\) → **≈ 7 s**。

**复杂度：\(O(n)\) 次 `ksu.exec`** —— 与「列表还要再等七八秒」同量级。  
UI 壳秒开、名单却要等很久，常被体感成「读列表慢」，实际是**全量图标拉取**。

优化后（IntersectionObserver）：只对进入视口的行拉图标 → **\(O(k)\)** 次 exec，首屏约 1–2 s 内出齐图标，滚动再按需补。

---

## 4. 后台 `refresh-labels`（有 aapt 时）

对每包：`pm path` + `aapt dump badging`：

\[
T_{\mathrm{labels}} = \Theta(n \cdot T_{\mathrm{aapt}})
\]

例：\(n=70 \times 200\,\mathrm{ms}\) → **≈ 14 s**。  
若 `ksu.exec` **串行**，会与图标抢同一通道，进一步拉长体感。

无 aapt（常见）：循环几乎空转，\(O(n)\) 但常数极小；然后 `list` 仍显示包名。

策略：首屏列表与图标完成后再延迟触发；或用户手动刷新名称。

---

## 5. 总览（主导项）

| 路径 | 大 O | 是否解释 ~8 s |
|------|------|----------------|
| 当前 shell `list` | \(O(n \log n)\) | 否（~0.1 s） |
| 旧每包 dumpsys/`awk` | \(O(n \cdot c)\)，\(c\) 大 | 是 |
| 全量图标 | \(O(n)\) × \(T_{\mathrm{exec}}\) | **是（最可疑）** |
| aapt 刷名称 | \(O(n \cdot T_{\mathrm{aapt}})\) | 是（后台，可抢 exec） |
| DOM / 排序 | \(O(n \log n)\) | 否 |

**结论：** 算法上名单本身已是 \(O(n \log n)\)；接近 8 s 的墙钟时间由 **\(O(n)\) 次 root exec（图标，及可能的 refresh-labels）** 主导，不是 `pm list` 本身。

---

## 6. 已落地（v0.3.3）：为什么别人能「秒开」

系统设置 / IceBox / KernelSU Manager 等是 **原生 App**：一次 `PackageManager` Binder 拿到 label+icon，**零 shell**。

本模块是 WebUI + `ksu.exec`，对齐策略：

| 手段 | 效果 |
|------|------|
| `localStorage` 上次 snapshot | **再次打开 0ms 出列表**，再后台 revalidate |
| 单次 `apps.sh snapshot` | 1× exec，含黑名单+是否有图标 |
| 图标写到 `webroot/icons/*.png` | `<img src="icons/pkg.png">`，**HTTP 静态资源**，不做 per-pkg exec |
| `cache-icons` / `refresh-labels` idle | 不挡首屏 |

打开复杂度：首屏数据 **\(O(1)\) 次 exec**；图标 **\(O(k)\) HTTP**（或缓存命中）。  

## 7. 仍可继续

1. 预编译 tiny JNI/`app_process` 调 PM（真正对齐系统列表）  
2. 合并图标 API batch（若不能写 webroot）  
3. 确认机上已装含 `snapshot` 的模块版本 
