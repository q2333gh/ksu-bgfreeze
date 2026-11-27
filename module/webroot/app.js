(() => {
  const MOD = "/data/adb/modules/ksu-bgfreeze";
  const SH = `sh ${MOD}/bin/apps.sh`;
  const listEl = document.getElementById("list");
  const statusEl = document.getElementById("status");
  const countEl = document.getElementById("count");
  const applyBtn = document.getElementById("apply");
  const qEl = document.getElementById("q");

  /** @type {{pkg:string,label:string,checked:boolean}[]} */
  let apps = [];
  let filter = "";

  function toast(msg) {
    try {
      if (window.ksu && typeof ksu.toast === "function") ksu.toast(msg);
      else statusEl.textContent = msg;
    } catch (_) {
      statusEl.textContent = msg;
    }
  }

  function exec(cmd) {
    return new Promise((resolve, reject) => {
      if (!window.ksu || typeof ksu.exec !== "function") {
        reject(new Error("请在 KernelSU 模块 WebUI 中打开"));
        return;
      }
      const cb = "_bgf_" + Math.random().toString(36).slice(2);
      window[cb] = (errno, stdout, stderr) => {
        try { delete window[cb]; } catch (_) {}
        if (errno === 0 || errno === "0") resolve(stdout || "");
        else reject(new Error(stderr || stdout || String(errno)));
      };
      try {
        ksu.exec(cmd, "{}", cb);
      } catch (e) {
        try { ksu.exec(cmd, cb); }
        catch (e2) { reject(e2 || e); }
      }
    });
  }

  function colorFor(pkg) {
    let h = 0;
    for (let i = 0; i < pkg.length; i++) h = (h * 31 + pkg.charCodeAt(i)) >>> 0;
    const hue = h % 360;
    return `hsl(${hue} 45% 42%)`;
  }

  function initial(label, pkg) {
    const s = (label || pkg || "?").trim();
    return s.charAt(0).toUpperCase();
  }

  function selectedPkgs() {
    return apps.filter((a) => a.checked).map((a) => a.pkg);
  }

  function updateCount() {
    countEl.textContent = "已选 " + selectedPkgs().length;
  }

  // Limit concurrent icon extractions — each is a shell + unzip.
  const ICON_CONCURRENCY = 2;
  let iconActive = 0;
  /** @type {{pkg:string,el:HTMLElement}[]} */
  const iconQueue = [];
  const iconCache = new Map();

  function pumpIcons() {
    while (iconActive < ICON_CONCURRENCY && iconQueue.length) {
      const job = iconQueue.shift();
      iconActive++;
      loadIconNow(job.pkg, job.el).finally(() => {
        iconActive--;
        pumpIcons();
      });
    }
  }

  function enqueueIcon(pkg, el) {
    if (iconCache.has(pkg)) {
      const b64 = iconCache.get(pkg);
      if (b64) paintIcon(el, b64);
      return;
    }
    iconQueue.push({ pkg, el });
    pumpIcons();
  }

  async function loadIconNow(pkg, el) {
    if (iconCache.has(pkg)) {
      const b64 = iconCache.get(pkg);
      if (b64) paintIcon(el, b64);
      return;
    }
    try {
      const b64 = (await exec(`${SH} icon '${pkg.replace(/'/g, "")}'`)).trim();
      iconCache.set(pkg, b64 || null);
      if (b64 && el.isConnected) paintIcon(el, b64);
    } catch (_) {
      iconCache.set(pkg, null);
    }
  }

  function paintIcon(el, b64) {
    el.textContent = "";
    el.style.background = "transparent";
    const img = document.createElement("img");
    img.alt = "";
    img.loading = "lazy";
    img.src = "data:image/png;base64," + b64;
    img.onerror = () => {
      try { el.removeChild(img); } catch (_) {}
    };
    el.appendChild(img);
  }

  function render() {
    const q = filter.trim().toLowerCase();
    iconQueue.length = 0;
    listEl.innerHTML = "";
    const frag = document.createDocumentFragment();
    let n = 0;
    const iconJobs = [];
    for (const app of apps) {
      if (q && !app.label.toLowerCase().includes(q) && !app.pkg.toLowerCase().includes(q)) continue;
      n++;
      const li = document.createElement("li");
      li.className = "row" + (app.checked ? " on" : "");
      li.dataset.pkg = app.pkg;

      const icon = document.createElement("div");
      icon.className = "icon";
      icon.style.background = colorFor(app.pkg);
      icon.textContent = initial(app.label, app.pkg);

      const meta = document.createElement("div");
      meta.className = "meta";
      meta.innerHTML = `<div class="name"></div><div class="pkg"></div>`;
      meta.querySelector(".name").textContent = app.label;
      meta.querySelector(".pkg").textContent = app.pkg;

      const check = document.createElement("div");
      check.className = "check";

      li.append(icon, meta, check);
      li.addEventListener("click", () => {
        app.checked = !app.checked;
        li.classList.toggle("on", app.checked);
        updateCount();
      });
      frag.appendChild(li);
      iconJobs.push({ pkg: app.pkg, el: icon });
    }
    listEl.appendChild(frag);
    statusEl.textContent = n ? `显示 ${n} / ${apps.length} 个第三方应用` : "无匹配应用";
    updateCount();

    // Defer icon fetch so the list paints first.
    setTimeout(() => {
      for (const job of iconJobs) enqueueIcon(job.pkg, job.el);
    }, 0);
  }

  function parseList(rawList, rawBl) {
    const bl = new Set(
      rawBl.split(/\r?\n/).map((s) => s.trim()).filter((s) => s && !s.startsWith("#"))
    );
    return rawList
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => {
        const i = line.indexOf("\t");
        const pkg = i >= 0 ? line.slice(0, i) : line;
        const label = i >= 0 ? line.slice(i + 1) : pkg;
        return { pkg, label: label || pkg, checked: bl.has(pkg) };
      })
      .sort((a, b) => {
        if (a.checked !== b.checked) return a.checked ? -1 : 1;
        return a.label.localeCompare(b.label, "zh");
      });
  }

  async function boot() {
    try {
      statusEl.textContent = "读取应用列表…";
      const t0 = Date.now();
      const [rawList, rawBl] = await Promise.all([
        exec(`${SH} list`),
        exec(`${SH} get-blacklist`),
      ]);
      const ms = Date.now() - t0;
      apps = parseList(rawList, rawBl);
      render();
      statusEl.textContent = `显示 ${apps.length} 个第三方应用 · 列表 ${ms}ms`;

      // Labels: Android 14 dumpsys 无 application-label；有 aapt 时后台刷新再重载
      const needsLabels = apps.some((a) => a.label === a.pkg);
      if (needsLabels) {
        exec(`${SH} refresh-labels`)
          .then(async (out) => {
            if (!String(out).includes("OK")) return;
            const [list2, bl2] = await Promise.all([
              exec(`${SH} list`),
              exec(`${SH} get-blacklist`),
            ]);
            apps = parseList(list2, bl2);
            render();
            statusEl.textContent =
              `显示 ${apps.length} 个第三方应用 · 列表 ${ms}ms · 已刷新名称`;
          })
          .catch(() => {});
      }
    } catch (e) {
      statusEl.textContent = String(e.message || e);
      toast("加载失败：请用 KernelSU 打开本模块 WebUI");
    }
  }

  qEl.addEventListener("input", () => {
    filter = qEl.value || "";
    render();
  });

  applyBtn.addEventListener("click", async () => {
    applyBtn.disabled = true;
    applyBtn.classList.add("busy");
    applyBtn.textContent = "应用中…";
    try {
      const pkgs = selectedPkgs();
      const payload = pkgs.map((p) => p.replace(/'/g, "")).join("\\n");
      const cmd =
        `printf '%b' '${payload}\\n' | ${SH} set-blacklist`;
      await exec(cmd);
      toast(pkgs.length ? `已应用 ${pkgs.length} 个` : "已应用：黑名单为空");
      statusEl.textContent = "已写入黑名单并重启守护进程";
    } catch (e) {
      toast("应用失败");
      statusEl.textContent = String(e.message || e);
    } finally {
      applyBtn.disabled = false;
      applyBtn.classList.remove("busy");
      applyBtn.textContent = "应用";
    }
  });

  boot();
})();
