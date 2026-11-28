(() => {
  "use strict";

  const MOD = "/data/adb/modules/ksu-bgfreeze";
  const SH = "sh " + MOD + "/bin/apps.sh";
  const CACHE_KEY = "bgf_snapshot_v3";

  const statusEl = document.getElementById("status");
  const hintEl = document.getElementById("hint");
  const qEl = document.getElementById("q");
  const frozenList = document.getElementById("frozenList");
  const allList = document.getElementById("allList");
  const frozenEmpty = document.getElementById("frozenEmpty");
  const frozenCount = document.getElementById("frozenCount");
  const allCount = document.getElementById("allCount");
  const btnApply = document.getElementById("btnApply");
  const btnReload = document.getElementById("btnReload");
  const btnMode = document.getElementById("btnMode");
  const modeStop = document.getElementById("modeStop");
  const modeDisable = document.getElementById("modeDisable");

  let apps = [];
  let filter = "";
  let mode = "stop";
  let iconGen = 0;
  let listMs = 0;
  let busy = false;

  function setStatus(t) {
    if (statusEl) statusEl.textContent = t || "";
  }

  function toast(msg) {
    try {
      if (window.ksu && typeof ksu.toast === "function") ksu.toast(msg);
      else setStatus(msg);
    } catch (_) {
      setStatus(msg);
    }
  }

  /** Activate handler: click + touchend (KernelSU WebView often drops click). */
  function bindTap(el, fn) {
    if (!el) return;
    let lock = false;
    const run = (e) => {
      if (lock || busy) return;
      if (e) {
        try { e.preventDefault(); } catch (_) {}
      }
      lock = true;
      Promise.resolve()
        .then(() => fn(e))
        .catch((err) => setStatus(String(err && err.message ? err.message : err)))
        .then(() => {
          setTimeout(() => { lock = false; }, 300);
        });
    };
    el.addEventListener("click", run);
    el.addEventListener(
      "touchend",
      (e) => {
        run(e);
      },
      { passive: false }
    );
  }

  function exec(cmd, timeoutMs) {
    const ms = timeoutMs || 25000;
    return new Promise((resolve, reject) => {
      if (!window.ksu || typeof ksu.exec !== "function") {
        reject(new Error("请用 KernelSU 打开本模块 WebUI"));
        return;
      }
      const cb = "_bgf_" + Math.random().toString(36).slice(2);
      let done = false;
      const timer = setTimeout(() => {
        if (done) return;
        done = true;
        try { delete window[cb]; } catch (_) {}
        reject(new Error("超时"));
      }, ms);
      window[cb] = (errno, stdout, stderr) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        try { delete window[cb]; } catch (_) {}
        if (errno === 0 || errno === "0") resolve(stdout || "");
        else reject(new Error(stderr || stdout || String(errno)));
      };
      try {
        ksu.exec(cmd, "{}", cb);
      } catch (e1) {
        try {
          ksu.exec(cmd, cb);
        } catch (e2) {
          clearTimeout(timer);
          done = true;
          reject(e2 || e1);
        }
      }
    });
  }

  function colorFor(pkg) {
    let h = 0;
    for (let i = 0; i < pkg.length; i++) h = (h * 31 + pkg.charCodeAt(i)) >>> 0;
    return "hsl(" + (h % 360) + " 45% 42%)";
  }

  function initial(label, pkg) {
    const s = (label || pkg || "?").trim();
    return s.charAt(0).toUpperCase();
  }

  function selectedPkgs() {
    return apps.filter((a) => a.checked).map((a) => a.pkg);
  }

  function updateHint() {
    if (!hintEl) return;
    hintEl.textContent =
      mode === "disable"
        ? "Hail 停用：退后台整包 pm disable（图标可能消失）。用「打开」解冻并启动。"
        : "SIGSTOP：退后台暂停进程。改勾选后请点「应用名单」。";
  }

  function syncModeRadios() {
    if (modeStop) modeStop.checked = mode === "stop";
    if (modeDisable) modeDisable.checked = mode === "disable";
    updateHint();
  }

  function saveCache() {
    try {
      localStorage.setItem(
        CACHE_KEY,
        JSON.stringify({ t: Date.now(), mode, iconGen, apps })
      );
    } catch (_) {}
  }

  function loadCache() {
    try {
      const o = JSON.parse(localStorage.getItem(CACHE_KEY) || "null");
      if (!o || !Array.isArray(o.apps) || !o.apps.length) return null;
      if (o.mode === "disable" || o.mode === "stop") mode = o.mode;
      if (typeof o.iconGen === "number") iconGen = o.iconGen;
      return o.apps;
    } catch (_) {
      return null;
    }
  }

  function parseSnapshot(raw) {
    return String(raw || "")
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean)
      .map((line) => {
        const p = line.split("\t");
        const pkg = p[0] || "";
        return {
          pkg,
          label: p[1] || pkg,
          checked: p[2] === "1",
          hasIcon: p[3] === "1",
        };
      })
      .filter((a) => a.pkg)
      .sort((a, b) => a.label.localeCompare(b.label, "zh"));
  }

  function matchFilter(app) {
    const q = filter.trim().toLowerCase();
    if (!q) return true;
    return (
      app.label.toLowerCase().includes(q) ||
      app.pkg.toLowerCase().includes(q)
    );
  }

  function makeRow(app, compact) {
    const row = document.createElement("label");
    row.className = "row" + (app.checked ? " frozen" : "") + (compact ? " compact" : "");
    row.dataset.pkg = app.pkg;

    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = !!app.checked;
    cb.dataset.pkg = app.pkg;

    const icon = document.createElement("div");
    icon.className = "icon";
    icon.style.background = colorFor(app.pkg);
    icon.textContent = initial(app.label, app.pkg);
    const img = document.createElement("img");
    img.alt = "";
    img.loading = "lazy";
    img.src = "icons/" + encodeURIComponent(app.pkg) + ".png?v=" + iconGen;
    img.onload = () => {
      icon.textContent = "";
      icon.style.background = "transparent";
      icon.appendChild(img);
    };
    img.onerror = () => {};

    const meta = document.createElement("div");
    meta.className = "meta";
    const name = document.createElement("div");
    name.className = "name";
    name.textContent = app.label;
    meta.appendChild(name);
    if (!compact) {
      const pkg = document.createElement("div");
      pkg.className = "pkg";
      pkg.textContent = app.pkg;
      meta.appendChild(pkg);
    }

    row.appendChild(cb);
    row.appendChild(icon);
    row.appendChild(meta);

    if (app.checked) {
      const badge = document.createElement("span");
      badge.className = "badge" + (mode === "disable" ? " tomb" : "");
      badge.textContent = mode === "disable" ? "停用" : "冻结";
      row.appendChild(badge);
      if (mode === "disable") {
        const thaw = document.createElement("button");
        thaw.type = "button";
        thaw.className = "thaw";
        thaw.textContent = "解冻";
        thaw.dataset.thaw = app.pkg;
        row.appendChild(thaw);
        const launch = document.createElement("button");
        launch.type = "button";
        launch.className = "thaw";
        launch.textContent = "打开";
        launch.dataset.launch = app.pkg;
        row.appendChild(launch);
      }
    }
    return row;
  }

  function render() {
    syncModeRadios();
    if (!frozenList || !allList) return;

    const frozen = [];
    const rest = [];
    for (let i = 0; i < apps.length; i++) {
      const a = apps[i];
      if (!matchFilter(a)) continue;
      if (a.checked) frozen.push(a);
      else rest.push(a);
    }

    frozenList.innerHTML = "";
    allList.innerHTML = "";
    const fg = document.createDocumentFragment();
    const ag = document.createDocumentFragment();
    for (let i = 0; i < frozen.length; i++) fg.appendChild(makeRow(frozen[i], false));
    for (let i = 0; i < rest.length; i++) ag.appendChild(makeRow(rest[i], true));
    frozenList.appendChild(fg);
    allList.appendChild(ag);

    if (frozenEmpty) frozenEmpty.style.display = frozen.length ? "none" : "block";
    if (frozenCount) frozenCount.textContent = String(frozen.length);
    if (allCount) allCount.textContent = String(rest.length);

    setStatus(
      apps.length
        ? apps.length +
            " 个应用 · 黑名单 " +
            selectedPkgs().length +
            " · " +
            (mode === "disable" ? "Hail停用" : "STOP") +
            (listMs ? " · " + listMs + "ms" : "")
        : "无应用数据"
    );
  }

  function findApp(pkg) {
    for (let i = 0; i < apps.length; i++) if (apps[i].pkg === pkg) return apps[i];
    return null;
  }

  function onListChange(e) {
    const t = e.target;
    if (!t || t.type !== "checkbox" || !t.dataset.pkg) return;
    const app = findApp(t.dataset.pkg);
    if (!app) return;
    app.checked = !!t.checked;
    saveCache();
    render();
  }

  async function doThaw(pkg) {
    busy = true;
    setStatus("解冻 " + pkg + "…");
    try {
      await exec(SH + " thaw-pkg '" + pkg.replace(/'/g, "") + "'", 30000);
      toast("已解冻");
      setStatus("已解冻 " + pkg);
    } catch (e) {
      setStatus(String(e.message || e));
      toast("解冻失败");
    } finally {
      busy = false;
    }
  }

  async function doLaunch(pkg) {
    busy = true;
    setStatus("打开 " + pkg + "…");
    try {
      await exec(SH + " launch-pkg '" + pkg.replace(/'/g, "") + "'", 30000);
      toast("已打开");
      setStatus("已打开 " + pkg);
    } catch (e) {
      setStatus(String(e.message || e));
      toast("打开失败");
    } finally {
      busy = false;
    }
  }

  async function doApply() {
    busy = true;
    if (btnApply) btnApply.disabled = true;
    setStatus("写入黑名单…");
    try {
      const pkgs = selectedPkgs();
      const arg =
        pkgs.length === 0
          ? ""
          : " " + pkgs.map((p) => "'" + p.replace(/'/g, "") + "'").join(" ");
      await exec(SH + " set-blacklist" + arg, 15000);
      saveCache();
      toast("已应用");
      setStatus("名单已写入 · 黑名单 " + pkgs.length);
    } catch (e) {
      setStatus(String(e.message || e));
      toast("应用失败");
    } finally {
      busy = false;
      if (btnApply) btnApply.disabled = false;
    }
  }

  async function doSetMode() {
    const next =
      modeDisable && modeDisable.checked
        ? "disable"
        : "stop";
    busy = true;
    if (btnMode) btnMode.disabled = true;
    setStatus("切换模式…");
    try {
      await exec(SH + " set-mode " + next, 12000);
      mode = next;
      saveCache();
      render();
      toast(next === "disable" ? "已切 Hail 停用" : "已切 SIGSTOP");
    } catch (e) {
      const msg = String(e.message || e);
      setStatus(msg);
      toast(msg.includes("allow-disable") ? "需先 touch allow-disable" : "切换失败");
      syncModeRadios();
    } finally {
      busy = false;
      if (btnMode) btnMode.disabled = false;
    }
  }

  async function refreshFromDevice() {
    setStatus("读取应用列表…");
    const t0 = Date.now();
    // Keep short — long apps.sh used to walk /proc and freeze WebUI.
    const raw = await exec(SH + " snapshot", 8000);
    let modeRaw = "stop";
    try {
      modeRaw = await exec(SH + " get-mode", 3000);
    } catch (_) {}
    listMs = Date.now() - t0;
    mode = String(modeRaw || "").trim() === "disable" ? "disable" : "stop";
    apps = parseSnapshot(raw);
    saveCache();
    render();
  }

  async function boot() {
    const cached = loadCache();
    if (cached) {
      apps = cached.map((a) => ({
        pkg: a.pkg,
        label: a.label || a.pkg,
        checked: !!a.checked,
        hasIcon: !!a.hasIcon,
      }));
      render();
      setStatus("缓存已显示 · 刷新中…");
    }
    try {
      await refreshFromDevice();
    } catch (e) {
      if (!apps.length) {
        setStatus(String(e.message || e));
        toast("加载失败");
      } else {
        setStatus("离线缓存（刷新失败）");
      }
    }
  }

  // Native checkbox change — most reliable in WebView
  document.addEventListener("change", onListChange, false);

  // Thaw / Launch buttons via delegation
  function onActionTap(e) {
    const t = e.target;
    if (!t || !t.dataset) return;
    if (t.dataset.thaw) {
      e.preventDefault();
      e.stopPropagation();
      doThaw(t.dataset.thaw);
      return;
    }
    if (t.dataset.launch) {
      e.preventDefault();
      e.stopPropagation();
      doLaunch(t.dataset.launch);
    }
  }
  document.addEventListener("click", onActionTap, false);
  document.addEventListener("touchend", onActionTap, { passive: false });

  if (qEl) {
    qEl.addEventListener("input", () => {
      filter = qEl.value || "";
      render();
    });
  }

  bindTap(btnApply, doApply);
  bindTap(btnReload, async () => {
    busy = true;
    if (btnReload) btnReload.disabled = true;
    try {
      await refreshFromDevice();
    } catch (e) {
      setStatus(String(e.message || e));
    } finally {
      busy = false;
      if (btnReload) btnReload.disabled = false;
    }
  });
  bindTap(btnMode, doSetMode);

  setStatus("UI 400 · 初始化…");
  boot();
})();
