//! Hail-style whole-package disable — one attempt, verify once, fail-fast.

use std::collections::HashSet;
use std::io;
use std::process::{Command, Stdio};

pub fn is_critical(pkg: &str) -> bool {
    matches!(
        pkg,
        "android"
            | "com.android.systemui"
            | "com.android.phone"
            | "com.android.server.telecom"
            | "com.android.settings"
            | "com.android.permissioncontroller"
            | "com.android.providers.settings"
            | "com.android.nfc"
            | "com.android.keychain"
            | "com.android.keystore"
            | "com.android.shell"
            | "com.android.bluetooth"
            | "com.android.vending"
            | "com.google.android.gms"
            | "com.google.android.gsf"
    ) || pkg.starts_with("com.android.launcher")
        || pkg.starts_with("com.android.providers.media")
        || pkg.starts_with("com.android.inputmethod")
        || pkg.starts_with("com.google.android.inputmethod")
        || pkg.starts_with("com.android.networkstack")
        || pkg.starts_with("com.oplus.")
        || pkg.starts_with("net.oneplus.")
        || pkg.starts_with("com.oneplus.")
        || pkg.starts_with("com.coloros.")
        || pkg.starts_with("com.qti.")
        || pkg.starts_with("com.qualcomm.")
        || pkg.starts_with("com.android.lmk")
        || pkg.starts_with("me.weishu.kernelsu")
        || pkg.starts_with("com.rifsxd.ksunext")
        || pkg.starts_with("com.topjohnwu.magisk")
}

pub fn is_binder_fail(msg: &str) -> bool {
    msg.contains("Failed transaction")
        || msg.contains("DeadObject")
        || msg.contains("NullPointerException")
        || msg.contains("RemoteException")
}

fn current_user() -> u32 {
    let out = Command::new("am")
        .arg("get-current-user")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok();
    out.and_then(|o| {
        String::from_utf8_lossy(&o.stdout)
            .trim()
            .parse()
            .ok()
    })
    .unwrap_or(0)
}

/// Θ(D) — one binder call, returns HashSet of disabled packages.
pub fn list_disabled() -> io::Result<HashSet<String>> {
    let out = Command::new("pm")
        .args(["list", "packages", "-d"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;
    let err = String::from_utf8_lossy(&out.stderr);
    if is_binder_fail(&err) || is_binder_fail(&String::from_utf8_lossy(&out.stdout)) {
        return Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            format!("Failed transaction: {err}"),
        ));
    }
    let mut set = HashSet::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if let Some(pkg) = line.strip_prefix("package:") {
            set.insert(pkg.trim().to_string());
        }
    }
    Ok(set)
}

/// ONE force-stop + ONE pm disable + verify via list_disabled caller or re-list.
pub fn apply_disable(pkg: &str) -> io::Result<()> {
    if is_critical(pkg) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "critical package",
        ));
    }
    let uid = current_user();

    let fs_out = Command::new("am")
        .args(["force-stop", "--user", &uid.to_string(), pkg])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?;
    let fs_err = String::from_utf8_lossy(&fs_out.stderr);
    if is_binder_fail(&fs_err) {
        return Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            format!("Failed transaction force-stop: {fs_err}"),
        ));
    }

    let pm_out = Command::new("pm")
        .args(["disable", "--user", &uid.to_string(), pkg])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&pm_out.stdout),
        String::from_utf8_lossy(&pm_out.stderr)
    );
    if is_binder_fail(&combined) {
        return Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            format!("Failed transaction pm-disable: {combined}"),
        ));
    }
    if !pm_out.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("pm disable failed: {combined}"),
        ));
    }

    // ONE verify
    let disabled = list_disabled()?;
    if disabled.contains(pkg) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::Other,
            "verify-fail: package still enabled",
        ))
    }
}

pub fn revive(pkg: &str) -> io::Result<()> {
    let uid = current_user();
    let _ = Command::new("pm")
        .args(["enable", "--user", &uid.to_string(), pkg])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let _ = Command::new("pm")
        .args(["unsuspend", "--user", &uid.to_string(), pkg])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    Ok(())
}
