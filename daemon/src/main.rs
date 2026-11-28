//! bgfreeze — KernelSU blacklist freezer daemon (Rust).
//!
//! Complexity targets (per poll):
//! - proc snapshot: Θ(T) once → HashMap<uid, Vec<pid>>
//! - packages.list: O(L) rebuild on mtime, O(1) lookup
//! - blacklist walk: Θ(N + P) using the shared snapshot
//! - disable verify: Θ(D) once per poll (one `pm list -d`)

mod config;
mod freezer;
mod hail;
mod ipc;
mod lock;
mod logutil;
mod procscan;

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use config::{Mode, Paths, Settings};
use freezer::Backend;
use hail::{apply_disable, is_binder_fail, is_critical, list_disabled, revive};
use ipc::IpcBudget;
use lock::DaemonLock;
use logutil::Logger;
use procscan::{scan_procs, ProcSnap, UidSnap};

const POLL: Duration = Duration::from_secs(3);
const POLL_IDLE: Duration = Duration::from_secs(10);
const DELAY: Duration = Duration::from_secs(3);
const WATCH_EVERY: Duration = Duration::from_secs(60);
const FAIL_COOLDOWN: Duration = Duration::from_secs(600);
const FG_CACHE: Duration = Duration::from_secs(8);
const PKG_LIST_MIN_REFRESH: Duration = Duration::from_secs(30);
/// Max am/pm/dumpsys calls per poll (fail-safe budget).
const IPC_PER_POLL: u32 = 3;
/// Trip circuit after this many binder fails in process lifetime.
const BINDER_FAIL_TRIP: u32 = 3;
const DUMPSYS_TIMEOUT: Duration = Duration::from_secs(2);
const DUMPSYS_MAX: usize = 256 * 1024;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(String::as_str).unwrap_or("daemon");
    match cmd {
        "daemon" | "run" => {
            if let Err(e) = run_daemon() {
                eprintln!("bgfreeze daemon fatal: {e}");
                std::process::exit(1);
            }
        }
        "version" | "-V" | "--version" => {
            println!("bgfreeze {}", env!("CARGO_PKG_VERSION"));
        }
        "help" | "-h" | "--help" => {
            eprintln!(
                "usage: bgfreeze <daemon|version|selfcheck>\n  daemon — main loop (default)"
            );
        }
        "selfcheck" => match selfcheck() {
            Ok(()) => println!("SELFCHECK_OK"),
            Err(e) => {
                eprintln!("SELFCHECK_FAIL {e}");
                std::process::exit(2);
            }
        },
        other => {
            eprintln!("unknown command: {other}");
            std::process::exit(2);
        }
    }
}

fn selfcheck() -> io::Result<()> {
    let paths = Paths::discover();
    if !paths.moddir.join("module.prop").is_file() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "module.prop missing"));
    }
    // Can we read /proc?
    let snap = scan_procs()?;
    if snap.by_uid.is_empty() {
        return Err(io::Error::new(io::ErrorKind::Other, "empty proc snap"));
    }
    Ok(())
}

