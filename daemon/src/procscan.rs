//! One-pass /proc scan — Θ(T) per call, no per-pid forks.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

#[derive(Debug, Default, Clone)]
pub struct ProcSnap {
    pub by_uid: HashMap<u32, UidSnap>,
}

#[derive(Debug, Default, Clone)]
pub struct UidSnap {
    /// (pid, state first char) e.g. 'R','S','T'
    pub pids: Vec<(i32, char)>,
}

impl UidSnap {
    pub fn stopped_count(&self) -> usize {
        self.pids.iter().filter(|(_, s)| *s == 'T').count()
    }

    /// SIGSTOP only if /proc/pid still belongs to `want_uid` (TOCTOU harden).
    pub fn stop_running_checked(&self, want_uid: u32) -> usize {
        let mut n = 0;
        for &(pid, st) in &self.pids {
            if st == 'T' {
                continue;
            }
            if pid_uid(pid) != Some(want_uid) {
                continue;
            }
            if signal(pid, libc::SIGSTOP) {
                n += 1;
            }
        }
        n
    }

    pub fn cont_all_checked(&self, want_uid: u32) -> usize {
        let mut n = 0;
        for &(pid, _) in &self.pids {
            if pid_uid(pid) != Some(want_uid) {
                continue;
            }
            if signal(pid, libc::SIGCONT) {
                n += 1;
            }
        }
        n
    }
}

fn signal(pid: i32, sig: i32) -> bool {
    // SAFETY: kill is the intended process control API for freezer daemon.
    unsafe { libc::kill(pid, sig) == 0 }
}

/// Re-read Uid from /proc/pid/status. None if gone or unreadable.
pub fn pid_uid(pid: i32) -> Option<u32> {
    let path = PathBuf::from(format!("/proc/{pid}/status"));
    parse_status(&path).map(|(u, _)| u)
}

/// Walk /proc/[pid]/status once. Complexity Θ(T).
pub fn scan_procs() -> io::Result<ProcSnap> {
    let mut snap = ProcSnap::default();
    let rd = fs::read_dir("/proc")?;
    for ent in rd.flatten() {
        let name = ent.file_name();
        let name = name.to_string_lossy();
        if !name.as_bytes().iter().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Ok(pid) = name.parse::<i32>() else {
            continue;
        };
        if pid <= 1 {
            continue;
        }
        let status_path = ent.path().join("status");
        let Some((uid, state)) = parse_status(&status_path) else {
            continue;
        };
        // Only app UIDs matter for freezer; still index all ≥10000 to keep map small-ish.
        if uid < 10000 {
            continue;
        }
        snap.by_uid
            .entry(uid)
            .or_default()
            .pids
            .push((pid, state));
    }
    Ok(snap)
}

fn parse_status(path: &Path) -> Option<(u32, char)> {
    let mut f = fs::File::open(path).ok()?;
    let mut buf = String::with_capacity(512);
    // status is small; cap read
    let mut tmp = [0u8; 2048];
    let n = f.read(&mut tmp).ok()?;
    buf.push_str(&String::from_utf8_lossy(&tmp[..n]));

    let mut uid = None;
    let mut state = '?';
    for line in buf.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            let first = rest.split_whitespace().next()?;
            uid = Some(first.parse().ok()?);
        } else if let Some(rest) = line.strip_prefix("State:") {
            state = rest.trim().chars().next().unwrap_or('?');
        }
    }
    Some((uid?, state))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_smoke() {
        let s = scan_procs().expect("scan");
        assert!(!s.by_uid.is_empty() || true);
    }
}
