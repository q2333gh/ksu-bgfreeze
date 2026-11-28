//! Freeze backends for mode=stop.
//! Prefer cgroup uid freeze (O(1)); then v1 /dev/freezer; then SIGSTOP with uid re-check.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use crate::procscan::{pid_uid, UidSnap};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// `/sys/fs/cgroup/apps/uid_<uid>/cgroup.freeze`
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
    if Path::new("/sys/fs/cgroup/apps").is_dir() {
        // Prefer apps hierarchy even if a sample uid dir is not yet created.
        return Backend::CgroupUid;
    }
    if Path::new("/dev/freezer/frozen/cgroup.procs").is_file()
        && Path::new("/dev/freezer/thaw/cgroup.procs").is_file()
    {
        return Backend::FreezerV1;
    }
    Backend::SigStop
}

fn apps_uid_freeze_path(uid: u32) -> PathBuf {
    PathBuf::from(format!("/sys/fs/cgroup/apps/uid_{uid}/cgroup.freeze"))
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
            let p = apps_uid_freeze_path(uid);
            if !p.is_file() {
                // App cgroup not created yet (no process) — nothing to freeze.
                return Ok(0);
            }
            write_one(&p, "1")?;
            Ok(1)
        }
        Backend::FreezerV1 => {
            let mut n = 0;
            for &(pid, _) in &snap.pids {
                if !pid_still_uid(pid, uid) {
                    continue;
                }
                write_one(Path::new("/dev/freezer/frozen/cgroup.procs"), &format!("{pid}\n"))?;
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
            let p = apps_uid_freeze_path(uid);
            if !p.is_file() {
                return Ok(0);
            }
            write_one(&p, "0")?;
            Ok(1)
        }
        Backend::FreezerV1 => {
            let mut n = 0;
            for &(pid, _) in &snap.pids {
                if !pid_still_uid(pid, uid) {
                    continue;
                }
                write_one(Path::new("/dev/freezer/thaw/cgroup.procs"), &format!("{pid}\n"))?;
                n += 1;
            }
            Ok(n)
        }
        Backend::SigStop => Ok(snap.cont_all_checked(uid)),
    }
}

/// true if cgroup reports frozen (cgroup-uid only); others use process state.
pub fn is_cgroup_frozen(uid: u32) -> bool {
    let p = apps_uid_freeze_path(uid);
    read_trim(&p).map(|s| s == "1").unwrap_or(false)
}

fn pid_still_uid(pid: i32, want: u32) -> bool {
    pid_uid(pid).map(|u| u == want).unwrap_or(false)
}
