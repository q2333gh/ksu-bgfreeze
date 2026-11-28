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
mod lock;
mod logutil;
mod procscan;

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use config::{Mode, Paths, Settings};
use freezer::Backend;
use hail::{apply_disable, is_binder_fail, is_critical, list_disabled, revive};
use lock::DaemonLock;
use logutil::Logger;
use procscan::{scan_procs, ProcSnap, UidSnap};

const POLL: Duration = Duration::from_secs(3);
const DELAY: Duration = Duration::from_secs(3);
const WATCH_EVERY: Duration = Duration::from_secs(60);
const FAIL_COOLDOWN: Duration = Duration::from_secs(600);
const FG_CACHE: Duration = Duration::from_secs(5);
const PKG_LIST_MIN_REFRESH: Duration = Duration::from_secs(30);

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
        "start pid={} mode={:?} backend={} poll={}s delay={}s rust=1 big_o=O(T)|O(1uid)",
        std::process::id(),
        settings.mode,
        backend.as_str(),
        POLL.as_secs(),
        DELAY.as_secs()
    ))?;

    let mut pkg_index: HashMap<String, u32> = HashMap::new();
    let mut pkg_mtime = None;
    let mut pkg_refresh_at = Instant::now()
        .checked_sub(PKG_LIST_MIN_REFRESH)
        .unwrap_or_else(Instant::now);

    let mut fg_cache: (Option<String>, Instant) = (None, Instant::now()
        .checked_sub(FG_CACHE)
        .unwrap_or_else(Instant::now));

    let mut bg_since: HashMap<String, u64> = HashMap::new();
    let mut frozen: HashSet<String> = HashSet::new();
    let mut tombstone: HashSet<String> = HashSet::new();
    let mut fail_until: HashMap<String, Instant> = HashMap::new();
    let mut last_watch: HashMap<String, Instant> = HashMap::new();

    // Restore markers from disk
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

        settings.reload_mode(&paths)?;
        if paths.circuit.is_file() {
            settings.mode = Mode::Stop;
        }

        refresh_pkg_index(
            &paths.packages_list,
            &mut pkg_index,
            &mut pkg_mtime,
            &mut pkg_refresh_at,
        )?;

        let blacklist = read_blacklist(&paths.blacklist)?;
        // Θ(T) once
        let snap = scan_procs().unwrap_or_else(|_| ProcSnap::default());

        let fg = foreground_pkg(&mut fg_cache);
        let disabled_set = if settings.mode == Mode::Disable {
            // Θ(D) + 1 binder, once per poll
            list_disabled().unwrap_or_default()
        } else {
            HashSet::new()
        };

        let now_unix = unix_now();

        for pkg in &blacklist {
            let Some(&uid) = pkg_index.get(pkg.as_str()) else {
                continue;
            };
            if uid < 10000 {
                continue;
            }

            match settings.mode {
                Mode::Disable => {
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

fn foreground_pkg(cache: &mut (Option<String>, Instant)) -> Option<String> {
    if cache.1.elapsed() < FG_CACHE {
        return cache.0.clone();
    }
    let out = Command::new("/system/bin/dumpsys")
        .args(["activity", "activities"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let s = String::from_utf8_lossy(&out.stdout);
    let mut found = None;
    for line in s.lines() {
        if line.contains("mResumedActivity") || line.contains("topResumedActivity") {
            // ... pkg/activity ...
            if let Some(pkg) = extract_pkg_from_activity_line(line) {
                found = Some(pkg);
                break;
            }
        }
    }
    cache.0 = found.clone();
    cache.1 = Instant::now();
    found
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
