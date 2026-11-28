//! Hard-capped exec for Binder-facing tools. Fail-fast, no retry storms.

use std::io;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

/// Per-poll budget for am/pm/dumpsys style calls.
pub struct IpcBudget {
    used: u32,
    limit: u32,
}

impl IpcBudget {
    pub fn new(limit: u32) -> Self {
        Self { used: 0, limit }
    }

    pub fn try_take(&mut self) -> bool {
        if self.used >= self.limit {
            return false;
        }
        self.used += 1;
        true
    }
}

static BINDER_FAILS: AtomicU32 = AtomicU32::new(0);

pub fn note_binder_fail() {
    BINDER_FAILS.fetch_add(1, Ordering::Relaxed);
}

pub fn binder_fail_count() -> u32 {
    BINDER_FAILS.load(Ordering::Relaxed)
}

pub fn reset_binder_fails() {
    BINDER_FAILS.store(0, Ordering::Relaxed);
}

fn looks_binder_fail(s: &str) -> bool {
    s.contains("Failed transaction")
        || s.contains("DeadObject")
        || s.contains("RemoteException")
}

/// Run program with wall timeout (via toybox timeout) and stdout byte cap.
pub fn run_capped(
    bin: &str,
    args: &[&str],
    timeout: Duration,
    max_stdout: usize,
) -> io::Result<Vec<u8>> {
    let secs = timeout.as_secs().max(1).to_string();
    let out = if Path::new("/system/bin/timeout").is_file() {
        Command::new("/system/bin/timeout")
            .args(["-k", "1", &secs, bin])
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()?
    } else {
        Command::new(bin)
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()?
    };

    let err = String::from_utf8_lossy(&out.stderr);
    let stdout_s = String::from_utf8_lossy(&out.stdout);
    if looks_binder_fail(&err) || looks_binder_fail(&stdout_s) {
        note_binder_fail();
        return Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            format!("Failed transaction: {err}"),
        ));
    }
    // timeout(1) exits 124 on timeout
    if !out.status.success() {
        if out.status.code() == Some(124) {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("timeout {bin}"),
            ));
        }
        // Non-zero without binder fail: still return stdout for parsers that tolerate it
    }

    let mut buf = out.stdout;
    if buf.len() > max_stdout {
        buf.truncate(max_stdout);
    }
    Ok(buf)
}