fn run_daemon() -> io::Result<()> {
    let paths = Paths::discover();
    fs::create_dir_all(&paths.data)?;

    let mut log = Logger::open(&paths.log)?;

    if paths.moddir.join("disable").is_file() || paths.data.join("panic").is_file() {
        log.write("exit reason=killswitch")?;
        return Ok(());
    }

    let _lock = match DaemonLock::try_acquire(&paths.lock) {
        Ok(l) => l,
        Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
            log.write("exit reason=lock-held")?;
            return Ok(());
        }
        Err(e) => return Err(e),
    };

    fs::write(&paths.pidfile, format!("{}\n", std::process::id()))?;

    let mut settings = Settings::load(&paths)?;
    let backend = freezer::detect();
    log.write(&format!(
        "start pid={} mode={:?} backend={} allow_disable={} ipc_budget={} rust=1 safe_enable=1",
        std::process::id(),
        settings.mode,
        backend.as_str(),
        paths.disable_allowed(),
        IPC_PER_POLL
    ))?;

    let mut pkg_index: HashMap<String, u32> = HashMap::new();
    let mut pkg_mtime = None;
    let mut pkg_refresh_at = Instant::now()
        .checked_sub(PKG_LIST_MIN_REFRESH)
        .unwrap_or_else(Instant::now);

    // (pkg, ts, ok) — ok=false means last dumpsys failed → skip freezes
    let mut fg_cache: (Option<String>, Instant, bool) = (
        None,
        Instant::now()
            .checked_sub(FG_CACHE)
            .unwrap_or_else(Instant::now),
        true,
    );

    let mut bg_since: HashMap<String, u64> = HashMap::new();
    let mut frozen: HashSet<String> = HashSet::new();
    let mut tombstone: HashSet<String> = HashSet::new();
    let mut fail_until: HashMap<String, Instant> = HashMap::new();
    let mut last_watch: HashMap<String, Instant> = HashMap::new();

    if let Ok(rd) = fs::read_dir(&paths.data) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if let Some(pkg) = name.strip_prefix("tombstone.") {
                tombstone.insert(pkg.to_string());
            }
            if let Some(pkg) = name.strip_prefix("frozen.") {
                frozen.insert(pkg.to_string());
            }
        }
    }

    loop {
        if paths.moddir.join("disable").is_file() || paths.data.join("panic").is_file() {
            log.write("stop reason=killswitch")?;
            break;
        }

        if ipc::binder_fail_count() >= BINDER_FAIL_TRIP {
            trip_circuit(&paths, "binder-fail-budget")?;
            log.write("circuit-open binder-fail-budget")?;
            ipc::reset_binder_fails();
        }

        settings.reload_mode(&paths)?;
        if paths.circuit.is_file() {
            settings.mode = Mode::Stop;
        }
        if settings.mode == Mode::Disable && !paths.disable_allowed() {
            settings.mode = Mode::Stop;
        }

        let blacklist = read_blacklist(&paths.blacklist)?;
        // Safe idle: empty list → no dumpsys, no /proc storm
        if blacklist.is_empty() {
            thread::sleep(POLL_IDLE);
            continue;
        }

        refresh_pkg_index(
            &paths.packages_list,
            &mut pkg_index,
            &mut pkg_mtime,
            &mut pkg_refresh_at,
        )?;

        let mut budget = IpcBudget::new(IPC_PER_POLL);

        // Foreground: required for safe freeze. On failure → skip freeze this round.
        let (fg, fg_ok) = foreground_pkg(&mut fg_cache, &mut budget);
        if !fg_ok {
            log.write("skip-freeze reason=fg-unknown")?;
            thread::sleep(POLL);
            continue;
        }

        let snap = scan_procs().unwrap_or_else(|_| ProcSnap::default());

        let disabled_set = if settings.mode == Mode::Disable {
            if !budget.try_take() {
                HashSet::new()
            } else {
                match list_disabled() {
                    Ok(s) => s,
                    Err(e) => {
                        if is_binder_fail(&e.to_string()) {
                            trip_circuit(&paths, &format!("pm-list-d:{e}"))?;
                            log.write(&format!("circuit-open pm-list-d {e}"))?;
                        }
                        HashSet::new()
                    }
                }
            }
        } else {
            HashSet::new()
        };

        let now_unix = unix_now();
        let mut disable_applied = false;

        for pkg in &blacklist {
            let Some(&uid) = pkg_index.get(pkg.as_str()) else {
                continue;
            };
            if uid < 10000 {
                continue;
            }

            match settings.mode {
                Mode::Disable => {
                    if disable_applied {
                        continue; // at most one apply per poll
                    }
                    let before = tombstone.contains(pkg);
                    tick_disable(
                        &paths,
                        &mut log,
                        pkg,
                        uid,
                        &fg,
                        &snap,
                        &disabled_set,
                        &mut bg_since,
                        &mut tombstone,
                        &mut frozen,
                        &mut fail_until,
                        &mut last_watch,
                        now_unix,
                    )?;
                    if !before && tombstone.contains(pkg) {
                        disable_applied = true;
                    }
                }
                Mode::Stop => {
                    tick_stop(
                        &paths,
                        &mut log,
                        pkg,
                        uid,
                        &fg,
                        &snap,
                        backend,
                        &mut bg_since,
                        &mut tombstone,
                        &mut frozen,
                        &mut last_watch,
                        now_unix,
                    )?;
                }
            }
        }

        thread::sleep(POLL);
    }
    Ok(())
}

