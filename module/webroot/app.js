(() => {
  "use strict";

  const MOD = "/data/adb/modules/ksu-bgfreeze";
  const SH = "sh " + MOD + "/bin/apps.sh";
  const CACHE_KEY = "bgf_snapshot_v5";
  const UI = "405";

  const statusEl = document.getElementById("status");
  const hintEl = document.getElementById("hint");
  const dirtyEl = document.getElementById("dirty");
  const qEl = document.getElementById("q");
  const frozenList = document.getElementById("frozenList");
  const allList = document.getElementById("allList");
  const frozenEmpty = document.getElementById("frozenEmpty");
  const frozenCount = document.getElementById("frozenCount");
  const allCount = document.getElementById("allCount");
  const btnApply = document.getElementById("btnApply");
  const btnReload = document.getElementById("btnReload");
  const modeStop = document.getElementById("modeStop");
  const modeDisable = document.getElementById("modeDisable");
  const appRoot = document.getElementById("app");

  let apps = [];
  let filter = "";
  let mode = "stop";
  let savedMode = "stop";
  let savedPkgs = [];
  let iconGen = 0;
  let listMs = 0;
  let busy = false;
  let lastTap = 0;

  function setStatus(t) {
    if (statusEl) statusEl.textContent = t || "";
  }

  function setBusy(on, label) {
    busy = !!on;
    if (appRoot) appRoot.classList.toggle("is-busy", busy);
    if (btnApply) btnApply.disabled = busy;
    if (btnReload) btnReload.disabled = busy;
    if (modeStop) modeStop.disabled = busy;
    if (modeDisable) modeDisable.disabled = busy;
    if (on && label) setStatus(label);
  }

  function toast(msg) {
    try {
      if (window.ksu && typeof ksu.toast === "function") ksu.toast(msg);
      else setStatus(msg);
    } catch (_) {
      setStatus(msg);
    }
  }

  /** Single-fire tap: ignore duplicate click after touchend within 450ms. */
  function shouldAcceptTap() {
    const now = Date.now();
    if (now - lastTap < 450) return false;
    lastTap = now;
    return true;
  }

  function bindTap(el, fn) {
    if (!el) return;
    const run = (e) => {
      if (busy) return;
      if (!shouldAcceptTap()) {
        if (e) {
          try {
            e.preventDefault();
          } catch (_) {}
        }
        return;
      }
      if (e) {
        try {
          e.preventDefault();
        } catch (_) {}
      }
      Promise.resolve()
        .then(() => fn(e))
        .catch((err) => setStatus(String(err && err.message ? err.message : err)));
    };
    el.addEventListener("click", run);
    el.addEventListener("touchend", run, { passive: false });
  }

  function exec(cmd, timeoutMs) {
    const ms = timeoutMs || 10000;
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
        try {
          delete window[cb];
        } catch (_) {}
        reject(new Error("超时"));
      }, ms);
      window[cb] = (errno, stdout, stderr) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        try {
          delete window[cb];
        } catch (_) {}
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

  function pkgsEqual(a, b) {
    if (a.length !== b.length) return false;
    const sa = a.slice().sort();
    const sb = b.slice().sort();
    for (let i = 0; i < sa.length; i++) if (sa[i] !== sb[i]) return false;
    return true;
  }

  function isDirty() {
    return mode !== savedMode || !pkgsEqual(selectedPkgs(), savedPkgs);
  }

  function updateDirty() {
    const dirty = isDirty();
    if (dirtyEl) {
      dirtyEl.hidden = !dirty;
      if (dirty) {
        const n = selectedPkgs().length;
        dirtyEl.textContent =
          "未保存" +
          (mode !== savedMode ? " · 模式" : "") +
          (pkgsEqual(selectedPkgs(), savedPkgs) ? "" : " · 名单 " + n);
      }
    }
    if (btnApply) {
      btnApply.classList.toggle("needs-save", dirty);
      btnApply.textContent = dirty ? "保存更改" : "已是最新";
    }
  }

  function updateHint() {
    if (!hintEl) return;
    hintEl.textContent =
      mode === "disable"
        ? "Hail 停用需 allow-disable。勾选后点「保存更改」。"
        : "勾选要冻结的应用，点「保存更改」。列表操作不扫 /proc。";
  }

  function syncModeRadios() {
    if (modeStop) modeStop.checked = mode === "stop";
    if (modeDisable) modeDisable.checked = mode === "disable";
    updateHint();
    updateDirty();
  }

  function saveCache() {
    try {
      localStorage.setItem(
        CACHE_KEY,
        JSON.stringify({
          t: Date.now(),
          mode,
          savedMode,
          savedPkgs,
          iconGen,
          apps,
          ui: UI,
        })
      );
    } catch (_) {}
  }

  function loadCache() {
    try {
      const o = JSON.parse(localStorage.getItem(CACHE_KEY) || "null");
      if (!o || !Array.isArray(o.apps) || !o.apps.length) return null;
      if (o.mode === "disable" || o.mode === "stop") mode = o.mode;
      if (o.savedMode === "disable" || o.savedMode === "stop") savedMode = o.savedMode;
      if (Array.isArray(o.savedPkgs)) savedPkgs = o.savedPkgs;
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
      app.label.toLowerCase().includes(q) || app.pkg.toLowerCase().includes(q)
    );
  }

  function fillIcon(icon, app) {
    icon.style.background = colorFor(app.pkg);
    icon.textContent = initial(app.label, app.pkg);
    if (!app.hasIcon) return;
    const img = document.createElement("img");
    img.alt = "";
    img.loading = "lazy";
    img.decoding = "async";
    img.src = "icons/" + encodeURIComponent(app.pkg) + ".png?v=" + iconGen;
    img.onload = () => {
      icon.textContent = "";
      icon.style.background = "transparent";
      icon.appendChild(img);
    };
    img.onerror = () => {};
  }

  function makeRow(app, compact) {
    const row = document.createElement("label");
    row.className =
      "row" + (app.checked ? " frozen" : "") + (compact ? " compact" : "");
    row.dataset.pkg = app.pkg;

    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = !!app.checked;
    cb.dataset.pkg = app.pkg;

    const icon = document.createElement("div");
    icon.className = "icon";
    fillIcon(icon, app);

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
            " 个 · 黑名单 " +
            selectedPkgs().length +
            " · " +
            (mode === "disable" ? "Hail" : "冻结") +
            (listMs ? " · " + listMs + "ms" : "")
        : "无应用数据"
    );
    updateDirty();
  }

  function findApp(pkg) {
    for (let i = 0; i < apps.length; i++) if (apps[i].pkg === pkg) return apps[i];
    return null;
  }

  /** Checkbox: update model + light re-render only when section membership changes. */
  function onListChange(e) {
    const t = e.target;
    if (!t || t.type !== "checkbox" || !t.dataset.pkg) return;
    if (busy) {
      t.checked = !t.checked;
      return;
    }
    const app = findApp(t.dataset.pkg);
    if (!app) return;
    const was = !!app.checked;
    app.checked = !!t.checked;
    if (was === app.checked) return;
    saveCache();
    // Crossing frozen/other boundary → full render; else just dirty flag.
    render();
  }

  async function doThaw(pkg) {
    if (busy || !shouldAcceptTap()) return;
    setBusy(true, "解冻 " + pkg + "…");
    try {
      await exec(SH + " thaw-pkg '" + pkg.replace(/'/g, "") + "'", 8000);
      toast("已解冻");
      setStatus("已解冻 " + pkg);
    } catch (e) {
      setStatus(String(e.message || e));
      toast("解冻失败");
    } finally {
      setBusy(false);
    }
  }

  async function doLaunch(pkg) {
    if (busy || !shouldAcceptTap()) return;
    setBusy(true, "打开 " + pkg + "…");
    try {
      await exec(SH + " launch-pkg '" + pkg.replace(/'/g, "") + "'", 8000);
      toast("已打开");
      setStatus("已打开 " + pkg);
    } catch (e) {
      setStatus(String(e.message || e));
      toast("打开失败");
    } finally {
      setBusy(false);
    }
  }

  async function doApply() {
    if (busy) return;
    if (!isDirty()) {
      toast("没有需要保存的更改");
      return;
    }
    setBusy(true, "保存中…");
    try {
      if (mode !== savedMode) {
        await exec(SH + " set-mode " + mode, 8000);
        savedMode = mode;
      }
      const pkgs = selectedPkgs();
      const arg =
        pkgs.length === 0
          ? ""
          : " " + pkgs.map((p) => "'" + p.replace(/'/g, "") + "'").join(" ");
      await exec(SH + " set-blacklist" + arg, 10000);
      savedPkgs = pkgs.slice();
      saveCache();
      toast("已保存");
      setStatus("已保存 · 黑名单 " + pkgs.length + " · " + (mode === "disable" ? "Hail" : "冻结"));
      updateDirty();
    } catch (e) {
      const msg = String(e.message || e);
      setStatus(msg);
      toast(msg.includes("allow-disable") ? "需先 touch allow-disable" : "保存失败");
      syncModeRadios();
    } finally {
      setBusy(false);
    }
  }

  function onModeChange() {
    if (busy) {
      syncModeRadios();
      return;
    }
    const next = modeDisable && modeDisable.checked ? "disable" : "stop";
    mode = next;
    updateHint();
    updateDirty();
    saveCache();
    // Re-render badges only when mode string changes for checked rows
    render();
  }

  async function refreshFromDevice() {
    setStatus("读取应用列表…");
    const t0 = Date.now();
    const raw = await exec(SH + " snapshot", 8000);
    let modeRaw = "stop";
    try {
      modeRaw = await exec(SH + " get-mode", 3000);
    } catch (_) {}
    listMs = Date.now() - t0;
    mode = String(modeRaw || "").trim() === "disable" ? "disable" : "stop";
    savedMode = mode;
    apps = parseSnapshot(raw);
    savedPkgs = selectedPkgs();
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
      if (!savedPkgs.length) savedPkgs = selectedPkgs();
      render();
      setStatus("缓存 · 刷新中…");
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

  document.addEventListener("change", onListChange, false);
  if (modeStop) modeStop.addEventListener("change", onModeChange);
  if (modeDisable) modeDisable.addEventListener("change", onModeChange);

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
    let qTimer = 0;
    qEl.addEventListener("input", () => {
      filter = qEl.value || "";
      clearTimeout(qTimer);
      qTimer = setTimeout(() => render(), 80);
    });
  }

  bindTap(btnApply, doApply);
  bindTap(btnReload, async () => {
    setBusy(true, "刷新列表…");
    try {
      await refreshFromDevice();
    } catch (e) {
      setStatus(String(e.message || e));
    } finally {
      setBusy(false);
    }
  });

  setStatus("UI " + UI + " · 初始化…");
  boot();
})();
