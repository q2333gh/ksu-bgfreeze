//! Freeze backends for mode=stop.
//! Prefer cgroup uid freeze (O(1)); then v1 /dev/freezer; then SIGSTOP with uid re-check.
//!
//! Layouts (research 2024–2025 / AOSP CachedAppOptimizer / OP12 ColorOS):
//! - ColorOS/OP12: `/sys/fs/cgroup/apps/uid_<uid>/cgroup.freeze`
//! - AOSP-style:   `/sys/fs/cgroup/uid_<uid>/cgroup.freeze`
//! Binder freeze (`BINDER_FREEZE`) stays out of scope for a pure KSU module
//! (needs framework / Re:Kernel / Xposed) — see docs/TOMBSTONE_PLAN.md.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use crate::procscan::{pid_uid, UidSnap};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// uid cgroup.freeze under apps/ or root cgroup (see `uid_freeze_path`)
    CgroupUid,
    /// `/dev/freezer/frozen|thaw/cgroup.procs`
    FreezerV1,
    SigStop,
}

impl Backend {
    pub fn as_str(self) -> &'static str {
        match self {
            Backend::CgroupUid => "cgroup-uid",
            Backend::FreezerV1 => "freezer-v1",
            Backend::SigStop => "sigstop",
        }
    }
}

pub fn detect() -> Backend {
    // O(1) probes only — never walk /sys/fs/cgroup.
    if Path::new("/sys/fs/cgroup/apps").is_dir() {
        return Backend::CgroupUid;
    }
    // AOSP CachedAppOptimizer layout sample.
    if Path::new("/sys/fs/cgroup/uid_0/cgroup.freeze").is_file() {
        return Backend::CgroupUid;
    }
    if Path::new("/dev/freezer/frozen/cgroup.procs").is_file()
        && Path::new("/dev/freezer/thaw/cgroup.procs").is_file()
    {
        return Backend::FreezerV1;
    }
    Backend::SigStop
}

/// Resolve freeze node for uid: apps/ first, then AOSP root uid_.
pub fn uid_freeze_path(uid: u32) -> Option<PathBuf> {
    let apps = PathBuf::from(format!("/sys/fs/cgroup/apps/uid_{uid}/cgroup.freeze"));
    if apps.is_file() {
        return Some(apps);
    }
    let root = PathBuf::from(format!("/sys/fs/cgroup/uid_{uid}/cgroup.freeze"));
    if root.is_file() {
        return Some(root);
    }
    None
}

fn write_one(path: &Path, data: &str) -> io::Result<()> {
    let mut f = OpenOptions::new().write(true).open(path)?;
    f.write_all(data.as_bytes())?;
    Ok(())
}

fn read_trim(path: &Path) -> io::Result<String> {
    Ok(fs::read_to_string(path)?.trim().to_string())
}

/// Freeze app uid. Returns how many units acted (1 for cgroup write, or pid count).
pub fn freeze_uid(backend: Backend, uid: u32, snap: &UidSnap) -> io::Result<usize> {
    if uid < 10000 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "refuse system uid",
        ));
    }
    match backend {
        Backend::CgroupUid => {
            let Some(p) = uid_freeze_path(uid) else {
                // App cgroup not created yet (no process) — nothing to freeze.
                return Ok(0);
            };
            write_one(&p, "1")?;
            if read_trim(&p)? != "1" {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "cgroup.freeze verify-fail",
                ));
            }
            Ok(1)
        }
        Backend::FreezerV1 => {
            let mut n = 0;
            for &(pid, _) in &snap.pids {
                if !pid_still_uid(pid, uid) {
                    continue;
                }
                write_one(
                    Path::new("/dev/freezer/frozen/cgroup.procs"),
                    &format!("{pid}\n"),
                )?;
                n += 1;
            }
            Ok(n)
        }
        Backend::SigStop => Ok(snap.stop_running_checked(uid)),
    }
}

pub fn thaw_uid(backend: Backend, uid: u32, snap: &UidSnap) -> io::Result<usize> {
    if uid < 10000 {
        return Ok(0);
    }
    match backend {
        Backend::CgroupUid => {
            let Some(p) = uid_freeze_path(uid) else {
                return Ok(0);
            };
            write_one(&p, "0")?;
            if read_trim(&p).unwrap_or_default() == "1" {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    "cgroup.thaw verify-fail",
                ));
            }
            Ok(1)
        }
        Backend::FreezerV1 => {
            let mut n = 0;
            for &(pid, _) in &snap.pids {
                if !pid_still_uid(pid, uid) {
                    continue;
                }
                write_one(
                    Path::new("/dev/freezer/thaw/cgroup.procs"),
                    &format!("{pid}\n"),
                )?;
                n += 1;
            }
            Ok(n)
        }
        Backend::SigStop => Ok(snap.cont_all_checked(uid)),
    }
}

/// true if cgroup reports frozen (cgroup-uid only); others use process state.
pub fn is_cgroup_frozen(uid: u32) -> bool {
    uid_freeze_path(uid)
        .and_then(|p| read_trim(&p).ok())
        .map(|s| s == "1")
        .unwrap_or(false)
}

fn pid_still_uid(pid: i32, want: u32) -> bool {
    pid_uid(pid).map(|u| u == want).unwrap_or(false)
}

/// Human/agent diagnostics for freeze capability on this device.
pub fn diagnose() -> String {
    let backend = detect();
    let mut lines = vec![format!("backend={}", backend.as_str())];
    lines.push(format!(
        "apps_hierarchy={}",
        Path::new("/sys/fs/cgroup/apps").is_dir()
    ));
    lines.push(format!(
        "aosp_uid0_freeze={}",
        Path::new("/sys/fs/cgroup/uid_0/cgroup.freeze").is_file()
    ));
    lines.push(format!(
        "freezer_v1={}",
        Path::new("/dev/freezer/frozen/cgroup.procs").is_file()
    ));
    lines.push(
        "binder_freeze=unavailable_in_module (need framework/Re:Kernel/Xposed)".into(),
    );
    lines.join("\n")
}