fn tick_disable(
    paths: &Paths,
    log: &mut Logger,
    pkg: &str,
    uid: u32,
    fg: &Option<String>,
    snap: &ProcSnap,
    disabled_set: &HashSet<String>,
    bg_since: &mut HashMap<String, u64>,
    tombstone: &mut HashSet<String>,
    frozen: &mut HashSet<String>,
    fail_until: &mut HashMap<String, Instant>,
    last_watch: &mut HashMap<String, Instant>,
    now_unix: u64,
) -> io::Result<()> {
    if paths.circuit.is_file() {
        return Ok(());
    }

    if tombstone.contains(pkg) {
        if !disabled_set.contains(pkg) {
            tombstone.remove(pkg);
            let _ = fs::remove_file(paths.data.join(format!("tombstone.{pkg}")));
            log.write(&format!("auto-clear {pkg} uid={uid}"))?;
            if fg.as_deref() == Some(pkg) {
                bg_since.remove(pkg);
                frozen.remove(pkg);
                return Ok(());
            }
            bg_since.insert(pkg.to_string(), now_unix);
            return Ok(());
        }
        let due = last_watch
            .get(pkg)
            .map(|t| t.elapsed() >= WATCH_EVERY)
            .unwrap_or(true);
        if due {
            log.write(&format!("watch-hail {pkg} uid={uid} disabled=1"))?;
            last_watch.insert(pkg.to_string(), Instant::now());
        }
        return Ok(());
    }

    if fg.as_deref() == Some(pkg) {
        bg_since.remove(pkg);
        frozen.remove(pkg);
        return Ok(());
    }

    if let Some(until) = fail_until.get(pkg) {
        if Instant::now() < *until {
            return Ok(());
        }
    }

    let since = *bg_since.entry(pkg.to_string()).or_insert(now_unix);
    if now_unix.saturating_sub(since) < DELAY.as_secs() {
        return Ok(());
    }

    if is_critical(pkg) {
        fail_until.insert(pkg.to_string(), Instant::now() + FAIL_COOLDOWN);
        log.write(&format!("hail-refuse-critical {pkg}"))?;
        return Ok(());
    }

    match apply_disable(pkg) {
        Ok(()) => {
            tombstone.insert(pkg.to_string());
            frozen.insert(pkg.to_string());
            let _ = fs::write(paths.data.join(format!("tombstone.{pkg}")), b"1\n");
            let _ = fs::write(paths.data.join(format!("frozen.{pkg}")), b"1\n");
            fail_until.remove(pkg);
            log.write(&format!("hail-disable {pkg} uid={uid} ok=1"))?;
        }
        Err(e) => {
            fail_until.insert(pkg.to_string(), Instant::now() + FAIL_COOLDOWN);
            let msg = e.to_string();
            if is_binder_fail(&msg) {
                trip_circuit(paths, &format!("pm:{pkg}:{msg}"))?;
                log.write(&format!("circuit-open {pkg} {msg}"))?;
            } else {
                log.write(&format!(
                    "hail-failfast {pkg} uid={uid} cooldown={}s err{{{msg}}}",
                    FAIL_COOLDOWN.as_secs()
                ))?;
            }
        }
    }
    last_watch.insert(pkg.to_string(), Instant::now());
    let _ = snap; // reserved: optional re-stop only if we ever re-enable quiet scan
    Ok(())
}

fn tick_stop(
    paths: &Paths,
    log: &mut Logger,
    pkg: &str,
    uid: u32,
    fg: &Option<String>,
    snap: &ProcSnap,
    backend: Backend,
    bg_since: &mut HashMap<String, u64>,
    tombstone: &mut HashSet<String>,
    frozen: &mut HashSet<String>,
    last_watch: &mut HashMap<String, Instant>,
    now_unix: u64,
) -> io::Result<()> {
    if tombstone.contains(pkg) {
        let _ = revive(pkg);
        tombstone.remove(pkg);
        let _ = fs::remove_file(paths.data.join(format!("tombstone.{pkg}")));
        log.write(&format!("revive {pkg} (mode=stop)"))?;
    }

    let empty = UidSnap::default();
    let us = snap.by_uid.get(&uid).unwrap_or(&empty);

    if fg.as_deref() == Some(pkg) {
        bg_since.remove(pkg);
        if frozen.remove(pkg) {
            let n = freezer::thaw_uid(backend, uid, us).unwrap_or(0);
            let _ = fs::remove_file(paths.data.join(format!("frozen.{pkg}")));
            log.write(&format!(
                "thaw {pkg} uid={uid} backend={} n={n}",
                backend.as_str()
            ))?;
        }
        return Ok(());
    }

    let since = *bg_since.entry(pkg.to_string()).or_insert(now_unix);
    if now_unix.saturating_sub(since) < DELAY.as_secs() {
        return Ok(());
    }

    // Already marked frozen: detect WAKE
    if frozen.contains(pkg) {
        let woke = match backend {
            Backend::CgroupUid => !freezer::is_cgroup_frozen(uid) && !us.pids.is_empty(),
            _ => {
                let running = us.pids.iter().filter(|(_, s)| *s != 'T').count();
                running > 0
            }
        };
        if woke {
            let n = freezer::freeze_uid(backend, uid, us).unwrap_or(0);
            last_watch.insert(pkg.to_string(), Instant::now());
            log.write(&format!(
                "WAKE {pkg} uid={uid} backend={} refreeze={n}",
                backend.as_str()
            ))?;
        } else {
            let due = last_watch
                .get(pkg)
                .map(|t| t.elapsed() >= WATCH_EVERY)
                .unwrap_or(true);
            if due {
                log.write(&format!(
                    "watch {pkg} uid={uid} backend={} total={} T={}",
                    backend.as_str(),
                    us.pids.len(),
                    us.stopped_count()
                ))?;
                last_watch.insert(pkg.to_string(), Instant::now());
            }
        }
        return Ok(());
    }

    let added = freezer::freeze_uid(backend, uid, us).unwrap_or(0);
    frozen.insert(pkg.to_string());
    let _ = fs::write(paths.data.join(format!("frozen.{pkg}")), b"1\n");
    last_watch.insert(pkg.to_string(), Instant::now());
    log.write(&format!(
        "freeze {pkg} uid={uid} backend={} n={added}",
        backend.as_str()
    ))?;
    Ok(())
}

fn trip_circuit(paths: &Paths, reason: &str) -> io::Result<()> {
    let mut f = fs::File::create(&paths.circuit)?;
    writeln!(f, "{reason}")?;
    fs::write(&paths.modefile, b"stop\n")?;
    Ok(())
}

fn refresh_pkg_index(
    path: &Path,
    index: &mut HashMap<String, u32>,
    mtime: &mut Option<SystemTime>,
    last: &mut Instant,
) -> io::Result<()> {
    if last.elapsed() < PKG_LIST_MIN_REFRESH {
        return Ok(());
    }
    let meta = match fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return Ok(()),
    };
    let mt = meta.modified().ok();
    if mt == *mtime && !index.is_empty() {
        *last = Instant::now();
        return Ok(());
    }
    let text = fs::read_to_string(path)?;
    index.clear();
    for line in text.lines() {
        let mut it = line.split_whitespace();
        let Some(pkg) = it.next() else { continue };
        let Some(uid_s) = it.next() else { continue };
        if let Ok(uid) = uid_s.parse::<u32>() {
            index.insert(pkg.to_string(), uid);
        }
    }
    *mtime = mt;
    *last = Instant::now();
    Ok(())
}

fn read_blacklist(path: &Path) -> io::Result<Vec<String>> {
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect())
}

/// Returns (fg_pkg, ok). ok=false → caller must skip freezes this round.
fn foreground_pkg(
    cache: &mut (Option<String>, Instant, bool),
    budget: &mut IpcBudget,
) -> (Option<String>, bool) {
    if cache.1.elapsed() < FG_CACHE {
        return (cache.0.clone(), cache.2);
    }
    if !budget.try_take() {
        return (cache.0.clone(), false);
    }
    let out = ipc::run_capped(
        "/system/bin/dumpsys",
        &["activity", "activities"],
        DUMPSYS_TIMEOUT,
        DUMPSYS_MAX,
    );
    let Ok(bytes) = out else {
        cache.0 = None;
        cache.1 = Instant::now();
        cache.2 = false;
        return (None, false);
    };
    let s = String::from_utf8_lossy(&bytes);
    let mut found = None;
    for line in s.lines() {
        if line.contains("mResumedActivity") || line.contains("topResumedActivity") {
            if let Some(pkg) = extract_pkg_from_activity_line(line) {
                found = Some(pkg);
                break;
            }
        }
    }
    // No resumed line → treat as unknown (fail-safe: do not freeze)
    let ok = found.is_some();
    cache.0 = found.clone();
    cache.1 = Instant::now();
    cache.2 = ok;
    (found, ok)
}

fn extract_pkg_from_activity_line(line: &str) -> Option<String> {
    // find token with '/'
    for tok in line.split_whitespace() {
        if let Some((pkg, _)) = tok.split_once('/') {
            if pkg.contains('.') {
                let pkg = pkg.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '.' && c != '_');
                if !pkg.is_empty() {
                    return Some(pkg.to_string());
                }
            }
        }
    }
    None
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
